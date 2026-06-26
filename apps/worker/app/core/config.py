from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    GOOGLE_API_KEY: str = Field(
        validation_alias=AliasChoices("GOOGLE_API_KEY", "GEMINI_API_KEY")
    )
    MODEL_NAME: str = "gemini-3.5-flash"
    TEMPERATURE: float = 0.1

    HOST: str = "mail.privateemail.com"
    PRIVATE_MAIL_PASSWORD: str | None = None
    PRIVATE_MAIL_EMAIL_ID: str | None = None

    IMAP_PORT: int = 993
    SMTP_PORT: int = 587

    FROM_NAME: str = "Customer Support"

    REDIS_URL: str = "redis://localhost:6379/0"
    REDIS_STREAM_NAME: str = "email:inbound"
    REDIS_CONSUMER_GROUP: str = "complaint-workers"
    REDIS_DEDUPE_TTL: int = 2_592_000

    model_config = SettingsConfigDict(env_file=("../../.env", ".env"), extra="ignore")


settings = Settings()
