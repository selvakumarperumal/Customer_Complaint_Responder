from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
import asyncio
import json

app = FastAPI()

# Dummy stock data
STOCKS = {"MSFT": 200.3, "AAPL": 100.4, "AMZN": 150.0, "RIL": 87.6}

# Simulated Human-in-the-Loop (HITL) state
hitl_state = {}


async def fake_llm_stream(symbol: str, qty: int):
    """Simulate an LLM agent with HITL (0 or 1 decision)."""
    price = STOCKS.get(symbol, 0.0)
    total = price * qty

    # Step 1: show calculation
    yield {"event": "info", "data": f"Price of {qty} {symbol} stocks = ${total:.2f}"}
    await asyncio.sleep(1)

    # Step 2: ask approval
    hitl_state["decision"] = None
    yield {"event": "hitl", "data": f"Approve purchase? Enter 1=yes, 0=no"}
    while hitl_state["decision"] is None:
        await asyncio.sleep(0.5)

    if hitl_state["decision"] == "0":
        yield {"event": "reply", "data": "Purchase declined."}
        return

    # Step 3: final success
    yield {"event": "reply", "data": f"Purchase successful: {qty} {symbol} for ${total:.2f}"}

    return


@app.get("/buy")
async def buy(symbol: str = "MSFT", qty: int = 1):
    """Stream the stock buying process."""
    async def event_generator():
        async for msg in fake_llm_stream(symbol, qty):
            yield f"event: {msg['event']}\ndata: {json.dumps(msg['data'])}\n\n"
    return StreamingResponse(event_generator(), media_type="text/event-stream")


@app.post("/hitl")
async def hitl(decision: int):
    """Endpoint to provide HITL decision (0 or 1)."""
    hitl_state["decision"] = str(decision)
    return {"status": "received", "decision": decision}
