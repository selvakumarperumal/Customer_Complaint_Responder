from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Accepts GOOGLE_API_KEY (preferred) or GEMINI_API_KEY (fallback).
    # In Kubernetes the value is injected as an env var from the Kubernetes Secret
    # that External Secrets Operator syncs from AWS Secrets Manager.
    GOOGLE_API_KEY: str = Field(
        validation_alias=AliasChoices("GOOGLE_API_KEY", "GEMINI_API_KEY")
    )
    MODEL_NAME: str = "gemini-3-flash-preview"
    TEMPERATURE: float = 0.1

    # Namecheap SMTP Settings
    SMTP_HOST: str = "mail.privateemail.com"
    SMTP_PORT: int = 587
    SMTP_USERNAME: str | None = None
    SMTP_PASSWORD: str | None = None
    SMTP_FROM_EMAIL: str | None = None
    SMTP_FROM_NAME: str = "Customer Support"

    # Namecheap IMAP Settings
    IMAP_HOST: str = "mail.privateemail.com"
    IMAP_PORT: int = 993
    IMAP_USERNAME: str | None = None
    IMAP_PASSWORD: str | None = None
    IMAP_POLL_INTERVAL: int = 60
    ENABLE_IMAP_POLLER: bool = False

    model_config = SettingsConfigDict(env_file=("../.env", ".env"), extra="ignore")


settings = Settings()