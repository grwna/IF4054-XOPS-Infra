# PLACEHOLDER NOTICE

This repo currently runs on **placeholder** content so Member 3's infra pipeline works end-to-end before Member 1 (app) and Member 2 (manifests/policies) finish their parts.

## What is placeholder right now

| Path | Placeholder role | Owner when final |
|------|------------------|------------------|
| `helm-charts/retail-app/` | Minimal chart: nginx-unprivileged, non-root, read-only FS, probes, limits, HPA, ingress (retail-xops/prod.local) | Member 2 |
| `kyverno-policies/require-team-label.yaml` | Dummy policy: require `team` label on pods (Enforce) | Member 2 |
| `kyverno-policies/tests/` | kyverno CLI test for the dummy policy | Member 2 |
| `non-compliant-deployment.yaml` | Bad deploy (root user, writable FS) for rejection proof | Member 2 |
| `helm-charts/retail-app/values-dev.yaml` / `values-prod.yaml` | image `nginxinc/nginx-unprivileged:alpine`, hosts retail-xops/prod.local | Member 2 + Member 1 image |

## What Member 3 owns (already real, not placeholder)

- `k8s.tf` — terraform: kind cluster (kind_config block: port mappings 80/443 inline), ns dev/prod, ingress-nginx, kyverno, metrics-server
- `k8s.tf` — terraform: kind cluster, ns dev/prod, ingress-nginx, kyverno, metrics-server
- `server-setup.yaml` — host bootstrap: packages, cloudflared, kubectl/kind/helm/kyverno-cli, GitLab Runner (docker executor, host network, kubeconfig mount)
- `.gitlab-ci.yml` — infra pipeline stages: validate → deploy-cluster (terraform) → deploy-infra (policies) → deploy-dev (auto) → deploy-prod (manual gate, `main` only)
- `vars.yaml` (gitignored) — cf_token + glrt- runner token

## To go final (remove placeholders)

### Member 1 (app repo, separate)
- Real app code + Dockerfile (USER 10001)
- App CI: unit test, lint, build image, push `:latest` and `:$CI_COMMIT_SHORT_SHA` to GitLab Container Registry
- App CI ends with a **bridge job triggering this infra repo** so deploys fire automatically after image push (registry has no webhook; this is the standard GitLab chain):

```yaml
deploy_to_infra:
  stage: deploy
  trigger:
    project: <group>/retail-app-infra-xops   # this repo
    strategy: depend                          # app pipeline waits for infra result
    variables:
      APP_IMAGE_TAG: $CI_COMMIT_SHORT_SHA
```

- How this repo "notices": it doesn't poll — app pipeline calls it via `trigger`, passing `APP_IMAGE_TAG`. Infra `deploy_dev`/`deploy_prod` consume that variable (see pipeline impact below). Until app repo exists, nothing to wire; placeholder nginx stays.

### Member 2 (manifests + policies)
1. Replace `helm-charts/retail-app/` with full chart: real app image, HPA, probes, resource limits, securityContext, readOnlyRootFilesystem, emptyDir, ingress hosts as decided
2. Replace `kyverno-policies/require-team-label.yaml` with real policies:
   - non-root execution
   - read-only root FS
   - no privilege escalation
   - resource limits required
   - trusted registry only (block everything except GitLab registry)
3. Rewrite `kyverno-policies/tests/` to cover those policies (kyverno CLI test: good manifest passes, bad manifest fails per rule)
4. Update `non-compliant-deployment.yaml` to violate at least one real rule (e.g. root user, missing limits, untrusted image) for rejection screenshots
5. Update hosts in `values-dev.yaml` / `values-prod.yaml` if not using retail-xops.local / retail-prod.local (then also `/etc/hosts` in E2E)

### Pipeline impact (Member 3 adjusts after 1 & 2)
- `deploy_infra` job: `kubectl apply -f kyverno-policies/` — may need to apply multiple files / kustomization once real policies exist (currently single file)
- `validate_policies` job: `kyverno test ./kyverno-policies/` — keep, just real policies
- `deploy_dev` / `deploy_prod`: pass image from trigger variable, fallback to placeholder:

```yaml
script:
  - helm upgrade --install retail-app ./helm-charts/retail-app -n dev
      --values ./helm-charts/retail-app/values-dev.yaml
      --set image.repository=<gitlab-registry>/retail-app
      --set image.tag=${APP_IMAGE_TAG:-alpine}
```

`APP_IMAGE_TAG` set only when pipeline triggered from app repo. Manual push here (no trigger) keeps placeholder image — by design.

### Runner / host (already real)
- No change needed for final. Runner stays docker executor + host network + kubeconfig mount.
- Ensure runner in GitLab UI has tag `xops` (CI `default: tags: [xops]`) — jobs hang without it.
