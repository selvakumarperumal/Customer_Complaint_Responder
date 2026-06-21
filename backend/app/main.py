from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import asyncio

from app.api.routes import complaints_router
from app.services.imap import start_imap_poller
from app.core.config import settings

app = FastAPI(
    title="Customer Complaint Responder",
    description=(
        "Classifies customer complaints and generates professional responses "
        "using LangGraph + Gemini."
    ),
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(complaints_router, prefix="/api/v1", tags=["complaints"])


@app.on_event("startup")
async def startup_event():
    if settings.ENABLE_IMAP_POLLER:
        asyncio.create_task(start_imap_poller())


@app.get("/health", tags=["health"])
async def health_check() -> dict:
    return {"status": "healthy"}
