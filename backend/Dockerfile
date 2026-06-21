FROM python:3.14-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
COPY . /app
WORKDIR /app
RUN uv sync --locked --no-dev
EXPOSE 8000
# Use uvicorn directly — avoids the reload=True in main.py (file-watching is
# wrong in production containers and causes unnecessary overhead).
CMD ["uv", "run", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]