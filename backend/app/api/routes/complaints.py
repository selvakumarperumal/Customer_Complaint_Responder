from fastapi import APIRouter, HTTPException, BackgroundTasks

from app.schemas import ComplaintRequest, ComplaintResponse
from app.services.agent.agent import process_complaint
from app.services.email import send_support_email

router = APIRouter()


@router.post(
    "/complaints",
    response_model=ComplaintResponse,
    summary="Process a customer complaint",
)
async def handle_complaint(
    request: ComplaintRequest, background_tasks: BackgroundTasks
) -> ComplaintResponse:
    """Classify the complaint and generate a professional response using LangGraph."""
    try:
        result = process_complaint(request.complaint, request.thread_id)
        email_sent = False
        if request.customer_email and result.get("response"):
            background_tasks.add_task(
                send_support_email,
                to_email=request.customer_email,
                subject="Regarding your support request",
                body_text=result["response"],
            )
            email_sent = True

        return ComplaintResponse(**result, email_sent=email_sent)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
