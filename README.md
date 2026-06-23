# Customer Complaint Responder

An AI-powered customer complaint handling system that monitors a support inbox, classifies incoming complaints, and automatically sends professional, empathetic replies using **Google Gemini** and **LangGraph** — all without human intervention.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Project Structure](#project-structure)
- [The Apps](#the-apps)
  - [Poller](#poller)
  - [Worker](#worker)
- [Deduplication — How Duplicate Replies Are Prevented](#deduplication--how-duplicate-replies-are-prevented)
- [LangGraph AI Pipeline](#langgraph-ai-pipeline)
- [Environment Variables](#environment-variables)
- [Quick Start](#quick-start)
- [Scaling](#scaling)
- [Logs](#logs)
- [Tech Stack](#tech-stack)

---

## Overview

When a customer sends a complaint email to your support inbox:

1. The **Poller** detects it via IMAP, pulls only its `uid`, and pushes it to a **Redis Stream**
2. On successful push, the Poller marks the email as `SEEN` to claim it
3. A **Worker** replica pulls the `uid` from the stream and downloads the full email headers/body from IMAP on-demand
4. The Worker checks if the email's `Message-ID` has already been handled, and if not, runs it through the **LangGraph AI agent** (classify → respond)
5. The Worker sends a professional reply via **SMTP**
6. The `Message-ID` is stored in Redis (30-day TTL) so the email is never replied to twice, and the stream entry is acknowledged

The system is designed to scale horizontally — you can run multiple Worker replicas safely because Redis Streams guarantee each email is processed by exactly one worker.

---

## How It Works

### Step-by-step flow

```
Customer sends email
        │
        ▼
Namecheap IMAP inbox  (mail.privateemail.com:993)
        │
        │  Every IMAP_POLL_INTERVAL seconds
        ▼
┌─────────────────────────────────────┐
│             POLLER                  │
│  (always exactly 1 replica)         │
│                                     │
│  1. IMAP SEARCH UNSEEN (UIDs only)  │  ← extremely fast & lightweight
│  2. XADD email:inbound * uid={uid}   │  ← push UID to Redis Stream
│  3. Mark UID as SEEN in mailbox     │  ← claim email only on success
└─────────────────────────────────────┘
        │
        │  Redis Stream  "email:inbound"
        │  Consumer Group "complaint-workers"
        │
        ▼
┌─────────────────────────────────────┐
│             WORKER                  │
│  (scale to any number of replicas)  │
│                                     │
│  1. XREADGROUP (block 5s)           │  ← get UID from stream entry
│  2. Connect to IMAP, fetch by UID   │  ← on-demand download & parsing
│  3. Check Redis: EXISTS             │
│       replied:{message_id}          │  ← skip if already handled
│  4. LangGraph AI pipeline:          │
│       classify complaint type       │
│       generate professional reply   │
│  5. Send reply via SMTP             │
│  6. SET replied:{message_id} 1      │  ← mark as done (30-day TTL)
│  7. XACK stream entry               │  ← remove from Pending Entry List
└─────────────────────────────────────┘
        │
        ▼
Customer receives AI-generated reply
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         Docker Compose                           │
│                                                                  │
│  ┌──────────┐     XADD      ┌──────────────────────────────┐    │
│  │  poller  │ ─────────────▶│   Redis 7                    │    │
│  │ 1 replica│               │   Stream: email:inbound      │    │
│  └──────────┘               │   Keys:   replied:{msg_id}   │    │
│       │                     └──────────────────────────────┘    │
│       │ IMAP poll                        │ XREADGROUP           │
│       │ (SSL:993)                        ▼                      │
│       │                     ┌──────────────────────────────┐    │
│       │                     │  worker  │  worker  │ worker  │   │
│       │                     │ replica1 │ replica2 │ replica3│   │
│       │                     └──────────────────────────────┘    │
│       │                                  │ SMTP                 │
│  Namecheap                               │ (TLS:587)            │
│  Private Email ◀─────────────────────────┘                      │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Why not poll IMAP from multiple replicas?

IMAP has no locking mechanism. If two pollers both call `SEARCH UNSEEN` at the same moment, they will both see the same unread emails before either has had a chance to mark them `SEEN`. The result: every email gets processed and replied to twice.

**Solution:** The Poller is always `replicas: 1`. It's cheap (just I/O-bound polling), so one replica is more than enough. The expensive work (LLM inference, SMTP) happens in the Workers, which are the ones you scale.

---

## Project Structure

```
Customer_Complaint_Responder/
├── docker-compose.yml          # Orchestrates all services
├── .env                        # Your credentials (never commit this)
├── .env.example                # Template — copy to .env and fill in
└── apps/
    ├── poller/                 # IMAP poller microservice
    │   ├── Dockerfile
    │   ├── pyproject.toml
    │   └── app/
    │       ├── core/
    │       │   └── config.py   # IMAP + Redis settings
    │       └── main.py         # Poll loop
    └── worker/                 # AI worker microservice
        ├── Dockerfile
        ├── pyproject.toml
        └── app/
            ├── core/
            │   └── config.py   # Gemini + SMTP + Redis settings
            ├── services/
            │   ├── agent/
            │   │   ├── agent.py    # LangGraph graph definition
            │   │   └── prompts.py  # Classify + respond prompts
            │   └── email.py        # SMTP sender
            └── main.py             # Stream consumer loop
```

---

## The Apps

### Poller

**Location:** `apps/poller/`  
**Replicas:** Always **1** — never scale this above 1  
**Dependencies:** `imap-tools`, `redis`, `pydantic-settings`

The Poller runs a simple infinite loop:

```
while True:
    connect to IMAP (SSL)
    get all UNSEEN email UIDs          # fast lookup (no content download)
    for each uid:
        XADD email:inbound * uid=<uid> # publish lightweight UID to Redis
        mark SEEN on success           # claim email only after queued
    sleep(IMAP_POLL_INTERVAL)
```

**Key design choice — Lazy fetching and at-least-once queueing:**  
The Poller uses a lightweight IMAP search for unseen email UIDs, pushes them to Redis Stream first, and only marks them `\Seen` on the mail server upon a successful `XADD`. This avoids downloading large MIME bodies inside the poller. If a failure occurs before the message is queued, it remains unseen and is retried. Once in the stream, the worker pool handles the retrieval and processing.

---

### Worker

**Location:** `apps/worker/`  
**Replicas:** **2 by default**, safe to scale to any number  
**Dependencies:** `langchain`, `langchain-google-genai`, `langgraph`, `redis`, `pydantic-settings`

The Worker runs a blocking Redis Stream consumer loop:

```
on startup:
    XGROUP CREATE email:inbound complaint-workers $ MKSTREAM  # idempotent

while True:
    messages = XREADGROUP GROUP complaint-workers <hostname> COUNT 10 BLOCK 5000
    for each message:
        connect to IMAP, fetch message by UID
        if EXISTS replied:{message_id}:
            XACK and skip             # already handled
        run LangGraph AI pipeline     # classify + respond
        send SMTP reply               # Namecheap outgoing mail
        SET replied:{message_id} 1 EX 2592000   # 30-day dedupe key
        XACK                          # remove from Pending Entry List
```

Each Worker uses its **container hostname** as the consumer name (`socket.gethostname()`). Docker assigns a unique hostname to each container, so replicas automatically register as distinct consumers in the group without any manual configuration.

---

## Deduplication — How Duplicate Replies Are Prevented

Three independent layers work together to ensure each complaint gets exactly one reply:

| Layer | Where | Mechanism | Guards Against |
|---|---|---|---|
| **1. IMAP claim** | Poller | `mark_seen=True` on fetch | Two poller restarts racing on the same UNSEEN email |
| **2. Stream delivery** | Redis | `XREADGROUP` consumer groups | Two worker replicas pulling the same stream entry |
| **3. Redis dedupe key** | Worker | `EXISTS replied:{Message-ID}` | Any edge case redelivery, crash recovery, or stream replay |

The `Message-ID` email header is the unique identifier used for the dedupe key. It is set by the sender's mail client and is guaranteed to be globally unique per RFC 5322.

**What happens if a Worker crashes mid-flight?**  
The `XACK` command is only sent after the reply has been successfully sent and the dedupe key has been written. If a worker crashes before `XACK`, the stream entry stays in the **Pending Entry List (PEL)**. On restart, another worker can reclaim it via `XAUTOCLAIM`. Since the dedupe key was never written, the email will be processed again — which is the safe fallback.

---

## LangGraph AI Pipeline

The Worker runs each complaint through a two-node LangGraph graph:

```
START
  │
  ▼
[classify]  ── Gemini ──▶  complaint_type:
                           "delivery" | "refund" | "product issue" | "other"
  │
  ▼
[respond]   ── Gemini ──▶  response: professional, empathetic reply text
  │
  ▼
END
```

**Thread-aware conversation history:**  
Each email thread is identified by a `thread_id` derived from the email's `In-Reply-To` or `References` headers (or a hash of `from + subject` as fallback). LangGraph's `MemorySaver` checkpointer stores conversation state per `thread_id`, so follow-up emails from the same customer are answered with full context of the prior exchange.

**Prompts** (in `apps/worker/app/services/agent/prompts.py`):

- **Classify prompt** — asks the model to return one of: `delivery`, `refund`, `product issue`, `other`
- **Response prompt** — asks the model to generate a single professional, empathetic support reply given the complaint text and its category

---

## Environment Variables

Copy `.env.example` to `.env` and fill in your real values:

```bash
cp .env.example .env
```

| Variable | Used By | Description | Default |
|---|---|---|---|
| `GEMINI_API_KEY` | worker | Google Gemini API key | *(required)* |
| `IMAP_HOST` | both | IMAP server hostname | `mail.privateemail.com` |
| `IMAP_PORT` | both | IMAP server port (SSL) | `993` |
| `IMAP_USERNAME` | both | Email address to poll | *(required)* |
| `IMAP_PASSWORD` | both | Email account password | *(required)* |
| `IMAP_POLL_INTERVAL` | poller | Seconds between inbox checks | `60` |
| `SMTP_HOST` | worker | SMTP server hostname | `mail.privateemail.com` |
| `SMTP_PORT` | worker | SMTP port (STARTTLS) | `587` |
| `SMTP_USERNAME` | worker | SMTP login username | *(required)* |
| `SMTP_PASSWORD` | worker | SMTP login password | *(required)* |
| `SMTP_FROM_EMAIL` | worker | Reply-from email address | *(required)* |
| `SMTP_FROM_NAME` | worker | Reply-from display name | `Customer Support` |
| `REDIS_URL` | both | Redis connection string | `redis://redis:6379/0` |
| `REDIS_STREAM_NAME` | both | Stream key name | `email:inbound` |
| `REDIS_CONSUMER_GROUP` | worker | Consumer group name | `complaint-workers` |

> **Note:** `REDIS_URL` is automatically set to `redis://redis:6379/0` by `docker-compose.yml` via the `environment:` block, so you don't need to set it in `.env` for Docker usage.

---

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) + [Docker Compose](https://docs.docker.com/compose/)
- A Namecheap Private Email account with an inbox to monitor
- A [Google AI Studio](https://aistudio.google.com) API key (Gemini)

### 1. Clone and configure

```bash
git clone <your-repo-url>
cd Customer_Complaint_Responder

cp .env.example .env
# Open .env and fill in your real credentials
```

### 2. Build images

```bash
docker compose build
```

### 3. Start all services

```bash
docker compose up -d
```

This starts:
- `redis` — Redis 7 with AOF persistence
- `poller` — 1 replica, polls your inbox every 60 seconds
- `worker` — 2 replicas, processes complaints from the stream

### 4. Verify everything is running

```bash
docker compose ps
```

Expected output:
```
NAME                          STATUS    PORTS
customer_complaint...-redis   Up        0.0.0.0:6379->6379/tcp
customer_complaint...-poller  Up
customer_complaint...-worker  Up (x2)
```

### 5. Send a test email

Send an email to your support inbox (the address in `IMAP_USERNAME`). Within `IMAP_POLL_INTERVAL` seconds you should see:

```
# In poller logs:
2026-06-23T13:30:01 [poller] INFO Published UID 45 → stream entry 1234567890-0 and marked SEEN.

# In worker logs:
2026-06-23T13:30:02 [worker/abc123] INFO Received job for email UID 45 (stream_id=1234567890-0)
2026-06-23T13:30:03 [worker/abc123] INFO Fetched email from customer@example.com (subject='Order not arrived', message_id=<...>)
2026-06-23T13:30:03 [worker/abc123] INFO Running LangGraph complaint handler for thread_id=...
2026-06-23T13:30:05 [worker/abc123] INFO Classified as: delivery
2026-06-23T13:30:06 [worker/abc123] INFO Successfully sent email to customer@example.com
2026-06-23T13:30:06 [worker/abc123] INFO Marked Message-ID <...> as replied (TTL=2592000s).
```

### 6. Stop

```bash
docker compose down        # stops containers, keeps Redis data
docker compose down -v     # also deletes the Redis volume (wipes stream + dedupe keys)
```

---

## Scaling

The Worker is the only service that should be scaled. The Poller must always stay at 1 replica.

```bash
# Run 4 worker replicas
docker compose up -d --scale worker=4

# Check active consumers in the Redis stream group
docker compose exec redis redis-cli XINFO CONSUMERS email:inbound complaint-workers
```

**For Kubernetes (future):** Use a KEDA `ScaledObject` targeting the `email:inbound` stream length to automatically scale the Worker deployment based on queue depth. Keep the Poller as a standard `Deployment` with `replicas: 1`.

---

## Logs

Watch all services in real time:

```bash
docker compose logs -f
```

Watch a specific service:

```bash
docker compose logs -f poller
docker compose logs -f worker
```

Inspect the Redis stream directly:

```bash
# Number of entries in the stream
docker compose exec redis redis-cli XLEN email:inbound

# Last 10 entries
docker compose exec redis redis-cli XREVRANGE email:inbound + - COUNT 10

# Pending (unacknowledged) messages in the consumer group
docker compose exec redis redis-cli XPENDING email:inbound complaint-workers - + 10

# Check if a specific Message-ID has been replied to
docker compose exec redis redis-cli EXISTS "replied:<message-id>"
```

---

## Tech Stack

| Component | Technology |
|---|---|
| AI Model | Google Gemini (`gemini-2.0-flash`) |
| AI Orchestration | LangGraph + LangChain |
| Message Queue | Redis 7 Streams (consumer groups) |
| IMAP Client | `imap-tools` |
| SMTP | Python `smtplib` (STARTTLS) |
| Email Provider | Namecheap Private Email |
| Config | `pydantic-settings` |
| Package Manager | `uv` |
| Container Runtime | Docker Compose |
