from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.routes import complaints_router

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


@app.get("/health", tags=["health"])
async def health_check() -> dict:
    return {"status": "healthy"}
