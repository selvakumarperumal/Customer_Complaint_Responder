from langchain_core.prompts import ChatPromptTemplate

category_prompt = ChatPromptTemplate.from_messages([
    ("system", "You are a helpful assistant that classifies customer complaints."),
    ("user", "Classify the following complaint into one of these categories: delivery, refund, product issue, other."),
    ("user", "Complaint: {input}"),
    ("user", "Respond with only the category name, nothing else."),
])

response_prompt = ChatPromptTemplate.from_messages([
    ("system", "You are a helpful customer service assistant that generates professional and empathetic responses."),
    ("user", (
        "Generate a professional and empathetic response to the following customer complaint.\n\n"
        "Complaint: {complaint}\n"
        "Complaint category: {complaint_type}\n\n"
        "Note: Provide only a single response message."
    )),
])
