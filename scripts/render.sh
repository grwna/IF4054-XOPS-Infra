#!/usr/bin/env bash
# Renders the umbrella Helm chart for each environment into rendered/<env>.yaml.
# Run from the repo root: ./scripts/render.sh
set -euo pipefail
: "${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART_DIR="$REPO_ROOT/helm/charts/app"
OUT_DIR="$REPO_ROOT/rendered"

mkdir -p "$OUT_DIR"

helm dependency build "$CHART_DIR" >/dev/null

for env in dev prod; do
  echo "Rendering $env ..."
  # --no-hooks: the charts' "helm test" connection-check Pods (plain busybox,
  # no hardening) are on-demand verification tooling, not part of the actual
  # rollout, so they are excluded from the deployed manifest entirely rather
  # than carved out with a policy exception.
  helm template retail "$CHART_DIR" \
    --namespace "$env" \
    --no-hooks \
    -f "$REPO_ROOT/helm/values/$env.yaml" \
    --set "cart.image.repository=docker.io/$DOCKERHUB_NAMESPACE/retail-store-cart" \
    --set "catalog.image.repository=docker.io/$DOCKERHUB_NAMESPACE/retail-store-catalog" \
    --set "checkout.image.repository=docker.io/$DOCKERHUB_NAMESPACE/retail-store-checkout" \
    --set "orders.image.repository=docker.io/$DOCKERHUB_NAMESPACE/retail-store-orders" \
    --set "ui.image.repository=docker.io/$DOCKERHUB_NAMESPACE/retail-store-ui" \
    > "$OUT_DIR/$env.yaml"
done

echo "Done. Output in $OUT_DIR/{dev,prod}.yaml"
