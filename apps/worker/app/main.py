"""
Worker microservice — entry point.

Responsibilities:
  1. Join Redis Stream consumer group "complaint-workers".
  2. Block-read messages from the "email:inbound" stream (XREADGROUP).
     - Each message is delivered to exactly ONE worker replica.
  3. For each message:
     a. Check Redis dedupe key "replied:{message_id}" — skip if already handled.
     b. Run LangGraph complaint handler → generate AI response.
     c. Send SMTP reply via Namecheap.
     d. SET dedupe key with 30-day TTL.
     e. XACK the stream message (removes it from the Pending Entry List).

Scale freely — Redis Stream consumer groups ensure each email is processed
by exactly one worker even when multiple replicas are running.
"""

import logging
import socket
import time

# pyrefly: ignore [missing-import]
import redis
from imap_tools import AND, MailBox, OR

from app.core.config import settings
from app.services.agent.agent import process_complaint
from app.services.email import send_support_email

_hostname = socket.gethostname()
logging.basicConfig(
    level=logging.INFO,
    format=f"%(asctime)s [worker/{_hostname}] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Redis helpers
# ---------------------------------------------------------------------------

def _build_redis_client() -> redis.Redis:
    """Create Redis client with retry on startup."""
    client = redis.from_url(settings.REDIS_URL, decode_responses=True, socket_timeout=15)
    client.ping()
    logger.info("Connected to Redis at %s", settings.REDIS_URL)
    return client


def _ensure_consumer_group(r: redis.Redis) -> None:
    try:
        r.xgroup_create(
            name=settings.REDIS_STREAM_NAME,
            groupname=settings.REDIS_CONSUMER_GROUP,
            id="$",
            mkstream=True,
        )
        logger.info(
            "Created consumer group '%s' on stream '%s'.",
            settings.REDIS_CONSUMER_GROUP,
            settings.REDIS_STREAM_NAME,
        )
    except redis.exceptions.ResponseError as exc:
        if "BUSYGROUP" in str(exc):
            logger.debug("Consumer group already exists — OK.")
        else:
            raise


def _dedupe_key(message_id: str) -> str:
    return f"replied:{message_id}"


# ---------------------------------------------------------------------------
# Message processing
# ---------------------------------------------------------------------------

def _handle_message(r: redis.Redis, stream_entry_id: str, fields: dict) -> None:
    """
    Process a single email from the stream by fetching it from IMAP using UID.
    Always ACKs the message if handled successfully or if it's an unrecoverable/skipped scenario.
    """
    uid = fields.get("uid", "")
    
    logger.info("Received job for email UID %s (stream_id=%s)", uid, stream_entry_id)

    if not uid:
        logger.warning("No UID found in stream entry %s — skipping.", stream_entry_id)
        
        r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
        return

    if not (settings.PRIVATE_MAIL_EMAIL_ID and settings.PRIVATE_MAIL_PASSWORD):
        logger.error("IMAP settings are not configured in worker — cannot fetch email %s", uid)
        
        raise ValueError("IMAP settings are not configured in worker.")

    try:
        # ── 1. Fetch email and its thread history from IMAP on-demand ────────
        with MailBox(settings.HOST, port=settings.IMAP_PORT, timeout=15).login(
            settings.PRIVATE_MAIL_EMAIL_ID, settings.PRIVATE_MAIL_PASSWORD
        ) as mailbox:
            messages = list(mailbox.fetch(AND(uid=uid)))
            
            if not messages:
                logger.warning("Email with UID %s not found in mailbox — skipping.", uid)
                
                r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
                return
            
            msg = messages[0]
            from_email = msg.from_
            subject = msg.subject or "(no subject)"
            message_id = msg.obj.get("Message-ID", "").strip()
            references = msg.obj.get("References", "").strip()
            in_reply_to = msg.obj.get("In-Reply-To", "").strip()
            
            thread_id = (
                in_reply_to
                or references
                or message_id
                or f"thread_{abs(hash(from_email + subject)) % 100_000}"
            )

            def normalize_subject(subj: str) -> str:
                s = subj.lower()
                for prefix in ["re:", "fwd:", "fw:"]:
                    if s.startswith(prefix):
                        s = s[len(prefix):].strip()
                return s.strip()

            def collect_thread_message_ids(message_id_: str, references_: str, in_reply_to_: str) -> set:
                """
                Collect every Message-ID that belongs to this email's thread,
                based on RFC 2822/5322 threading headers (References / In-Reply-To).
                This is the canonical way mail clients (Gmail, Outlook, Apple Mail)
                group conversations — far more reliable than subject-text matching.
                """
                ids = set()
                if message_id_:
                    ids.add(message_id_)
                if references_:
                    ids.update(references_.split())
                if in_reply_to_:
                    ids.add(in_reply_to_)
                return ids

            norm_subj = normalize_subject(subject)
            thread_msg_ids = collect_thread_message_ids(message_id, references, in_reply_to)

            # ── 1a. Narrow candidate pool server-side: same normalized subject
            #        AND (sent by this customer OR sent to this customer).
            #        This is cheap (IMAP-indexed) but NOT sufficient on its own —
            #        two different customers can share an identical subject line
            #        (e.g. "Refund request"), which would otherwise leak one
            #        customer's thread into another's context.
            candidates = list(
                mailbox.fetch(
                    AND(OR(from_=from_email, to=from_email), subject=norm_subj)
                )
            )

            # ── 1b. Strict filter in Python using the Message-ID/References
            #        chain, so we only keep messages that are *actually* part
            #        of this exact conversation — not just same-subject noise
            #        from a different customer, and not lost due to subject
            #        text drift (extra "FWD:", translated "Re:", etc.).
            if thread_msg_ids:
                thread_messages = [
                    m for m in candidates
                    if m.obj.get("Message-ID", "").strip() in thread_msg_ids
                    or (thread_msg_ids & set(m.obj.get("References", "").strip().split()))
                    or (m.obj.get("In-Reply-To", "").strip() in thread_msg_ids)
                ]
                # Always include the triggering message itself, even if its
                # own Message-ID logic above didn't catch it (e.g. first
                # message in a thread, no prior References to match against).
                if not any(m.obj.get("Message-ID", "").strip() == message_id for m in thread_messages):
                    thread_messages.append(msg)
            else:
                # No usable threading headers at all (rare) — fall back to the
                # participant-narrowed, subject-matched candidate pool as-is.
                thread_messages = candidates or [msg]

            thread_messages.sort(key=lambda m: m.date or m.date_str)

            thread_history = ""
            for m in thread_messages:
                m_sender = m.from_
                m_date = m.date.strftime("%Y-%m-%d %H:%M:%S") if m.date else "Unknown Date"
                m_body = m.text.strip() if m.text else m.html.strip() if m.html else ""
                
                clean_lines = [line for line in m_body.splitlines() if not line.strip().startswith(">")]
                clean_body = "\n".join(clean_lines).strip()
                
                thread_history += f"From: {m_sender} (Date: {m_date})\nSubject: {m.subject}\nContent:\n{clean_body}\n\n---\n\n"

        logger.info(
            "Fetched thread history for subject=%r (%d message(s), message_id=%s)",
            subject,
            len(thread_messages),
            message_id,
        )

        # ── 2. Dedupe check ─────────────────────────────────────────────────
        if message_id:
            key = _dedupe_key(message_id)
            if r.exists(key):
                logger.warning(
                    "Already replied to Message-ID %s — skipping duplicate.", message_id
                )
                
                r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
                return
        else:
            logger.warning("Email has no Message-ID header — dedupe not possible.")

        # ── 3. Validate ────────────────-------------------------------------
        if not from_email or not thread_history.strip():
            logger.warning("Missing from_email or thread history — skipping.")
            
            r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
            return

        # ── 4. Run LangGraph AI agent ────────────────────────────────────────
        logger.info("Running LangGraph complaint handler for thread_id=%s", thread_id)
        
        result = process_complaint(thread_history, thread_id=thread_id)
        
        logger.info("Classified as: %s", result["complaint_type"])

        # ── 5. Build reply subject ──────────────────────────────────────────
        reply_subject = subject if subject.lower().startswith("re:") else f"Re: {subject}"

        # ── 6. Send SMTP reply ──────────────────────────────────────────────
        sent = send_support_email(
            to_email=from_email,
            subject=reply_subject,
            body_text=result["response"],
            in_reply_to=message_id or None,
            references=f"{references} {message_id}".strip() or None,
        )

        # ── 7. Mark as replied in Redis ─────────────────────────────────────
        if sent and message_id:
            r.set(_dedupe_key(message_id), "1", ex=settings.REDIS_DEDUPE_TTL)
            
            logger.info("Marked Message-ID %s as replied (TTL=%ds).", message_id, settings.REDIS_DEDUPE_TTL)

        # ── 8. Success ACK ──────────────────────────────────────────────────
        r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
        
        logger.info("Successfully processed and ACKed stream entry %s", stream_entry_id)

    except Exception as exc:  # noqa: BLE001
        logger.error("Error processing message %s: %s", stream_entry_id, exc)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def run() -> None:
    """Consume the Redis Stream forever."""
    r: redis.Redis | None = None
    while r is None:
        try:
            r = _build_redis_client()
        except Exception as exc:  # noqa: BLE001
            logger.warning("Redis not ready yet (%s) — retrying in 3s…", exc)
            time.sleep(3)

    _ensure_consumer_group(r)

    logger.info(
        "Worker started. stream=%s group=%s consumer=%s",
        settings.REDIS_STREAM_NAME,
        settings.REDIS_CONSUMER_GROUP,
        _hostname,
    )

    while True:
        try:
            response = r.xreadgroup(
                groupname=settings.REDIS_CONSUMER_GROUP,
                consumername=_hostname,
                streams={settings.REDIS_STREAM_NAME: ">"},
                count=10,
                block=5000,
            )

            if not response:
                continue

            for _stream_name, entries in response:
                for entry_id, fields in entries:
                    _handle_message(r, entry_id, fields)

        except redis.exceptions.TimeoutError:
            continue

        except redis.exceptions.ConnectionError as exc:
            logger.error("Redis connection lost: %s — retrying in 5s…", exc)
            time.sleep(5)

        except Exception as exc:  # noqa: BLE001
            logger.error("Unexpected error in worker loop: %s", exc)
            time.sleep(1)


if __name__ == "__main__":
    run()
