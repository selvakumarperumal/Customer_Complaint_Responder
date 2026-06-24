# Redis Streams & Consumer Groups: In-Depth Architecture

This document provides a comprehensive, technical guide on how **Redis**, **Redis Streams**, and **Consumer Groups** function within the Customer Complaint Responder (CCR) system. It outlines the role Redis plays, explains the mechanics of its data structures, and walks through the exact commands and code snippets used in the application.

---

## 1. Architectural Overview

In the CCR system, Redis 7 acts as both a **durable message broker** and a **de-duplication database**.

1. **Decoupled Architecture**: The system splits email polling and complaint processing into two microservices:
   - **Poller**: A lightweight service (strictly `replicas: 1`) that watches the Namecheap IMAP inbox for new emails, extracts their `UID`s, and pushes them to Redis.
   - **Worker**: A processor that pulls `UID`s from Redis, fetches the full email bodies, runs the LangGraph AI agent, sends SMTP replies, and acknowledges the job.
2. **Horizontal Scaling**: You can spin up multiple Worker replicas. Redis Streams distribute the queue load across all active workers, ensuring that each email is processed by exactly **one** worker.
3. **At-Least-Once Delivery**: Messages are never lost, even if a worker crashes mid-process.
4. **Idempotency Safeguard**: If a network glitch causes an email to be redelivered or replayed, a Redis key-value cache (`replied:{Message-ID}`) prevents duplicate AI replies from being sent to customers.

---

## 2. Mermaid Execution Flow

The following sequence diagram illustrates how a message flows from the Poller, through the Redis Stream and Consumer Group, into a Worker replica, and how reliability (PEL) and de-duplication are enforced.

```mermaid
flowchart TD
    %% Styling Classes
    classDef producer fill:#d1e7dd,stroke:#0f5132,stroke-width:2px;
    classDef broker fill:#f8d7da,stroke:#842029,stroke-width:2px;
    classDef consumer fill:#cff4fc,stroke:#087990,stroke-width:2px;
    classDef external fill:#e2e3e5,stroke:#41464b,stroke-width:2px;

    %% Nodes
    IMAP["📧 Namecheap IMAP Server"]:::external
    
    subgraph PollerMicroservice ["Poller Microservice (1 Replica)"]
        Poller["🔍 IMAP Poller Loop"]:::producer
    end

    subgraph RedisBroker ["Redis 7 Message Broker"]
        Stream[("📝 Stream: email:inbound")]:::broker
        
        subgraph Group ["Consumer Group: complaint-workers"]
            PEL1["📋 Worker 1 Pending Entry List (PEL)"]:::broker
            PEL2["📋 Worker 2 Pending Entry List (PEL)"]:::broker
        end
        
        DedupeCache[("💾 Deduplication Cache<br/>replied:Message-ID")]:::broker
    end

    subgraph WorkerMicroservice ["Worker Microservice (N Replicas)"]
        Worker1["⚙️ Worker Replica 1"]:::consumer
        Worker2["⚙️ Worker Replica 2"]:::consumer
    end
    
    LLM["🤖 LangGraph Agent (Gemini)"]:::external
    SMTP["📤 Namecheap SMTP Server"]:::external

    %% Connections
    IMAP -->|1. Fetch UNSEEN UIDs| Poller
    Poller -->|2. XADD email:inbound * uid=123| Stream
    Poller -->|3. Mark SEEN| IMAP

    Stream -->|4. XREADGROUP (Assigns to Worker 1)| Worker1
    Stream -.->|Locks message in| PEL1

    Stream -->|4. XREADGROUP (Assigns to Worker 2)| Worker2
    Stream -.->|Locks message in| PEL2

    Worker1 -->|5. EXISTS replied:msg_id?| DedupeCache
    Worker1 -->|6. Fetch Email Body by UID| IMAP
    Worker1 -->|7. Run Agent Chain| LLM
    Worker1 -->|8. Send SMTP Reply| SMTP
    Worker1 -->|9. SET replied:msg_id '1' EX 30d| DedupeCache
    Worker1 -->|10. XACK email:inbound complaint-workers entry_id| Stream
    Worker1 -.->|Removes message from| PEL1
```

---

## 3. What is a Redis Stream?

A **Redis Stream** is a specialized, append-only data structure that models a log file. It behaves similarly to Apache Kafka topics or AWS Kinesis shards.

### Core Properties:
- **Append-Only**: You can only add new elements to the end of the stream.
- **Persistent & Durable**: Unlike Redis lists or Pub/Sub channels (which are volatile), entries in a Redis Stream are written to disk if AOF (Append-Only File) or RDB (Snapshotting) persistence is configured (which we do in `docker-compose.yml` via the `--appendonly yes` command).
- **Time-Based ID Generation**: Every entry in a stream is automatically assigned a unique ID in the format `<timestamp>-<sequence>`.
  - For example, `1719220035041-0` indicates the entry was created at timestamp `1719220035041` (milliseconds since Unix epoch) and is the `0`th entry generated at that exact millisecond.
- **Payload Structure**: Each stream entry is structured as a dictionary of key-value pairs (e.g. `{"uid": "23"}`).

### Stream vs. Lists vs. Pub/Sub

| Feature | Redis Lists (`LPUSH`/`RPOP`) | Redis Pub/Sub (`PUBLISH`/`SUBSCRIBE`) | Redis Streams (`XADD`/`XREAD`) |
| :--- | :--- | :--- | :--- |
| **Durable Storage** | Yes (if saved) | No (Fire-and-forget; lost if consumer is offline) | **Yes** (durable, historical log) |
| **Multiplexing** | No (One message goes to only one reader) | Yes (Every subscriber receives every message) | **Yes** (Multiple consumers can read the same stream independently) |
| **Consumer Groups** | No | No | **Yes** (Distributed load-balancing + acknowledgments) |
| **Reliability ACK** | No (Popped messages disappear instantly) | No | **Yes** (Pending Entry List keeps messages safe until `XACK`) |

---

## 4. What is a Redis Consumer Group?

A **Consumer Group** is a logical partition/view layered on top of a Redis Stream. It allows multiple workers to act as a single unit to cooperatively consume messages.

### Key Concepts under the Hood:

1. **Load Balancing**:
   Within a consumer group, each message is delivered to **only one** consumer in that group. When `Worker 1` pulls a message, `Worker 2` will not see it during its polling loop.
2. **Consumer Tracking**:
   Redis remembers the state of each consumer (identified by its hostname). It knows which worker replica requested which message and when.
3. **Pending Entry List (PEL)**:
   This is the backbone of reliability. When a consumer reads a message using `XREADGROUP`, Redis adds that message ID to that specific consumer's **PEL**.
   - The message remains in the PEL until the worker explicitly sends an acknowledgment command (`XACK`).
   - If the worker crashes or loses network connectivity mid-process, the message is **never lost**. It remains in the PEL.
   - Another worker (or a monitoring process) can inspect the PEL using `XPENDING` and claim ownership of the stuck message using `XCLAIM` or `XAUTOCLAIM` to re-process it.
4. **Read Positions**:
   The consumer group maintains a state variable representing the last message ID delivered to *any* consumer in the group. This is represented by the special position character `>` when reading.

---

## 5. Message Lifecycle in CCR

Here is the exact lifecycle of an email message passing through our architecture:

```
[Namecheap IMAP]
       │ (UNSEEN email arrives)
       ▼
[Poller Service]
       │ 1. Connects to IMAP, finds UID
       │ 2. Publishes to Redis Stream via XADD
       │ 3. Marks IMAP email as SEEN (read)
       ▼
[Redis Stream] ──(Saves entry e.g. "1719220035041-0")
       │
       ▼ [Consumer Group: "complaint-workers"]
       │ (Assigns message to Worker 1; moves entry to Worker 1's PEL)
       ▼
[Worker Replica 1]
       │ 1. Receives message via XREADGROUP
       │ 2. Extracts UID, fetches email envelope headers from IMAP
       │ 3. Checks de-duplication: EXISTS "replied:<Message-ID>"
       │    ├── IF EXISTS (True): Skip processing, call XACK
       │    └── IF NOT EXISTS (False): Continue
       │ 4. Fetches thread history, passes to LangGraph AI Agent
       │ 5. Sends SMTP reply to customer via SMTP server
       │ 6. Caches dedupe key: SET "replied:<Message-ID>" "1" EX 30 days
       │ 7. Acknowledges message: XACK
       ▼
[Redis Broker] ──(Removes entry from Worker 1's PEL)
```

---

## 6. Command-by-Command Code Analysis

Below is an in-depth breakdown of the exact Redis commands executed by our codebase.

### A. Publishing to the Stream (`XADD`)
Used in the poller service to queue a lightweight IMAP email UID.

#### Code Snippet:
*File: [apps/poller/app/main.py](file:///home/selva/Documents/langchain-projects/Customer_Complaint_Responder/apps/poller/app/main.py#L66-L67)*
```python
payload = {"uid": uid}
stream_id = r.xadd(settings.REDIS_STREAM_NAME, payload)
```

#### Redis Command Under the Hood:
```bash
XADD email:inbound * uid 23
```

#### Parameters & Execution:
- **`email:inbound`**: The name of the stream key (configured via `REDIS_STREAM_NAME`).
- **`*`**: Instructs Redis to automatically generate a unique, time-based ID (e.g. `1719220035041-0`). If a specific ID is desired (for example, to enforce strict external identifiers), it can be provided, but `*` is the standard for queueing.
- **`uid 23`**: The field-value pair representing the payload.
- **Auto-creation**: If the stream `email:inbound` does not exist when `XADD` is run, Redis **automatically creates it**.

---

### B. Creating the Consumer Group (`XGROUP CREATE`)
Used during worker startup to initialize the processing cluster.

#### Code Snippet:
*File: [apps/worker/app/main.py](file:///home/selva/Documents/langchain-projects/Customer_Complaint_Responder/apps/worker/app/main.py#L61-L66)*
```python
r.xgroup_create(
    name=settings.REDIS_STREAM_NAME,
    groupname=settings.REDIS_CONSUMER_GROUP,
    id="$",
    mkstream=True,
)
```

#### Redis Command Under the Hood:
```bash
XGROUP CREATE email:inbound complaint-workers $ MKSTREAM
```

#### Parameters & Execution:
- **`email:inbound`**: Target stream key.
- **`complaint-workers`**: The name of the consumer group.
- **`$`**: The starting offset for the group. 
  - `$` means **"only read new messages arriving after the group is created"**.
  - If you wanted workers to process all historical messages currently sitting in the stream from the very beginning, you would pass `"0"` instead of `"$"` as the ID.
- **`MKSTREAM` / `mkstream=True`**: Tells Redis to automatically create the stream key if it doesn't exist yet. This prevents errors if workers start up before the poller has pushed any messages.
- **Error Handling**: If the group already exists, Redis returns a `BUSYGROUP` error. Our code catches this error safely and ignores it:
  ```python
  except redis.exceptions.ResponseError as exc:
      if "BUSYGROUP" in str(exc):
          logger.debug("Consumer group already exists — OK.")
  ```

---

### C. Reading from the Group (`XREADGROUP`)
Used in the worker's polling loop to fetch messages.

#### Code Snippet:
*File: [apps/worker/app/main.py](file:///home/selva/Documents/langchain-projects/Customer_Complaint_Responder/apps/worker/app/main.py#L224-L230)*
```python
response = r.xreadgroup(
    groupname=settings.REDIS_CONSUMER_GROUP,
    consumername=_hostname,
    streams={settings.REDIS_STREAM_NAME: ">"},
    count=10,
    block=5000,
)
```

#### Redis Command Under the Hood:
```bash
XREADGROUP GROUP complaint-workers worker-pod-xyz COUNT 10 BLOCK 5000 STREAMS email:inbound >
```

#### Parameters & Execution:
- **`GROUP complaint-workers`**: Tells Redis which consumer group is requesting the data.
- **`worker-pod-xyz`**: The unique name of the consumer replica (we use the container's `hostname` to distinguish replicas).
- **`COUNT 10`**: Max number of messages to fetch in a single call.
- **`BLOCK 5000`**: Blocking timeout in milliseconds. If the stream is empty, the worker will sleep/wait for up to 5 seconds before returning an empty list, saving CPU cycles.
- **`STREAMS email:inbound >`**: Specifies the stream and position to read.
  - **`>`**: A critical, special character. It tells Redis: **"Deliver only messages that have never been delivered to anyone else in this consumer group."** This triggers the load-balancing mechanism.
  - If we had passed `"0"` instead of `">"`, Redis would ignore new messages and instead return all messages that are **currently pending** (in this specific consumer's PEL) but have not yet been acknowledged (`XACK`).

---

### D. Checking Deduplication Cache (`EXISTS`)
Used in the worker to verify if the email has already been processed.

#### Code Snippet:
*File: [apps/worker/app/main.py](file:///home/selva/Documents/langchain-projects/Customer_Complaint_Responder/apps/worker/app/main.py#L159-L160)*
```python
key = _dedupe_key(message_id)
if r.exists(key):
```

#### Redis Command Under the Hood:
```bash
EXISTS replied:<message_id_string>
```

#### Parameters & Execution:
- **`replied:<Message-ID>`**: The key constructed using the email's unique RFC 2822 `Message-ID` header.
- **Returns**: `1` if the key exists (already processed), `0` otherwise.
- **Why it matters**: If a worker crashes *after* sending the SMTP reply but *before* acknowledging the stream entry, the stream message will be retried (or reclaimed). The next worker will read the stream entry, extract the UID, fetch the headers, see that `replied:Message-ID` exists, and immediately call `XACK` to clean up the stream without sending a duplicate response to the customer.

---

### E. Writing to Deduplication Cache (`SET ... EX`)
Used in the worker after successfully sending the SMTP reply to register the message ID.

#### Code Snippet:
*File: [apps/worker/app/main.py](file:///home/selva/Documents/langchain-projects/Customer_Complaint_Responder/apps/worker/app/main.py#L189)*
```python
r.set(_dedupe_key(message_id), "1", ex=settings.REDIS_DEDUPE_TTL)
```

#### Redis Command Under the Hood:
```bash
SET replied:<message_id_string> "1" EX 2592000
```

#### Parameters & Execution:
- **`EX 2592000`**: Sets an expiration (Time-to-Live) on the key in seconds. We default to `2592000` seconds (30 days).
- **TTL cleanup**: Redis automatically deletes keys after they expire. This ensures that the Redis database memory usage doesn't grow infinitely, while keeping a wide enough window to protect against delayed email retries or client email client threading issues.

---

### F. Acknowledging Message Processing (`XACK`)
Used to finalize the job and remove it from tracking.

#### Code Snippet:
*File: [apps/worker/app/main.py](file:///home/selva/Documents/langchain-projects/Customer_Complaint_Responder/apps/worker/app/main.py#L192)*
```python
r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
```

#### Redis Command Under the Hood:
```bash
XACK email:inbound complaint-workers 1719220035041-0
```

#### Parameters & Execution:
- **`email:inbound`**: The stream key.
- **`complaint-workers`**: The consumer group name.
- **`1719220035041-0`**: The unique stream entry ID that was processed.
- **Under the hood**: Redis receives the `XACK` call and immediately locates the entry ID in the consumer's Pending Entry List (PEL). It deletes it from the PEL. This signifies that the message is fully processed and no further worker needs to worry about it.

---

## 7. Command Line Diagnostics

Use these commands directly on the Redis CLI to inspect the stream and monitor worker behavior.

### Shell Access to Redis:
```bash
docker compose exec redis redis-cli
```

### 1. View Stream Size
Check how many entries are currently in the stream.
```bash
XLEN email:inbound
```

### 2. Inspect Consumer Group Status
Check which consumer groups exist, how many consumers are registered, and how many items are pending.
```bash
XINFO GROUPS email:inbound
```
*Expected Output:*
```
1) 1) "name"
   2) "complaint-workers"
   3) "consumers"
   4) (integer) 2          # 2 active workers running
   5) "pending"
   6) (integer) 0          # 0 items currently unacknowledged
   7) "last-delivered-id"
   8) "1719220035041-0"
```

### 3. Inspect Individual Consumers
Check detailed statistics for each worker container (hostname).
```bash
XINFO CONSUMERS email:inbound complaint-workers
```
*Expected Output:*
```
1) 1) "name"
   2) "worker-pod-xyz-1"   # Hostname of consumer 1
   3) "pending"
   4) (integer) 0          # Pending items for this consumer
   5) "idle"
   6) (integer) 45000      # Milliseconds since last active pull
```

### 4. Inspect Pending Entries (PEL)
Find messages that have been delivered to workers but have not yet been `XACK`ed. This is useful for identifying frozen workers.
```bash
XPENDING email:inbound complaint-workers - + 10
```
This shows the entry ID, the consumer that holds it, the millisecond duration it has been idle, and the number of times it has been delivered.

### 5. Read Raw Historical Stream Entries
Inspect the latest 10 messages stored in the stream, regardless of their consumption state.
```bash
XREVRANGE email:inbound + - COUNT 10
```

### 6. Verify De-duplication Cache
Check if a specific email message has been replied to:
```bash
EXISTS "replied:<message-id-here>"
```
