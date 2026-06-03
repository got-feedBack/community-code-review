#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────
#  Teardown Script — Community Code Review
#  Stops everything and cleans up.
# ──────────────────────────────────────────────────────────────────────────
set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     Community Code Review — Teardown                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Stop Tailscale Funnel ────────────────────────────────────────────────
if command -v tailscale &>/dev/null; then
    echo "🛑 Stopping Tailscale Funnel..."
    tailscale funnel 8080 off 2>/dev/null || sudo tailscale funnel 8080 off 2>/dev/null || true
    echo "  ✓ Funnel stopped"
fi
echo ""

# ── Stop Docker containers ───────────────────────────────────────────────
echo "🛑 Stopping Docker containers..."
docker compose down 2>/dev/null || true
echo "  ✓ Containers stopped"
echo ""

# ── Remove .env file ─────────────────────────────────────────────────────
if [ -f .env ]; then
    echo "🗑️  Removing .env file..."
    rm .env
    echo "  ✓ .env removed"
fi
echo ""

echo "✅ Teardown complete. Thanks for contributing!"