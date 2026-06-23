# Poller Microservice — Code & Flow Explanation

This document explains the internal scripts, source code, and execution flow of the **IMAP Poller** microservice.

---

## Execution Flow Diagram

The following Mermaid diagram shows the lifecycle and polling logic executed by `app/main.py` in the poller container:

```mermaid
graph TD
    Start([Service Start]) --> InitRedis[Initialize Redis Client]
    
    subgraph Connection Retry Loop
        InitRedis -->|Failure| RetryRedis[Wait 3s]
        RetryRedis --> InitRedis
        InitRedis -->|Success| PollLoop{Poll Inbox Loop}
    end

    PollLoop --> LoginIMAP[Login to Namecheap IMAP]
    LoginIMAP -->|Failure| LogError[Log Error] --> Sleep[Sleep IMAP_POLL_INTERVAL]
    LoginIMAP -->|Success| FetchUIDs[Fetch UNSEEN Message UIDs]
    
    FetchUIDs -->|No UIDs Found| CloseIMAP[Close IMAP Session]
    CloseIMAP --> Sleep
    
    FetchUIDs -->|UIDs Found| LoopUIDs[For each UID]
    
    LoopUIDs --> PushStream[Publish UID to Redis Stream XADD]
    
    PushStream -->|Success| MarkSeen[Mark Email as SEEN in Inbox]
    MarkSeen --> NextUID{More UIDs?}
    
    PushStream -->|Failure| LogPushError[Log Publish Error]
    LogPushError --> NextUID
    
    NextUID -->|Yes| LoopUIDs
    NextUID -->|No| CloseIMAP
    
    Sleep --> PollLoop
```

---

## Script & Code Breakdown

### 1. Configuration: `app/core/config.py`
This script defines the configuration settings for the poller service using **Pydantic Settings**. It automatically reads values from environment variables or loads them from the shared `.env` file at the root.

```python
from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Namecheap IMAP Settings
    IMAP_HOST: str = "mail.privateemail.com"
    IMAP_PORT: int = 993
    IMAP_USERNAME: str | None = None
    IMAP_PASSWORD: str | None = None
    IMAP_POLL_INTERVAL: int = 60  # seconds between inbox checks

    # Redis Settings
    REDIS_URL: str = "redis://localhost:6379/0"
    REDIS_STREAM_NAME: str = "email:inbound"

    model_config = SettingsConfigDict(env_file=("../../.env", ".env"), extra="ignore")


settings = Settings()
```

---

### 2. Main Entry Point: `app/main.py`
This is the heart of the poller service. It runs an infinite loop checking for unread email UIDs, posting them to Redis, and marking them read only after a successful queue write.

```python
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
    # Ping to verify connectivity on startup
    client.ping()
    logger.info("Connected to Redis at %s", settings.REDIS_URL)
    return client


def poll_once(r: redis.Redis) -> int:
    """
    Open IMAP, find all UNSEEN message UIDs, publish each UID to the Redis Stream,
    and mark them as SEEN on success.
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
            # Fetch UIDs of all unseen emails
            unseen_uids = mailbox.uids(AND(seen=False))
            if not unseen_uids:
                return 0

            logger.info("Found %d unseen email(s) in INBOX.", len(unseen_uids))

            for uid in unseen_uids:
                try:
                    payload = {"uid": uid}
                    # Push UID to the stream
                    stream_id = r.xadd(settings.REDIS_STREAM_NAME, payload)
                    
                    # Successfully added to Redis stream, now mark SEEN in IMAP
                    mailbox.flag(uid, MailMessageFlags.SEEN, True)
                    
                    published += 1
                    logger.info("Published UID %s → stream entry %s and marked SEEN.", uid, stream_id)
                except Exception as exc:  # noqa: BLE001
                    logger.error("Failed to process UID %s: %s", uid, exc)

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
```
