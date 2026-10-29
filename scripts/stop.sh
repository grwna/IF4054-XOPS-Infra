#!/bin/bash
#
# stop.sh — gracefully stop XOps runtime services without losing state.
#

set -euo pipefail

if [ "$EUID" -eq 0 ]; then
  echo "Run as your normal user, not root: ./stop.sh"
  exit 1
fi

echo "Stopping cloudflared..."
if systemctl is-active --quiet cloudflared 2>/dev/null; then
  sudo systemctl stop cloudflared
  echo "cloudflared stopped."
else
  echo "cloudflared is not running."
fi

echo "Stopping gitlab-runner..."
if docker ps --format '{{.Names}}' | grep -qx 'gitlab-runner'; then
  docker stop gitlab-runner
else
  echo "gitlab-runner container is not running."
fi

echo "Stopping kind node (xops-control-plane)..."
if docker ps --format '{{.Names}}' | grep -qx 'xops-control-plane'; then
  docker stop xops-control-plane
else
  echo "xops-control-plane container is not running."
fi

echo
echo "Done. All XOps runtime services have been stopped cleanly."