
# Base image
FROM python:3.13-slim AS base

# Install Python dependencies
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy app code
COPY app.py ./

# Production image
FROM base AS prod

# Development image
FROM base AS dev

