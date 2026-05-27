from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    # Accepts GOOGLE_API_KEY (preferred) or GEMINI_API_KEY (fallback)
    GOOGLE_API_KEY: str = Field(
        validation_alias=AliasChoices("GOOGLE_API_KEY", "GEMINI_API_KEY")
    )
    MODEL_NAME: str = "gemini-2.0-flash"
    TEMPERATURE: float = 0.1

    model_config = SettingsConfigDict(env_file=("../.env", ".env"), extra="ignore")


settings = Settings()
