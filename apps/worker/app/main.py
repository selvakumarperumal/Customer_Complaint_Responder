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

import redis
from imap_tools import AND, MailBox

from app.core.config import settings
from app.services.agent.agent import process_complaint
from app.services.email import send_support_email

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [worker/%(hostname)s] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)

# Include hostname in every log line so you can distinguish replicas
_hostname = socket.gethostname()
logging.getLogger().handlers[0].setFormatter(
    logging.Formatter(
        fmt=f"%(asctime)s [worker/{_hostname}] %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Redis helpers
# ---------------------------------------------------------------------------

def _build_redis_client() -> redis.Redis:
    """Create Redis client with retry on startup."""
    client = redis.from_url(settings.REDIS_URL, decode_responses=True)
    client.ping()
    logger.info("Connected to Redis at %s", settings.REDIS_URL)
    return client


def _ensure_consumer_group(r: redis.Redis) -> None:
    """
    Create the consumer group if it doesn't exist yet.
    MKSTREAM creates the stream key if it's also missing.
    '$' means: only process NEW messages added after group creation.
    """
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
            # Group already exists — this is fine (other worker replica created it first)
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

    # Check that IMAP config is available
    if not (settings.IMAP_USERNAME and settings.IMAP_PASSWORD):
        logger.error("IMAP settings are not configured in worker — cannot fetch email %s", uid)
        raise ValueError("IMAP settings are not configured in worker.")

    try:
        # ── 1. Fetch email from IMAP on-demand ──────────────────────────────
        with MailBox(settings.IMAP_HOST, port=settings.IMAP_PORT, timeout=15).login(
            settings.IMAP_USERNAME, settings.IMAP_PASSWORD
        ) as mailbox:
            messages = list(mailbox.fetch(AND(uid=uid)))
            if not messages:
                logger.warning("Email with UID %s not found in mailbox — skipping.", uid)
                r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
                return
            
            msg = messages[0]
            from_email = msg.from_
            subject = msg.subject or "(no subject)"
            body = (
                msg.text.strip()
                if msg.text
                else msg.html.strip()
                if msg.html
                else ""
            )
            message_id = msg.obj.get("Message-ID", "").strip()
            references = msg.obj.get("References", "").strip()
            in_reply_to = msg.obj.get("In-Reply-To", "").strip()
            
            thread_id = (
                in_reply_to
                or references
                or message_id
                or f"thread_{abs(hash(from_email + subject)) % 100_000}"
            )

        logger.info("Fetched email from %s (subject=%r, message_id=%s)", from_email, subject, message_id)

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

        # ── 3. Validate ─────────────────────────────────────────────────────
        if not from_email or not body:
            logger.warning("Missing from_email or body — skipping.")
            r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
            return

        # ── 4. Run LangGraph AI agent ────────────────────────────────────────
        logger.info("Running LangGraph complaint handler for thread_id=%s", thread_id)
        result = process_complaint(body, thread_id=thread_id)
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

    # Retry Redis connection on startup (Redis container may not be ready yet)
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
            # XREADGROUP: block up to 5 seconds waiting for a new message.
            # ">" means "give me messages not yet delivered to any consumer."
            # COUNT 10 means process up to 10 emails per batch.
            response = r.xreadgroup(
                groupname=settings.REDIS_CONSUMER_GROUP,
                consumername=_hostname,
                streams={settings.REDIS_STREAM_NAME: ">"},
                count=10,
                block=5000,  # ms
            )

            if not response:
                # Timeout — no new messages, loop back
                continue

            # response shape: [(stream_name, [(entry_id, fields_dict), ...])]
            for _stream_name, entries in response:
                for entry_id, fields in entries:
                    _handle_message(r, entry_id, fields)

        except redis.exceptions.ConnectionError as exc:
            logger.error("Redis connection lost: %s — reconnecting in 5s…", exc)
            time.sleep(5)
            try:
                r = _build_redis_client()
            except Exception:  # noqa: BLE001
                pass

        except Exception as exc:  # noqa: BLE001
            logger.error("Unexpected error in worker loop: %s", exc)
            time.sleep(1)


if __name__ == "__main__":
    run()
