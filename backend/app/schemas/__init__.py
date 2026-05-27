from pydantic import BaseModel


class ComplaintRequest(BaseModel):
    complaint: str
    thread_id: str | None = None


class ComplaintResponse(BaseModel):
    complaint: str
    complaint_type: str
    response: str
