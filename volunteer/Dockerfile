# ── Stage 1: llama-server binary ──────────────────────────────────────────
FROM ghcr.io/ggml-org/llama.cpp:server-cuda AS llama

FROM python:3.14-alpine

# Copy llama-server from the official image
COPY --from=llama /app/llama-server /usr/local/bin/llama-server

# Alpine uses apk instead of apt-get
RUN apk add --no-cache curl

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the WebSocket agent
COPY agent.py .
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The only host path volunteers must share — model storage
VOLUME ["/models"]

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]