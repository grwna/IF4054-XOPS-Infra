# retail-app-infra-xops

> **Placeholder content:** app chart + Kyverno policies are dummy until Member 1/2 deliver. See [PLACEHOLDER_NOTICE.md](PLACEHOLDER_NOTICE.md).

## Tech Stack
- Kind, kubectl, Helm, Kyverno, metrics-server
- Terraform (cluster + namespaces + ingress-nginx + Kyverno + metrics-server)
- Ansible (host bootstrap: tools, cloudflared, GitLab Runner)
- GitLab CI/CD (runner on same host as cluster)

## Bootstrap vs Pipeline

**Day 0 (once, manual):** ansible installs host tools + registers runner. Host is bootstrapper concern — can't be in CI because runner must exist before any job runs.
**Day 1+ (every push):** pipeline deploys ALL infra via CI/CD (spec requirement): terraform (cluster/platform), Kyverno policies, Helm chart (dev auto, prod manual gate).

Terraform state on host (`/root/tfstate`, mounted into runner jobs) — persists across runs, no cluster recreate. Ansible/cloudflared/runner config never touched by pipeline.

## How to Use

### Day 0 - Bootstrap (once)

- Install SSH and Ansible:
```bash
sudo apt install openssh ansible

# or

chmod +x init.sh && sudo ./init.sh
```

- Fill `vars.yaml` (copy `vars-example.yaml`, set `cf_token` + `gitlab_token` glrt- runner token), then:
```bash
sudo ansible-playbook server-setup.yaml
```

- Verify tools + runner container:
```bash
kubectl version --client
kind --version
terraform version
docker ps
```

Cluster + platform (kind, namespaces, ingress-nginx, Kyverno, metrics-server) is created by the **pipeline** on first push (`terraform_apply` job) — no manual terraform needed. Fallback if CI bootstrap fails, run locally:
```bash
sudo terraform init
sudo terraform apply -target=kind_cluster.xops -auto-approve
sudo terraform apply -auto-approve
```

Note: runner must be **re-registered** once after `/root/tfstate` mount was added (jobs need the volume):
```bash
docker exec gitlab-runner gitlab-runner unregister --all-runners
sudo ansible-playbook server-setup.yaml
```

### Restart after shutdown

After WSL/server reboot - no ansible, no terraform needed (state on disk):
```bash
chmod +x start.sh && sudo ./start.sh
```
Starts docker, kind node, gitlab-runner, cloudflared. See comments in `start.sh` for when NOT to use it (first setup / deleted cluster = redo day 0).

### Day 1+ - Pipeline

Push to repo. Runner (same host) picks jobs. Stages:
1. `validate` - kyverno CLI test on policies
2. `deploy-cluster` - terraform apply (kind + ns + ingress-nginx + Kyverno + metrics-server)
3. `deploy-infra` - kubectl apply Kyverno ClusterPolicies
4. `deploy-dev` - helm upgrade to `dev` namespace (auto)
5. `deploy-prod` - helm upgrade to `prod` (manual gate, `main` only)

If jobs stuck "no runner": runner must have tag `xops` (GitLab UI > Settings > CI/CD > Runners > Edit runner > Tags).

### Verify

```bash
kubectl get ns
kubectl get pods -n dev
kubectl get pods -n prod
kubectl get pods -n ingress-nginx
kubectl get pods -n kyverno
```

### E2E

```bash
echo "127.0.0.1 retail-xops.local retail-prod.local" | sudo tee -a /etc/hosts
curl -I http://retail-xops.local
curl -I http://retail-prod.local
```

### HPA

```bash
kubectl get hpa -n dev -w
kubectl run -i --tty load-generator --rm --image=busybox:1.28 --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://retail-app.dev.svc.cluster.local; done"
```

### Policy rejection proof

```bash
kubectl apply -f non-compliant-deployment.yaml -n dev
# expect admission webhook deny (placeholder: missing team label; Member 2 policies: root/read-only/etc)
```
