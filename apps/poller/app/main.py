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

import logging
import time

import redis
from imap_tools import AND, MailBox, MailMessageFlags

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
    client.ping()
    logger.info("Connected to Redis at %s", settings.REDIS_URL)
    return client


def _process_email_uid(r: redis.Redis, mailbox: MailBox, uid: str) -> bool:
    """Publish a single email UID to the Redis stream and mark it as SEEN on success."""
    try:
        payload = {"uid": uid}
        stream_id = r.xadd(settings.REDIS_STREAM_NAME, payload)
        mailbox.flag(uid, MailMessageFlags.SEEN, True)
        logger.info("Published UID %s → stream entry %s and marked SEEN.", uid, stream_id)
        return True
    except Exception as exc:  # noqa: BLE001
        logger.error("Failed to process UID %s: %s", uid, exc)
        return False


def poll_once(r: redis.Redis) -> int:
    """
    Open IMAP, find all UNSEEN message UIDs, and process them.
    Returns the number of emails successfully published.
    """
    username = settings.PRIVATE_MAIL_EMAIL_ID
    password = settings.PRIVATE_MAIL_PASSWORD

    if not (username and password):
        logger.warning("IMAP credentials not configured — skipping poll.")
        return 0

    published = 0
    try:
        with MailBox(settings.HOST, port=settings.IMAP_PORT, timeout=15).login(
            username, password
        ) as mailbox:
            unseen_uids = mailbox.uids(AND(seen=False))
            if not unseen_uids:
                return 0

            logger.info("Found %d unseen email(s) in INBOX.", len(unseen_uids))

            for uid in unseen_uids:
                if _process_email_uid(r, mailbox, uid):
                    published += 1

    except Exception as exc:  # noqa: BLE001
        logger.error("IMAP connection/fetch error: %s", exc)

    return published


def run() -> None:
    """Main loop — poll forever."""
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
