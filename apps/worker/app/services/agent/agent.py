from typing import TypedDict

from langchain_google_genai import ChatGoogleGenerativeAI
from langgraph.graph import END, START, StateGraph

from app.core.config import settings
from app.services.agent.prompts import category_prompt, response_prompt


class ComplaintState(TypedDict):
    complaint: str
    complaint_type: str
    response: str


_llm = ChatGoogleGenerativeAI(
    model=settings.MODEL_NAME,
    temperature=settings.TEMPERATURE,
    api_key=settings.GOOGLE_API_KEY,
)

_classify_chain = category_prompt | _llm
_response_chain = response_prompt | _llm


def _node_classify(state: ComplaintState) -> dict:
    """Classify the complaint into a category."""
    ai_response = _classify_chain.invoke({"input": state["complaint"]})
    return {"complaint_type": ai_response.text.strip().lower()}


def _node_respond(state: ComplaintState) -> dict:
    """Generate a professional response to the complaint."""
    ai_response = _response_chain.invoke({
        "complaint": state["complaint"],
        "complaint_type": state["complaint_type"],
    })
    return {"response": ai_response.text}


_workflow = StateGraph(ComplaintState)
_workflow.add_node("classify", _node_classify)
_workflow.add_node("respond", _node_respond)
_workflow.add_edge(START, "classify")
_workflow.add_edge("classify", "respond")
_workflow.add_edge("respond", END)

_app = _workflow.compile()


def process_complaint(complaint_text: str, thread_id: str | None = None) -> dict:
    """Run the LangGraph workflow and return classification + response."""
    result = _app.invoke(
        {"complaint": complaint_text, "complaint_type": "", "response": ""}
    )
    return {
        "complaint": complaint_text,
        "complaint_type": result["complaint_type"],
        "response": result["response"],
    }
