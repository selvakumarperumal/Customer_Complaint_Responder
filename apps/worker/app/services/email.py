import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import make_msgid
import logging
from app.core.config import settings

logger = logging.getLogger(__name__)


def send_support_email(
    to_email: str,
    subject: str,
    body_text: str,
    in_reply_to: str | None = None,
    references: str | None = None,
) -> bool:
    """Send an email using Namecheap Private Email SMTP."""
    if not all([settings.PRIVATE_MAIL_EMAIL_ID, settings.PRIVATE_MAIL_PASSWORD]):
        logger.warning("SMTP credentials are not fully configured. Skipping email dispatch.")
        return False

    try:
        msg = MIMEMultipart()
        msg["From"] = f"{settings.FROM_NAME} <{settings.PRIVATE_MAIL_EMAIL_ID}>"
        msg["To"] = to_email

        # Ensure reply subject starts with "Re:"
        if subject and not subject.lower().startswith("re:"):
            subject = f"Re: {subject}"
        msg["Subject"] = subject

        # Generate a unique Message-ID for this reply
        msg["Message-ID"] = make_msgid()

        if in_reply_to:
            msg["In-Reply-To"] = in_reply_to
        if references:
            msg["References"] = references

        # Attach text body using explicit UTF-8 encoding
        msg.attach(MIMEText(body_text, "plain", "utf-8"))

        if settings.SMTP_PORT == 465:
            server = smtplib.SMTP_SSL(settings.HOST, settings.SMTP_PORT, timeout=10)
        else:
            server = smtplib.SMTP(settings.HOST, settings.SMTP_PORT, timeout=10)
            server.starttls()

        server.login(settings.PRIVATE_MAIL_EMAIL_ID, settings.PRIVATE_MAIL_PASSWORD)
        server.send_message(msg)
        server.quit()
        logger.info("Successfully sent email to %s", to_email)

        # Upload a copy of the sent email to IMAP "Sent" folder so it appears in mail UI
        if settings.PRIVATE_MAIL_EMAIL_ID and settings.PRIVATE_MAIL_PASSWORD:
            try:
                from imap_tools import MailBox
                with MailBox(settings.HOST, port=settings.IMAP_PORT, timeout=10).login(
                    settings.PRIVATE_MAIL_EMAIL_ID, settings.PRIVATE_MAIL_PASSWORD
                ) as mailbox:
                    mailbox.append(msg.as_bytes(), "Sent")
                logger.info("Uploaded a copy of sent email to IMAP 'Sent' folder.")
            except Exception as imap_err:
                logger.warning("Could not copy sent email to IMAP 'Sent' folder: %s", imap_err)

        return True
    except Exception as e:
        logger.error("Failed to send email via SMTP: %s", e)
        return False
