# IMAP Poller Microservice

The IMAP Poller is a lightweight, single-replica microservice responsible for checking the Namecheap IMAP support inbox, identifying new emails, and publishing their unique IMAP UIDs to the Redis Stream for worker processing.

---

## Responsibilities

1. **Periodic Inbox Scanning**: Logs into the Namecheap IMAP server every `IMAP_POLL_INTERVAL` seconds to search for `UNSEEN` emails.
2. **Lightweight UID Search**: Uses the IMAP `SEARCH` protocol to retrieve only the numerical message UIDs. This avoids downloading large email bodies or MIME attachments in the poller service, keeping CPU, memory, and network utilization extremely low.
3. **At-Least-Once Delivery**: Publishes the UID to the Redis Stream using `XADD`. Only after the Redis transaction succeeds does it mark the email as `SEEN` (read) in the IMAP folder. If Redis is unavailable or the push fails, the email is left unread so it can be retried on the next poll cycle.
4. **Race Prevention (Single Replica)**: Runs as a single container replica (`replicas: 1`). Keeping it at exactly one replica prevents multiple pollers from racing on the same unseen emails.

---

## File Structure

```
apps/poller/
├── Dockerfile                  # Slim Python 3.12 build definition
├── pyproject.toml              # Dependencies (imap-tools, redis)
├── README.md                   # This file
└── app/
    ├── __init__.py
    ├── main.py                 # Core IMAP poll and Redis stream publisher loop
    └── core/
        ├── __init__.py
        └── config.py           # Poller configuration using pydantic-settings
```

---

## Environment Variables

The poller relies on the following environment variables (typically supplied via the shared `.env` file at the project root):

| Variable | Description | Default |
|---|---|---|
| `IMAP_HOST` | Namecheap IMAP server address | `mail.privateemail.com` |
| `IMAP_PORT` | Namecheap IMAP port (SSL) | `993` |
| `IMAP_USERNAME` | Support inbox username | *(required)* |
| `IMAP_PASSWORD` | Support inbox password | *(required)* |
| `IMAP_POLL_INTERVAL` | Seconds between inbox checks | `60` |
| `REDIS_URL` | Redis server URL | `redis://localhost:6379/0` |
| `REDIS_STREAM_NAME` | Redis Stream to publish to | `email:inbound` |

---

## Local Development

If you want to run the poller microservice locally (outside of Docker):

1. **Install uv**: Ensure you have [uv](https://github.com/astral-sh/uv) installed.
2. **Install dependencies**:
   ```bash
   uv sync
   ```
3. **Start the poller loop**:
   ```bash
   uv run python -m app.main
   ```
