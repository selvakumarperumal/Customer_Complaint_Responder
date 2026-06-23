from langchain_core.prompts import ChatPromptTemplate

category_prompt = ChatPromptTemplate.from_messages([
    ("system", "You are a helpful assistant that classifies customer complaints into one of these categories: delivery, refund, product issue, other. Respond with only the category name, nothing else."),
    ("user", "Conversation Thread:\n{input}"),
])

response_prompt = ChatPromptTemplate.from_messages([
    ("system", "You are a helpful customer service assistant that generates professional and empathetic responses. The complaint category is: {complaint_type}."),
    ("user", (
        "Generate a professional and empathetic response to the customer's latest request in the following conversation thread.\n\n"
        "Conversation Thread:\n{complaint}\n\n"
        "Note: Provide only a single response message addressing the customer's latest request, keeping the thread history in mind."
    )),
])
