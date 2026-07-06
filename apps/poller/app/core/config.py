from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    HOST: str = "mail.privateemail.com"
    IMAP_PORT: int = 993
    PRIVATE_MAIL_EMAIL_ID: str | None = None
    PRIVATE_MAIL_PASSWORD: str | None = None
    IMAP_POLL_INTERVAL: int = 60

    REDIS_URL: str = "redis://localhost:6379/0"
    REDIS_STREAM_NAME: str = "email:inbound"

    model_config = SettingsConfigDict(env_file=("../../.env", ".env"), extra="ignore")


settings = Settings()
