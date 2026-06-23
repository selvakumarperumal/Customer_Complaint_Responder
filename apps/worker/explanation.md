# AI Worker Microservice — Code & Flow Explanation

This document explains the internal scripts, module dependencies, and execution flow of the **AI Worker** microservice.

---

## Execution Flow Diagram

The following Mermaid diagram outlines how a worker pod processes a stream entry (UID job) from Redis:

```mermaid
graph TD
    Start([Job Dequeued from Stream]) --> LoginIMAP[Login to Namecheap IMAP]
    LoginIMAP --> FetchTarget[Fetch Target Email by UID]
    
    FetchTarget -->|Not Found| AckSkip[ACK & Skip]
    
    FetchTarget -->|Found| Normalize[Normalize Subject: strip Re:, Fwd:, etc.]
    Normalize --> SearchThread[Search Inbox for all matching subjects]
    SearchThread --> SortChron[Sort messages chronologically]
    
    subgraph Conversation Compilation
        SortChron --> LoopMsgs[For each message in thread]
        LoopMsgs --> StripQuotes[Strip lines starting with '>']
        StripQuotes --> FormatTranscript[Append to Thread History Transcript]
    end
    
    FormatTranscript --> CloseIMAP[Close IMAP Connection]
    
    CloseIMAP --> CheckDedupe{Redis EXISTS replied:Message-ID?}
    CheckDedupe -->|Yes| AckSkip
    CheckDedupe -->|No| RunAgent[Run LangGraph Agent]
    
    subgraph LangGraph Pipeline
        RunAgent --> Classify[Classify: category_prompt]
        Classify --> Generate[Generate Response: response_prompt]
    end
    
    Generate --> SendSMTP[Send Outbound Email via Namecheap SMTP]
    
    SendSMTP -->|Success| SaveDedupe[SET replied:Message-ID EX 30 days]
    SaveDedupe --> ACK[XACK Stream Entry]
    
    SendSMTP -->|Failure| LogError[Log Error & Do NOT ACK]
```

---

## Script Breakdown

### 1. `app/core/config.py`
Defines the worker configuration settings using **Pydantic Settings**. Loads settings (like `GEMINI_API_KEY`, SMTP host/creds, IMAP host/creds, and Redis configs) from the shared `.env` file at the root.

### 2. `app/services/email.py`
Contains the utility for sending outbound emails:
*   **`send_support_email(...) -> bool`**:
    *   Constructs a standard multi-part MIME email message (`MIMEMultipart`).
    *   Appends the AI-generated reply body as plain text.
    *   **In-Inbox Threading**: Injects standard `In-Reply-To` and `References` headers using the incoming email's `Message-ID` to ensure mail clients group the reply under the customer's original email.
    *   Establishes an SMTP connection (supporting direct `SMTP_SSL` on port `465` or falling back to standard `starttls()` on port `587`), logs in, dispatches, and disconnects.

### 3. `app/services/agent/prompts.py`
Contains the Chat Prompt Templates used by the LLM:
*   **`category_prompt`**: Instructs Gemini to classify the conversation thread into one of: `delivery`, `refund`, `product issue`, `other`.
*   **`response_prompt`**: Persona instructions for the customer service assistant, taking the conversation thread history and the category classification to write a single professional reply.

### 4. `app/services/agent/agent.py`
Sets up the LangGraph processing workflow:
*   **`ComplaintState`**: Declares the state container with keys `complaint` (the incoming compiled history thread), `complaint_type` (category), and `response` (resulting reply).
*   **Workflow setup**: Connects the `classify` node and the `respond` node sequentially:
    ```
    START ──▶ [classify] ──▶ [respond] ──▶ END
    ```
*   **`process_complaint(complaint_text, ...)`**: Compiles the graph and executes it in a single stateless execution, invoking the nodes and returning the final dictionary containing the category and reply response.

### 5. `app/main.py`
This is the core worker loop orchestrating the whole process:
*   **`_ensure_consumer_group(r)`**: Ensures the Redis Stream consumer group exists.
*   **`_handle_message(r, stream_entry_id, fields)`**:
    1. Extracts the email `uid` from the stream.
    2. Logs into IMAP, normalizes the subject, and pulls all messages matching it.
    3. Sorts them, strips the quoted `>` content, compiles the `thread_history`, and logs out.
    4. Performs the `replied:{message_id}` deduplication check in Redis.
    5. Calls the LangGraph agent.
    6. Sends the reply via SMTP.
    7. Marks the `message_id` as replied in Redis and sends the `XACK` to remove the item from the queue.
*   **`run()`**: Listens continuously via `r.xreadgroup` in an infinite loop, routing incoming jobs to `_handle_message`.
