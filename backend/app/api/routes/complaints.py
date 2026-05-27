from fastapi import APIRouter, HTTPException

from app.schemas import ComplaintRequest, ComplaintResponse
from app.services.agent.agent import process_complaint

router = APIRouter()


@router.post(
    "/complaints",
    response_model=ComplaintResponse,
    summary="Process a customer complaint",
)
async def handle_complaint(request: ComplaintRequest) -> ComplaintResponse:
    """Classify the complaint and generate a professional response using LangGraph."""
    try:
        result = process_complaint(request.complaint, request.thread_id)
        return ComplaintResponse(**result)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
