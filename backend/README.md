# Customer Complaint Responder — Backend

FastAPI backend that classifies customer complaints and generates professional responses using LangGraph + Gemini.

## Setup

```bash
cd backend
uv pip install -e .
```

## Run

```bash
uv run python main.py
# or
uvicorn app.main:app --reload
```

## Environment variables

Create a `.env` file in the **project root** (one level above `backend/`):

```
GOOGLE_API_KEY=your-key-here
# or
GEMINI_API_KEY=your-key-here
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| POST | `/api/v1/complaints` | Process a complaint |

### Request body

```json
{
  "complaint": "My order hasn't arrived after 2 weeks.",
  "thread_id": "optional-session-id"
}
```

### Response

```json
{
  "complaint": "My order hasn't arrived after 2 weeks.",
  "complaint_type": "delivery",
  "response": "Dear customer, we sincerely apologize..."
}
```
