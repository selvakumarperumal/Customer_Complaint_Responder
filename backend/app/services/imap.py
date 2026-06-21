import imaplib
import email
from email.header import decode_header
import logging
import asyncio
from app.core.config import settings
from app.services.agent.agent import process_complaint
from app.services.email import send_support_email

logger = logging.getLogger(__name__)

def parse_email_body(msg) -> str:
    """Helper to extract plain text content from email parts."""
    body = ""
    if msg.is_multipart():
        for part in msg.walk():
            content_type = part.get_content_type()
            content_disposition = str(part.get("Content-Disposition"))
            if content_type == "text/plain" and "attachment" not in content_disposition:
                try:
                    payload = part.get_payload(decode=True)
                    if payload:
                        body = payload.decode(errors="ignore")
                        break
                except Exception as e:
                    logger.debug(f"Failed to decode part: {e}")
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            body = payload.decode(errors="ignore")
    return body

def check_and_process_emails():
    """Poll the IMAP server and process any new messages."""
    # We allow fallbacks to SMTP credentials if IMAP specific ones are not set
    username = settings.IMAP_USERNAME or settings.SMTP_USERNAME
    password = settings.IMAP_PASSWORD or settings.SMTP_PASSWORD

    if not all([username, password]):
        logger.warning("IMAP credentials are not fully configured. Skipping poller run.")
        return

    try:
        mail = imaplib.IMAP4_SSL(settings.IMAP_HOST, settings.IMAP_PORT, timeout=15)
        mail.login(username, password)
        mail.select("inbox")

        # Search for unseen emails
        status, messages = mail.search(None, "UNSEEN")
        if status != "OK" or not messages[0]:
            mail.logout()
            return

        for num in messages[0].split():
            try:
                # Fetch full RFC822 message
                res, msg_data = mail.fetch(num, "(RFC822)")
                if res != "OK":
                    continue

                for response_part in msg_data:
                    if isinstance(response_part, tuple):
                        msg = email.message_from_bytes(response_part[1])
                        
                        # Decode subject safely
                        subject = ""
                        raw_subject = msg.get("Subject")
                        if raw_subject:
                            decoded_parts = decode_header(raw_subject)
                            for part, encoding in decoded_parts:
                                if isinstance(part, bytes):
                                    subject += part.decode(encoding or "utf-8", errors="ignore")
                                else:
                                    subject += part
                        
                        from_ = msg.get("From", "")
                        msg_id = msg.get("Message-ID", "")
                        references = msg.get("References", "")
                        in_reply_to = msg.get("In-Reply-To", "")

                        # Parse sender email
                        from_email = email.utils.parseaddr(from_)[1]
                        if not from_email:
                            continue

                        body_text = parse_email_body(msg).strip()
                        if not body_text:
                            logger.warning(f"Empty email body from {from_email}. Skipping.")
                            continue

                        logger.info(f"Processing inbound email from {from_email} regarding '{subject}'")

                        # Determine thread ID: use message-id or references to keep thread session in LangGraph
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

                # Mark email as read/seen
                mail.store(num, "+FLAGS", "\\Seen")
            except Exception as e:
                logger.error(f"Failed to process individual message {num}: {e}")

        mail.logout()
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
