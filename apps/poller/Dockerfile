FROM python:3.12-slim

# Install uv (fast Python package manager)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Copy dependency files first for layer caching
COPY pyproject.toml uv.lock* ./

# Install dependencies (no dev extras)
RUN uv sync --locked --no-dev 2>/dev/null || uv sync --no-dev

# Copy application code
COPY app/ ./app/

CMD ["uv", "run", "python", "-m", "app.main"]
