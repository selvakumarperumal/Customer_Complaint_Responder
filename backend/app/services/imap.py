from imap_tools import MailBox, AND
import logging
import asyncio
from app.core.config import settings
from app.services.agent.agent import process_complaint
from app.services.email import send_support_email

logger = logging.getLogger(__name__)

def check_and_process_emails():
    """Poll the IMAP server and process any new messages using imap-tools."""
    username = settings.IMAP_USERNAME or settings.SMTP_USERNAME
    password = settings.IMAP_PASSWORD or settings.SMTP_PASSWORD

    if not all([username, password]):
        logger.warning("IMAP credentials are not fully configured. Skipping poller run.")
        return

    try:
        # Use MailBox context manager to handle connection, login, selection, and logout
        with MailBox(settings.IMAP_HOST, port=settings.IMAP_PORT, timeout=15).login(username, password) as mailbox:
            # Fetch all unseen emails and automatically mark them as seen (mark_seen=True)
            for msg in mailbox.fetch(AND(seen=False), mark_seen=True):
                try:
                    subject = msg.subject
                    from_email = msg.from_
                    
                    if not from_email:
                        continue

                    # Safely retrieve threading headers from original message object
                    msg_id = msg.obj.get("Message-ID", "")
                    references = msg.obj.get("References", "")
                    in_reply_to = msg.obj.get("In-Reply-To", "")

                    # Extract plain text email body (fallback to html if plain text is empty)
                    body_text = msg.text.strip() if msg.text else msg.html.strip() if msg.html else ""
                    if not body_text:
                        logger.warning(f"Empty email body from {from_email}. Skipping.")
                        continue

                    logger.info(f"Processing inbound email from {from_email} regarding '{subject}'")

                    # Map incoming email threads to LangGraph thread session
                    thread_id = in_reply_to or references or msg_id
                    if not thread_id:
                        thread_id = f"thread_{abs(hash(from_email + subject)) % 100_000}"

                    # Process with LangGraph Agent
                    result = process_complaint(body_text, thread_id=thread_id)

                    # Formulate reply subject
                    reply_subject = subject
                    if not reply_subject.lower().startswith("re:"):
                        reply_subject = f"Re: {reply_subject}"

                    # Send professional reply via SMTP
                    send_support_email(
                        to_email=from_email,
                        subject=reply_subject,
                        body_text=result["response"],
                        in_reply_to=msg_id,
                        references=f"{references} {msg_id}".strip()
                    )

                except Exception as e:
                    logger.error(f"Failed to process individual message: {e}")

    except Exception as e:
        logger.error(f"Error in IMAP execution run: {e}")

async def start_imap_poller():
    """Background task loop that periodically checks for new emails."""
    logger.info("Starting inbound IMAP email poller...")
    while True:
        try:
            await asyncio.to_thread(check_and_process_emails)
        except Exception as e:
            logger.error(f"Error in IMAP background task loop: {e}")
        await asyncio.sleep(settings.IMAP_POLL_INTERVAL)
