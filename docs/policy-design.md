# IaC Manifests & Kyverno Policy Design

Scope of this document: the Kubernetes deployment manifests and Kyverno
policies owned by this part of the team (manifests + policy; cluster
provisioning, the infra CI/CD pipeline, and the prod approval gate are a
separate repo concern). It covers what was built, why, and the evidence that
it works — all reproducible locally without a live cluster.

## 1. Approach

The application (`retail-store-app-xops`, the AWS retail-store-sample-app) already
ships a Helm chart per service (`cart`, `catalog`, `checkout`, `orders`, `ui`)
plus an umbrella chart that wires them together. Rather than writing Kubernetes
manifests from scratch, those charts were **vendored into this repo**
(`helm/charts/`) and patched directly, because:

- Kubernetes config belongs in the infra repo per the task's own repo split
  ("Repository terkait dengan infrastruktur memuat konfigurasi infrastruktur,
  Kubernetes, Kyverno, dan dokumentasi desain") — not in the app repo.
- A vendored copy avoids a cross-repo `file://` Helm dependency, which would
  only work if both repos happened to be checked out side by side in CI.
- Patching the real templates (not post-render patches) keeps the chart
  usable the normal Helm way — `-f values/dev.yaml` / `-f values/prod.yaml` —
  for whoever runs the infra CI/CD pipeline.

Environments are handled as **two values overlays on one chart**
(`helm/values/dev.yaml`, `helm/values/prod.yaml`), not two separate chart
copies, so dev and prod can never drift in structure, only in the explicit
values that are meant to differ (image tag, replica/HPA bounds, ingress host).

Persistence: every service defaults to `in-memory` (no MySQL/Redis/DynamoDB
StatefulSets). This keeps the deployment surface small enough to fully secure
and verify in the available time, and it's a deliberate, documented scope
decision, not an oversight — the data-loss-on-restart tradeoff is accepted for
this assignment's purpose.

## 2. Gaps found in the upstream charts, and what was changed

Checked directly against `src/<service>/chart/templates/deployment.yaml` and
`values.yaml` in the app repo before vendoring:

| Spec requirement (§3) | Upstream chart | Fix applied |
|---|---|---|
| ≥1 replica | `replicaCount: 1` ✅ | kept |
| CPU **and** memory limits | only `limits.memory` ❌ | added `resources.limits.cpu` to every service's `values.yaml` |
| Autoscale on load | `hpa.yaml` template present but `autoscaling.enabled: false` ❌ | enabled per environment in `helm/values/{dev,prod}.yaml` with min/max/target CPU |
| Liveness **and** readiness probe | only `readinessProbe`, hardcoded in the template, no `livenessProbe` field at all ❌ | converted `readinessProbe` to read from `.Values.readinessProbe`, added a new `.Values.livenessProbe` block and a `livenessProbe:` stanza in every `deployment.yaml` |
| Non-root | `runAsNonRoot: true`, `runAsUser: 1000` ✅ | kept, then corrected to `10001` — see note below |
| Read-only root filesystem | `readOnlyRootFilesystem: true` + `emptyDir` for `/tmp` ✅ | kept |
| No privilege escalation | `allowPrivilegeEscalation` never set ❌ (Kubernetes default is `true`) | added `allowPrivilegeEscalation: false` to every service's `securityContext` in `values.yaml` |
| Image from own registry | defaults to `public.ecr.aws/aws-containers/...` ❌ | overridden per environment to `docker.io/starath/retail-store-<service>` |
| Ingress/gateway from outside | present only on the `ui` chart ✅ (correct — `ui` is the only public entry point, every other service is ClusterIP-only and reached through `ui`) | enabled per environment with a distinct dev/prod host |

Liveness probe paths were chosen per service's actual health framework:
`catalog` and `checkout` use their existing `/health` for both probes (no
separate liveness endpoint exists); `cart`, `orders`, `ui` are Spring Boot
services and use `/actuator/health/liveness` (confirmed from a commented
example already present in `ui`'s own `values.yaml`), distinct from
`/actuator/health/readiness`.

`dev.yaml` also sets `image.pullPolicy: Always` for every service (`prod.yaml`
keeps the chart default `IfNotPresent`). This matters because `dev` tracks a
mutable `:latest` tag: with `IfNotPresent`, a node that already pulled
`cart:latest` once would never re-pull it again even after a newer image is
pushed, silently running a stale build. `prod` pins an immutable version tag
per release, so `IfNotPresent` there is correct and avoids redundant pulls.

`securityContext.runAsUser` and `podSecurityContext.fsGroup` were corrected
from `1000` (the upstream chart's assumption, matching the original app
image's `USER appuser`) to `10001`, after the app repo's Dockerfiles were
rewritten to `useradd --uid 10001 --gid 10001` + `USER 10001` (per the task's
own `USER 10001` convention). Kubernetes' `securityContext.runAsUser`
overrides the image's own `USER` directive — leaving it at `1000` would have
forced every container to run as a UID that doesn't own `/app` (the image's
home directory and binary location), which is a likely `CrashLoopBackOff`
from permission errors, not just a cosmetic mismatch.

One upstream quirk worth flagging: each chart's `templates/tests/` directory
defines a `helm.sh/hook: test` Pod (`<service>-test-connection`) that runs an
unpinned, unhardened `busybox` image — this is on-demand `helm test` tooling,
not part of the actual rollout. `scripts/render.sh` renders with `--no-hooks`
so these never appear in the deployed manifest or get evaluated by policy —
they simply never run unless someone explicitly invokes `helm test`.

## 3. Rendering

```
./scripts/render.sh
```

Produces `rendered/dev.yaml` and `rendered/prod.yaml` from
`helm/charts/app` + the matching `helm/values/<env>.yaml`. The infra CI/CD
pipeline is expected to override `image.tag` per service at deploy time
(`--set cart.image.tag=$CI_COMMIT_SHORT_SHA` for dev, a pinned release tag for
prod) rather than relying on the placeholder tags committed here.

## 4. Kyverno policies

All 6 policies live in `kyverno-policies/policies/`, `apiVersion: kyverno.io/v1`,
`kind: ClusterPolicy`, `validationFailureAction: Enforce` (not `Audit` —
audit only warns, it does not reject, so it would not satisfy "deployment
yang melanggar ditolak"). Each matches `kind: Pod` and relies on Kyverno's
**autogen** feature to automatically generate the matching rule for
`Deployment` (confirmed working — see evidence below; rule names become
`autogen-<rule-name>`), so a non-compliant Deployment is rejected at
admission, not just a bare Pod. `kube-system` and the `kyverno` namespace are
excluded on every policy so enforcement can never block Kyverno's own
bootstrap or self-healing.

| Policy file | Spec requirement | What it rejects |
|---|---|---|
| `require-run-as-nonroot.yaml` | 3.d — container tanpa akses root | `runAsNonRoot` not `true`, or `runAsUser: 0`, on any container |
| `require-readonly-rootfs.yaml` | 3.d — filesystem read-only | `readOnlyRootFilesystem` not `true` on any container |
| `disallow-privilege-escalation.yaml` | 3.d — larangan privilege escalation | `allowPrivilegeEscalation` not explicitly `false` (missing field is rejected too, since the Kubernetes default is `true`) |
| `require-resource-limits.yaml` | 3.c — limit resource CPU dan memory | missing `resources.limits.cpu` or `resources.limits.memory` |
| `require-liveness-readiness-probes.yaml` | 3.c — liveness **dan** readiness probe | missing either probe. Written independently of Kyverno's own official "require-probes" example policy, which only requires *one* of liveness/readiness/startup — not strict enough for this requirement. |
| `restrict-image-registries.yaml` | 3.b — image hanya dari registry sendiri | image that doesn't match the group's Docker Hub namespace prefix (`docker.io/starath/retail-store-*`) |

Deliberately **not** enforced via Kyverno (left to the CI/CD pipeline or the
cluster-level HPA/metrics-server setup instead, each for a stated reason):

- **HPA presence/correctness** — cross-resource validation (Deployment ↔ HPA)
  is complex to get right at admission time and risks deadlocking the very
  first install if written carelessly. `autoscaling.enabled: true` per
  environment plus an actual load test (infra repo's CI/CD scope) is the
  chosen proof instead.
- **Two image tags in the registry, prod approval** — these aren't
  properties of a single manifest Kyverno can see at admission time; they're
  pipeline-level controls (image promotion, protected environment approval).

## 5. Evidence

All of the following are reproducible locally, no cluster required (`brew
install helm kyverno kustomize`):

- **`docs/evidence/kyverno-test-output.txt`** — output of `kyverno test
  kyverno-policies/tests/`, a declarative test suite (`kyverno-policies/tests/kyverno-test.yaml`)
  that cross-checks all 6 policies against 8 fixtures (1 compliant baseline +
  7 fixtures, each with exactly one deliberate violation, generated from a
  real rendered `cart` Deployment — not synthetic). Result: **48/48 expected
  outcomes matched, 0 failed** — every policy passes the compliant fixture and
  every other fixture, and fails only the fixture it's meant to catch.
- **`docs/evidence/sample-denials.txt`** — the human-readable Kyverno denial
  message for each of the 7 violations (`kyverno apply kyverno-policies/policies/
  --resource <fixture>`), showing the exact policy, rule, and field path that
  rejected it.
- **`docs/evidence/kyverno-apply-dev-report.yaml`** /
  **`kyverno-apply-prod-report.yaml`** — the full policy report from running
  all 6 policies against the actual rendered dev/prod manifests (all 5
  services, not a cherry-picked one). Summary: **30/30 checks passed, 0
  failed** in both environments (5 services × 6 policies) — proving the real
  deployment manifests, not just the test fixtures, are compliant.

To reproduce:
```
./scripts/render.sh
kyverno apply kyverno-policies/policies/ --resource rendered/dev.yaml --policy-report
kyverno test kyverno-policies/tests/
```

## 6. Known gaps / handed off to other members

- **Registry target — resolved.** Originally assumed GitLab Container
  Registry (`registry.gitlab-edu.itb.ac.id/<group>/retail-store-app-xops/<service>`),
  inferred from the infra repo's own GitLab remote. The app repo's CI
  actually publishes to **Docker Hub** instead (`ci/publish-images.py`,
  `IMAGE_HOST = "docker.io"`), confirmed via the app repo's group-level
  CI/CD variable `DOCKERHUB_NAMESPACE = starath`. All `values.yaml`/policy
  files were updated to `docker.io/starath/retail-store-<service>`.
- **Ingress controller.** `ingressClassName: nginx` is a placeholder; whoever
  owns cluster bootstrap (IaC) picks and installs the actual controller.
- **Namespace is not baked into the manifests** — `metadata.namespace` is
  intentionally left for the deploying command (`helm upgrade --install
  --namespace dev|prod`) to set, matching how the upstream charts already
  work; this is why local Kyverno tests above don't filter by namespace and
  instead exclude only `kube-system`/`kyverno` by name.
- **Image digests / pinned promotion, prod approval gate, HPA load test,
  cluster bootstrap** are infra CI/CD pipeline concerns, not part of this
  manifest/policy deliverable.
