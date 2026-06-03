#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────
#  Setup Script — Community Code Review
#  Run this once on the coordinator machine to get everything going.
# ──────────────────────────────────────────────────────────────────────────
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Community Code Review — Setup                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Check prerequisites ──────────────────────────────────────────
echo "🔍 Checking prerequisites..."

if ! command -v git &>/dev/null; then
    echo "✗ Git not found. Install from https://git-scm.com/downloads"
    echo "  (On Windows, this also provides Git Bash for running this script.)"
    exit 1
fi
echo "  ✓ Git"

if ! command -v docker &>/dev/null; then
    echo "✗ Docker not found. Install from https://docs.docker.com/get-docker/"
    exit 1
fi
echo "  ✓ Docker"

if ! command -v tailscale &>/dev/null; then
    echo "✗ Tailscale not found. Install from https://tailscale.com/download"
    exit 1
fi

# Check Tailscale is logged in and connected
TAILSCALE_STATUS=$(tailscale status --json 2>/dev/null || echo '{"Self":null}')
if ! echo "$TAILSCALE_STATUS" | grep -q '"Online":true'; then
    echo "  ⚠ Tailscale is installed but may not be logged in or connected."
    echo "  Please run: tailscale up"
    echo "  Then re-run this script."
    exit 1
fi
echo "  ✓ Tailscale (connected)"
echo ""

# ── Step 2: Generate volunteer secret ─────────────────────────────────---
echo "🔐 Generating volunteer secret..."
COORDINATOR_SECRET=$(openssl rand -base64 32)
echo "  ✓ Secret generated"
echo ""

# ── Step 3: Gather inputs ────────────────────────────────────────────────
echo "Please enter your GitHub organization name:"
read -r GITHUB_ORG_NAME
echo "Please enter your GitHub Personal Access Token (with admin:org scope):"
read -rs GITHUB_PAT
echo ""

# ── Step 4: Create .env file ─────────────────────────────────────────────
echo "📝 Creating .env file..."
cat > .env << EOF
COORDINATOR_SECRET=${COORDINATOR_SECRET}
GITHUB_ORG_NAME=${GITHUB_ORG_NAME}
GITHUB_PAT=${GITHUB_PAT}
RUNNER_NAME=coordinator-runner
EOF
echo "  ✓ .env created"
echo ""

# ── Step 5: Start Docker containers ──────────────────────────────────────
echo "🐳 Starting coordinator and runner..."
docker compose up -d
echo "  ✓ Containers started"
echo ""

# Wait for runner to appear
echo "⏳ Waiting for runner to register with GitHub..."
sleep 5
RUNNER_IDLE=$(docker compose ps --status running runner 2>/dev/null | grep -c "runner" || true)
echo "  Check GitHub → Your Organization → Settings → Actions → Runners"
echo "  for 'coordinator-runner' (status: Idle)"
echo ""

# ── Step 6: Tailscale Funnel setup ───────────────────────────────────────
echo "🌐 Setting up Tailscale Funnel..."
echo ""
echo "  First, enable MagicDNS and HTTPS Certificates in your Tailscale admin console:"
echo "    1. Go to https://login.tailscale.com/admin/dns"
echo "    2. Enable MagicDNS (if not already on)"
echo "    3. Enable HTTPS Certificates (if not already on)"
echo ""
echo "  Press Enter once you've done both..."
read -r

# Get the Funnel URL
# `tailscale funnel` may need sudo on Linux; on Windows Git Bash it doesn't
FUNNEL_OUTPUT=$(tailscale funnel 8080 2>&1) || FUNNEL_OUTPUT=$(sudo tailscale funnel 8080 2>&1) || true
echo "$FUNNEL_OUTPUT"
FUNNEL_URL=$(echo "$FUNNEL_OUTPUT" | grep -o 'https://[^ ]*' | head -1 || true)
if [ -z "$FUNNEL_URL" ]; then
    FUNNEL_URL="https://<your-machine>.<your-tailnet>.ts.net"
fi

# ── Step 7: Optional smoke test ──────────────────────────────────────────
echo ""
echo "🧪 Run a quick smoke test?"
echo "  This builds the volunteer image and starts a test container on"
echo "  this machine to verify the coordinator can see it."
echo "  You'll need a GPU for this (or it will fall back to CPU)."
echo ""
echo "  Run smoke test? [y/N]"
read -r SMOKE_TEST

if [ "$SMOKE_TEST" = "y" ] || [ "$SMOKE_TEST" = "Y" ]; then
    echo ""
    echo "🧪 Building volunteer image..."
    cd "$(dirname "$0")/volunteer"
    docker build -t volunteer:latest .
    cd - > /dev/null

    echo "🧪 Starting test volunteer..."
    docker run -d \
        --name smoke-test-volunteer \
        --gpus all \
        --add-host host.docker.internal:host-gateway \
        -v /tmp/smoke-test-models:/models \
        -e COORDINATOR_URL="http://host.docker.internal:8080" \
        -e VOLUNTEER_ID="smoke-test" \
        -e VOLUNTEER_SECRET="${COORDINATOR_SECRET}" \
        -e MODEL_REPO="Qwen/Qwen3-30B-A3B-GGUF" \
        -e MODEL_FILE="qwen3-30b-a3b-q4_k_m.gguf" \
        volunteer:latest

    echo "⏳ Waiting for model download and registration (this may take a while)..."
    echo "  You can follow progress with: docker logs -f smoke-test-volunteer"
    echo ""

    # Poll for registration up to 5 minutes
    REGISTERED=false
    for i in $(seq 1 60); do
        VOLUNTEERS=$(curl -sf http://localhost:8080/volunteers 2>/dev/null || echo "[]")
        if echo "$VOLUNTEERS" | grep -q '"smoke-test"'; then
            REGISTERED=true
            break
        fi
        sleep 5
    done

    if [ "$REGISTERED" = true ]; then
        echo "✅ Smoke test passed! Coordinator sees the volunteer."
        echo "  You can leave it running while you test PRs, or stop it now."
        echo ""
        echo "  Keep it running? [y/N]"
        read -r KEEP_VOLUNTEER
        if [ "$KEEP_VOLUNTEER" != "y" ] && [ "$KEEP_VOLUNTEER" != "Y" ]; then
            docker stop smoke-test-volunteer > /dev/null 2>&1 || true
            docker rm smoke-test-volunteer > /dev/null 2>&1 || true
            echo "  Test volunteer stopped and removed."
        fi
    else
        echo "⚠ Smoke test inconclusive — volunteer did not register within 5 minutes."
        echo "  The model download may still be in progress."
        echo "  Check logs: docker logs -f smoke-test-volunteer"
        echo ""
        echo "  To clean up the test container:"
        echo "    docker stop smoke-test-volunteer"
        echo "    docker rm smoke-test-volunteer"
    fi
    echo ""
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Setup complete. The coordinator is ready!               ║"
echo "║                                                              ║"
echo "║  Tell volunteers to run this command:                        ║"
echo "║                                                              ║"
echo "║  docker run -d --gpus all \                                  ║"
echo "║    --name code-review-volunteer \                            ║"
echo "║    -v ~/code-review-models:/models \                         ║"
echo "║    -e COORDINATOR_URL=\"${FUNNEL_URL}\" \                    ║"
echo "║    -e VOLUNTEER_SECRET=\"${COORDINATOR_SECRET}\" \           ║"
echo "║    -e VOLUNTEER_ID=\"github-or-discord-name\" \              ║"
echo "║    volunteer:latest                                          ║"
echo "║                                                              ║"
echo "║  Need to stop everything later? Run:                         ║"
echo "║    ./teardown.sh                                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
