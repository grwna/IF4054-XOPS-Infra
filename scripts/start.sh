#!/bin/bash
#
# start.sh — bring XOps services back after a server/WSL shutdown.
#
# Use this when:
#   - WSL/VM was shut down and restarted
#   - docker/kind/runner/cloudflared are down but were already set up (day 0 done)
#
# Do NOT use this when:
#   - first-time setup (use init.sh, then ansible-playbook server-setup.yaml, then terraform apply)
#   - you changed k8s.tf / server-setup.yaml and need to re-apply (run terraform/ansible instead)
#   - cluster/runner were deleted (kind delete cluster / docker rm) — re-run day 0, not this

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root or with sudo: sudo ./start.sh"
  exit 1
fi

echo "Starting docker..."
systemctl start docker

echo "Starting kind node (xops-control-plane)..."
if docker ps -a --format '{{.Names}}' | grep -qx 'xops-control-plane'; then
  docker start xops-control-plane
else
  echo "kind node container not found — cluster not created yet. Run day 0: sudo terraform apply"
fi

echo "Starting gitlab-runner..."
if docker ps -a --format '{{.Names}}' | grep -qx 'gitlab-runner'; then
  docker start gitlab-runner
else
  echo "gitlab-runner container not found — run ansible-playbook server-setup.yaml first"
fi

echo "Starting cloudflared..."
if systemctl list-unit-files | grep -q '^cloudflared'; then
  systemctl start cloudflared
else
  echo "cloudflared unit not installed — run ansible-playbook server-setup.yaml first"
fi

echo
echo "Waiting for kubernetes node..."
sleep 5
kubectl get nodes || true

echo
echo "Done. Verify pods: kubectl get pods -A"
