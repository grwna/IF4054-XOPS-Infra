#!/bin/sh
set -eu

: "${DOCKERHUB_NAMESPACE:?DOCKERHUB_NAMESPACE is required}"
case "$DOCKERHUB_NAMESPACE" in
  *[!a-z0-9_-]*|'') exit 1 ;;
esac

rm -rf generated/kyverno-policies
mkdir -p generated/kyverno-policies
cp -R kyverno-policies/. generated/kyverno-policies/
find generated/kyverno-policies -type f -name '*.yaml' -exec \
  sed -i "s/__DOCKERHUB_NAMESPACE__/${DOCKERHUB_NAMESPACE}/g" {} +
