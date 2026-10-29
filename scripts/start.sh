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

if [ "$EUID" -eq 0 ]; then
  echo "Run as your normal user, not root: ./start.sh"
  exit 1
fi

echo "Starting docker..."
sudo systemctl start docker
until docker info &>/dev/null; do sleep 2; done

echo "Starting kind node (xops-control-plane)..."
if docker ps -a --format '{{.Names}}' | grep -qx 'xops-control-plane'; then
  docker start xops-control-plane
else
  echo "kind node not found. Run day 0: terraform apply"
fi

echo "Refreshing kubeconfig..."
kind export kubeconfig --name xops

echo "Starting gitlab-runner..."
if systemctl list-unit-files | grep -q '^gitlab-runner'; then
  sudo systemctl start gitlab-runner
else
  echo "gitlab-runner unit not installed. Run ansible-playbook server-setup.yaml first"
fi

echo "Starting cloudflared..."
if systemctl list-unit-files | grep -q '^cloudflared'; then
  sudo systemctl start cloudflared
else
  echo "cloudflared unit not installed. Run ansible-playbook server-setup.yaml first"
fi

echo "Waiting for Kubernetes API server..."
for i in $(seq 1 24); do
  kubectl get nodes --request-timeout=5s &>/dev/null && break
  [ "$i" -eq 24 ] && { echo "API server not ready after 2 min"; exit 1; }
  sleep 5
done

kubectl get nodes
echo "Done. Verify pods: kubectl get pods -A"