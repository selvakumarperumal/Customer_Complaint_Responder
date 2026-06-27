import logging
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.utils import make_msgid

from imap_tools import MailBox

from app.core.config import settings

logger = logging.getLogger(__name__)


def _upload_to_sent_folder(msg: MIMEMultipart) -> None:
    """Upload a copy of the sent email to the IMAP 'Sent' folder."""
    if not all([settings.PRIVATE_MAIL_EMAIL_ID, settings.PRIVATE_MAIL_PASSWORD]):
        return
    try:
        with MailBox(settings.HOST, port=settings.IMAP_PORT, timeout=10).login(
            settings.PRIVATE_MAIL_EMAIL_ID, settings.PRIVATE_MAIL_PASSWORD
        ) as mailbox:
            mailbox.append(msg.as_bytes(), "Sent")
        logger.info("Uploaded a copy of sent email to IMAP 'Sent' folder.")
    except Exception as exc:
        logger.warning("Could not copy sent email to IMAP 'Sent' folder: %s", exc)


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
        # 1. Build MIME Message
        msg = MIMEMultipart()
        msg["From"] = f"{settings.FROM_NAME} <{settings.PRIVATE_MAIL_EMAIL_ID}>"
        msg["To"] = to_email

        if subject and not subject.lower().startswith("re:"):
            subject = f"Re: {subject}"
        msg["Subject"] = subject
        msg["Message-ID"] = make_msgid()

        if in_reply_to:
            msg["In-Reply-To"] = in_reply_to
        if references:
            msg["References"] = references

        msg.attach(MIMEText(body_text, "plain", "utf-8"))

        # 2. Establish SMTP connection and send
        if settings.SMTP_PORT == 465:
            server = smtplib.SMTP_SSL(settings.HOST, settings.SMTP_PORT, timeout=10)
        else:
            server = smtplib.SMTP(settings.HOST, settings.SMTP_PORT, timeout=10)
            server.starttls()

        with server:
            server.login(settings.PRIVATE_MAIL_EMAIL_ID, settings.PRIVATE_MAIL_PASSWORD)
            server.send_message(msg)

        logger.info("Successfully sent email to %s", to_email)

        # 3. Save copy to IMAP Sent folder
        _upload_to_sent_folder(msg)

        return True

    except Exception as exc:
        logger.error("Failed to send email via SMTP: %s", exc)
        return False
