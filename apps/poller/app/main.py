"""
Poller microservice — entry point.

Responsibilities:
  1. Poll Namecheap IMAP inbox every IMAP_POLL_INTERVAL seconds.
  2. Fetch UNSEEN emails and mark them SEEN immediately (claim them).
  3. Publish each email's payload to the Redis Stream "email:inbound".

This service always runs as a single replica (replicas: 1 in docker-compose).
Keeping it at one replica is what prevents two pollers from racing on the same
UNSEEN email.  The Redis Stream + consumer group in the worker handles scale-out
on the processing side.
"""

import json
import logging
import time

import redis
from imap_tools import AND, MailBox

from app.core.config import settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [poller] %(levelname)s %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger(__name__)


def _build_redis_client() -> redis.Redis:
    """Create and return a Redis client with connection retry."""
    client = redis.from_url(settings.REDIS_URL, decode_responses=True)
    # Ping to verify connectivity on startup
    client.ping()
    logger.info("Connected to Redis at %s", settings.REDIS_URL)
    return client


def poll_once(r: redis.Redis) -> int:
    """
    Open IMAP, fetch all UNSEEN messages, mark them SEEN, publish to stream.
    Returns the number of emails published.
    """
    username = settings.IMAP_USERNAME
    password = settings.IMAP_PASSWORD

    if not (username and password):
        logger.warning("IMAP credentials not configured — skipping poll.")
        return 0

    published = 0
    try:
        with MailBox(settings.IMAP_HOST, port=settings.IMAP_PORT, timeout=15).login(
            username, password
        ) as mailbox:
            # mark_seen=True is atomic within imap-tools — marks the message
            # SEEN on the server before we even touch it locally.
            for msg in mailbox.fetch(AND(seen=False), mark_seen=True):
                try:
                    from_email = msg.from_
                    if not from_email:
                        continue

                    msg_id = msg.obj.get("Message-ID", "").strip()
                    references = msg.obj.get("References", "").strip()
                    in_reply_to = msg.obj.get("In-Reply-To", "").strip()

                    body_text = (
                        msg.text.strip()
                        if msg.text
                        else msg.html.strip()
                        if msg.html
                        else ""
                    )
                    if not body_text:
                        logger.warning("Empty body from %s — skipping.", from_email)
                        continue

                    # Derive a stable thread_id for LangGraph conversation history
                    thread_id = (
                        in_reply_to
                        or references
                        or msg_id
                        or f"thread_{abs(hash(from_email + msg.subject)) % 100_000}"
                    )

                    payload = {
                        "from_email": from_email,
                        "subject": msg.subject or "(no subject)",
                        "body": body_text,
                        "message_id": msg_id,
                        "references": references,
                        "in_reply_to": in_reply_to,
                        "thread_id": thread_id,
                    }

                    # XADD email:inbound * field value ...
                    # Redis flattens the dict to field-value pairs in the stream entry.
                    stream_id = r.xadd(settings.REDIS_STREAM_NAME, payload)
                    published += 1
                    logger.info(
                        "Published email from %s (subject=%r) → stream entry %s",
                        from_email,
                        msg.subject,
                        stream_id,
                    )

                except Exception as exc:  # noqa: BLE001
                    logger.error("Failed to publish individual message: %s", exc)

    except Exception as exc:  # noqa: BLE001
        logger.error("IMAP connection/fetch error: %s", exc)

    return published


def run() -> None:
    """Main loop — poll forever."""
    # Retry Redis connection on startup (Redis may not be ready yet)
    r: redis.Redis | None = None
    while r is None:
        try:
            r = _build_redis_client()
        except Exception as exc:  # noqa: BLE001
            logger.warning("Redis not ready yet (%s) — retrying in 3s…", exc)
            time.sleep(3)

    logger.info(
        "Poller started. Interval=%ds, stream=%s",
        settings.IMAP_POLL_INTERVAL,
        settings.REDIS_STREAM_NAME,
    )

    while True:
        try:
            count = poll_once(r)
            if count:
                logger.info("Poll complete — %d email(s) queued.", count)
            else:
                logger.debug("Poll complete — inbox empty.")
        except Exception as exc:  # noqa: BLE001
            logger.error("Unexpected error in poll loop: %s", exc)

        time.sleep(settings.IMAP_POLL_INTERVAL)


if __name__ == "__main__":
    run()
