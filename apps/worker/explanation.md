# AI Worker Microservice — Code & Flow Explanation

This document explains the internal scripts, source code, and execution flow of the **AI Worker** microservice.

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

## Detailed Code & Snippet Breakdown

### 1. Subject Normalization & Thread Fetching (`app/main.py`)

When processing a message, we normalize the subject and search the mailbox for all messages belonging to that email thread.

```python
            # Normalize the subject to find all messages in the same conversation thread
            def normalize_subject(subj: str) -> str:
                s = subj.lower()
                for prefix in ["re:", "fwd:", "fw:"]:
                    if s.startswith(prefix):
                        s = s[len(prefix):].strip()
                return s.strip()

            norm_subj = normalize_subject(subject)

            # Fetch all messages in the current folder (INBOX) matching this normalized subject
            # This fetches the entire history of customer emails in this thread
            thread_messages = list(mailbox.fetch(AND(subject=norm_subj)))
            thread_messages.sort(key=lambda m: m.date or m.date_str)
```

#### Snippet Breakdown:
*   **`normalize_subject`**: Email replies typically append prefixes like `Re:` or `Fwd:` to the subject. Stripping these prefixes (case-insensitively) gives us a clean root subject (e.g. `"order status #101"`).
*   **`mailbox.fetch(AND(subject=norm_subj))`**: Queries the IMAP server for all messages in the folder containing that normalized subject string. This retrieves the historical customer emails sent under this conversation chain.
*   **`thread_messages.sort(...)`**: Email delivery can occasionally be out of order. Sorting the messages by their date header ensures that we reconstruct the history in exact chronological order.

---

### 2. Thread Transcript Cleaning (`app/main.py`)

We format the emails into a single transcript while cleaning out duplicated quoted replies to minimize LLM token usage and prevent confusion.

```python
            # Construct the chronological thread history
            thread_history = ""
            for m in thread_messages:
                m_sender = m.from_
                m_date = m.date.strftime("%Y-%m-%d %H:%M:%S") if m.date else "Unknown Date"
                m_body = m.text.strip() if m.text else m.html.strip() if m.html else ""
                
                # Clean body part: remove lines starting with '>' (quoted reply history)
                # to prevent duplicating the conversation history in the prompt.
                clean_lines = [line for line in m_body.splitlines() if not line.strip().startswith(">")]
                clean_body = "\n".join(clean_lines).strip()
                
                thread_history += f"From: {m_sender} (Date: {m_date})\nSubject: {m.subject}\nContent:\n{clean_body}\n\n---\n\n"
```

#### Snippet Breakdown:
*   **`clean_lines` list comprehension**: Most email clients include the previous email exchange appended at the bottom, quoted with standard `>` characters. If we simply concatenate the raw bodies, the prompt would contain the original messages multiple times. Stripping out lines that start with `>` removes all quoted fragments, leaving only the newly written content for each message in the thread.
*   **`thread_history += ...`**: Joins each cleaned message with metadata headers (`From` and `Date`), creating a clean chat-like transcript of the conversation to feed into the LLM.

---

### 3. Redis-Based Deduplication Check (`app/main.py`)

Guarantees that we never send a duplicate reply to a customer under any circumstances.

```python
        # ── 2. Dedupe check ─────────────────────────────────────────────────
        if message_id:
            key = _dedupe_key(message_id)
            if r.exists(key):
                logger.warning(
                    "Already replied to Message-ID %s — skipping duplicate.", message_id
                )
                r.xack(settings.REDIS_STREAM_NAME, settings.REDIS_CONSUMER_GROUP, stream_entry_id)
                return
        else:
            logger.warning("Email has no Message-ID header — dedupe not possible.")
```

#### Snippet Breakdown:
*   **`message_id`**: The `Message-ID` header is globally unique and generated by the sender's mail client (compliant with RFC 5322).
*   **`r.exists(key)`**: Checks if a key matching `replied:{message_id}` exists in Redis. If a worker pod crashes or the stream message is redelivered after a reply has been successfully sent, this check prevents duplicate processing.
*   **`r.xack(...)`**: If a duplicate is detected, the worker acknowledges the stream entry immediately to remove it from the queue and returns.

---

### 4. LangGraph Nodes & Chains (`app/services/agent/agent.py`)

This script declares the LangGraph State Graph and executes the Gemini chains.

```python
_classify_chain = category_prompt | _llm
_response_chain = response_prompt | _llm

def _node_classify(state: ComplaintState) -> dict:
    """Classify the complaint into a category."""
    ai_response = _classify_chain.invoke({"input": state["complaint"]})
    return {"complaint_type": ai_response.text.strip().lower()}


def _node_respond(state: ComplaintState) -> dict:
    """Generate a professional response to the complaint."""
    ai_response = _response_chain.invoke({
        "complaint": state["complaint"],
        "complaint_type": state["complaint_type"],
    })
    return {"response": ai_response.text}
```

#### Snippet Breakdown:
*   **`_classify_chain` and `_response_chain`**: Created using LangChain Expression Language (LCEL) piping `prompt | model`.
*   **`_node_classify`**: Runs the classification chain. Pass the constructed `thread_history` as the input. Gemini returns the category name (`delivery`, `refund`, `product issue`, or `other`). The node updates the graph state with `complaint_type`.
*   **`_node_respond`**: Runs the response chain. Receives the `complaint` (the thread transcript) and the classified `complaint_type` to generate the email response text.

---

### 5. SMTP Threading Headers (`app/services/email.py`)

Injects RFC headers to keep emails linked together inside the customer's email client.

```python
        # Create message
        msg = MIMEMultipart()
        msg["From"] = f"{settings.SMTP_FROM_NAME} <{settings.SMTP_FROM_EMAIL}>"
        msg["To"] = to_email
        msg["Subject"] = subject

        if in_reply_to:
            msg["In-Reply-To"] = in_reply_to
        if references:
            msg["References"] = references
```

#### Snippet Breakdown:
*   **`In-Reply-To`**: Sets the outgoing email header `In-Reply-To` to match the incoming email's `Message-ID`.
*   **`References`**: Sets the outgoing email header `References` to include the preceding references chain plus the incoming `Message-ID`.
*   **Why this is crucial**: Linking these IDs is what allows email clients (like Gmail or Outlook) to visually bundle our automated replies inside the customer's same thread interface instead of generating fragmented, independent emails.
