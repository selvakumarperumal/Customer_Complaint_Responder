# Poller Microservice — Code & Flow Explanation

This document explains the internal scripts and execution flow of the **IMAP Poller** microservice.

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

## Script Breakdown

### 1. `app/core/config.py`
This script defines the configuration system for the poller service using **Pydantic Settings**.
*   **Settings Model**: Declares fields for `IMAP_HOST`, `IMAP_PORT`, `IMAP_USERNAME`, `IMAP_PASSWORD`, `IMAP_POLL_INTERVAL`, `REDIS_URL`, and `REDIS_STREAM_NAME`.
*   **Environment Loading**: Configured with `SettingsConfigDict` to load values from a `.env` file located in parent directories (`../../.env` or `.env`) while prioritizing active system environment variables. It ignores extra variables not declared in the model.

### 2. `app/main.py`
This is the entry point of the poller service, housing the main execution loop. It contains three primary functions:

*   **`_build_redis_client() -> redis.Redis`**:
    *   Creates a Redis client from `settings.REDIS_URL` in decoded text mode (`decode_responses=True`).
    *   Executes a `ping()` command on startup to guarantee Redis connectivity before starting the poll loop.
*   **`poll_once(r: redis.Redis) -> int`**:
    *   Logs in to the IMAP mailbox using `settings.IMAP_USERNAME` and `settings.IMAP_PASSWORD`.
    *   Runs `mailbox.uids(AND(seen=False))` to find all unseen message UIDs. This is a lightweight metadata-only fetch.
    *   Loops through each UID, publishing it to the Redis Stream:
        ```python
        r.xadd(settings.REDIS_STREAM_NAME, {"uid": uid})
        ```
    *   Immediately calls `mailbox.flag(uid, MailMessageFlags.SEEN, True)` if the stream addition succeeds. This prevents the next poll cycle from fetching it again.
    *   Catches failures at the individual message level so a single bad queue transaction does not crash the loop.
*   **`run()`**:
    *   Orchestrates startup by retrying the Redis connection every 3 seconds if Redis is not yet online.
    *   Runs an infinite loop calling `poll_once()` followed by a sleep period defined by `settings.IMAP_POLL_INTERVAL`.
