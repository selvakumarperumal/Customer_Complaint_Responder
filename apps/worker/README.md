# AI Worker Microservice

The AI Worker is a scalable microservice responsible for consuming inbound email jobs from the Redis Stream, pulling the full thread context on-demand from the Namecheap IMAP mail server, running the LangGraph AI pipeline, and sending automated replies via SMTP.

---

## Responsibilities

1. **Redis Stream Consumer**: Joins the `complaint-workers` consumer group and blocks on the `email:inbound` stream for new job entries (delivering only the email UID).
2. **On-Demand IMAP Fetcher**: Establishes short-lived IMAP connections to fetch the target email by UID and search the inbox for all messages matching the normalized subject (the conversation thread).
3. **Thread Cleaner**: Chronologically sorts and strips out quoted reply history (lines starting with `>`) to construct a clean conversation transcript.
4. **LangGraph Pipeline**: Invokes the stateless two-node LangGraph agent using Google Gemini (`gemini-3.5-flash`) to classify the complaint category (`delivery`, `refund`, `product issue`, `other`) and generate an empathetic response.
5. **Deduplication Check**: Ensures no duplicate replies are sent by checking and writing to a Redis `replied:{Message-ID}` key (with a 30-day TTL).
6. **SMTP Dispatches**: Sends replies viaNamecheap SMTP with proper `In-Reply-To` and `References` headers for inbox grouping.
7. **Stream Acknowledgement**: Sends `XACK` to remove the message from the Pending Entry List (PEL).

---

## File Structure

```
apps/worker/
├── Dockerfile                  # Slim Python 3.12 build definition
├── pyproject.toml              # Dependencies (LangChain, LangGraph, imap-tools, redis)
├── README.md                   # This file
└── app/
    ├── __init__.py
    ├── main.py                 # Core consumer loop and message orchestrator
    ├── core/
    │   ├── __init__.py
    │   └── config.py           # Worker configuration using pydantic-settings
    └── services/
        ├── __init__.py
        ├── email.py            # SMTP email sending implementation
        └── agent/
            ├── __init__.py
            ├── agent.py        # LangGraph StateGraph pipeline
            └── prompts.py      # Category classification and response templates
```

---

## Environment Variables

The worker relies on the following environment variables (typically supplied via the shared `.env` file at the project root):

| Variable | Description | Default |
|---|---|---|
| `GEMINI_API_KEY` | Google Gemini API key | *(required)* |
| `MISTRAL_API_KEY` | Mistral API key | *(optional)* |
| `HOST` | Namecheap Private Email host address | `mail.privateemail.com` |
| `PRIVATE_MAIL_EMAIL_ID` | Private Email ID | *(required)* |
| `PRIVATE_MAIL_PASSWORD` | Private Email password | *(required)* |
| `IMAP_PORT` | Namecheap IMAP port (SSL) | `993` |
| `SMTP_PORT` | Namecheap SMTP port (STARTTLS) | `587` |
| `FROM_NAME` | Support display name | `Customer Support` |
| `REDIS_URL` | Redis server URL | `redis://localhost:6379/0` |
| `REDIS_STREAM_NAME` | Redis Stream to consume from | `email:inbound` |
| `REDIS_CONSUMER_GROUP` | Consumer group name | `complaint-workers` |
| `REDIS_DEDUPE_TTL` | Retention (seconds) of dedupe keys | `2592000` (30 days) |

---

## Local Development

If you want to run the worker microservice locally (outside of Docker):

1. **Install uv**: Ensure you have [uv](https://github.com/astral-sh/uv) installed.
2. **Install dependencies**:
   ```bash
   uv sync
   ```
3. **Start the worker loop**:
   ```bash
   uv run python -m app.main
   ```
