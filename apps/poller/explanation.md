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

## Detailed Code & Snippet Breakdown

### 1. Configuration: `app/core/config.py`

This script handles the microservice configuration using Pydantic Settings.

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

#### Snippet Breakdown:
*   **`class Settings(BaseSettings)`**: Inherits from Pydantic's `BaseSettings`. This automatically maps class variables to matching environment variables (case-insensitive). If an environment variable is set (e.g. `IMAP_USERNAME="support@domain.com"`), Pydantic replaces the default `None` with that value.
*   **`IMAP_POLL_INTERVAL: int = 60`**: Declares that this configuration parameter is strictly parsed as an integer. If the environment variable provides a string like `"30"`, Pydantic casts it to `30`.
*   **`model_config = SettingsConfigDict(env_file=("../../.env", ".env"), extra="ignore")`**:
    *   `env_file`: Tells Pydantic to look for a `.env` file first at `../../.env` (two levels up, which is the project root in our structure) and fallback to `.env` in the local directory if the parent isn't present.
    *   `extra="ignore"`: Discards any extra environment variables in `.env` (like `GEMINI_API_KEY` or SMTP settings) that this poller service doesn't require, preventing validation conflicts.

---

### 2. Main Entry Point: `app/main.py`

This is the main driver script for the poller. Below is the detailed breakdown of each code section:

#### Redis Connection Builder & Retry
```python
def _build_redis_client() -> redis.Redis:
    """Create and return a Redis client with connection retry."""
    client = redis.from_url(settings.REDIS_URL, decode_responses=True)
    # Ping to verify connectivity on startup
    client.ping()
    logger.info("Connected to Redis at %s", settings.REDIS_URL)
    return client
```
*   **`decode_responses=True`**: Crucial config parameter. It instructs the Redis client to automatically decode binary string payloads fetched from Redis into Python native UTF-8 strings. Without this, all values read would return as `bytes` (e.g. `b"uid"`).
*   **`client.ping()`**: Sends a synchronous ping-pong command to the Redis server. If Redis is starting up or offline, this raises a `ConnectionError`, prompting the startup routine to wait rather than executing loop cycles blindly.

---

#### Fetching Unseen UIDs (Metadata Only)
```python
            # Fetch UIDs of all unseen emails
            unseen_uids = mailbox.uids(AND(seen=False))
            if not unseen_uids:
                return 0
```
*   **`mailbox.uids(AND(seen=False))`**: Performs an IMAP `SEARCH UNSEEN` command on the mail server. It **only** retrieves a list of numeric string identifiers (e.g., `['45', '46', '47']`).
*   **Why this is highly scalable**: Unlike a standard fetch that downloads the full multipart MIME payload (including HTML bodies and heavy image attachments) for every unread email, this metadata lookup transfers only a few bytes. It avoids bloating the poller's CPU and RAM under heavy mail volumes.

---

#### At-Least-Once Transactional Queueing & Claiming
```python
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
```
*   **`r.xadd(settings.REDIS_STREAM_NAME, payload)`**: Appends a new entry containing the email UID into the Redis Stream. Redis generates a unique timestamp-based ID (e.g., `1719123456789-0`) and returns it.
*   **`mailbox.flag(uid, MailMessageFlags.SEEN, True)`**: Once (and only once) Redis successfully acknowledges the addition to the stream, the poller flags the email as `\Seen` on the IMAP server.
*   **Why this is resilient**:
    *   If the Redis connection fails or drops during the loop, the `xadd` will throw an error, skipping the `mailbox.flag` mutation. The email remains `UNSEEN` in the mailbox. On the next poll cycle, the poller tries again.
    *   If the poller crashes after writing to the stream but before flagging it `SEEN`, the worker will still process the message. The duplicate entry will be caught by the worker's deduplication check.
    *   Catches exceptions inside the loop (`except Exception`) so that a single corrupted email transaction does not abort processing for other valid emails in the same batch.
