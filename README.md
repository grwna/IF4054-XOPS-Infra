# retail-app-infra-xops

> **Placeholder content:** app chart + Kyverno policies are dummy until Member 1/2 deliver. See [PLACEHOLDER_NOTICE.md](PLACEHOLDER_NOTICE.md).

## Tech Stack
- Kind, kubectl, Helm, Kyverno, metrics-server
- Terraform (cluster + namespaces + ingress-nginx + Kyverno + metrics-server)
- Ansible (host bootstrap: tools, cloudflared, GitLab Runner)
- GitLab CI/CD (runner on same host as cluster)

## Bootstrap vs Pipeline

**Day 0 (once, manual):** ansible installs host tools + registers runner; terraform creates cluster + platform.
**Day 1+ (every push):** runner picks job, pipeline applies Kyverno policies + deploys Helm chart (dev auto, prod manual gate).

Pipeline never re-runs ansible (job container `localhost` != host). Terraform state lives on host - pipeline does not run terraform, so runner/ansible/cloudflared untouched. Safe.

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
ansible-playbook server-setup.yaml --ask-become-pass
```

- Verify tools + runner container:
```bash
kubectl version --client
kind --version
docker ps
```

- Create cluster + platform (kind, namespaces, ingress-nginx, Kyverno, metrics-server):
```bash
sudo terraform init
sudo terraform apply -auto-approve
```

Note: first ever `terraform apply` may fail plan (kubeconfig not yet on disk). If so:
```bash
sudo terraform apply -target=kind_cluster.xops
sudo terraform apply -auto-approve
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
2. `deploy-infra` - kubectl apply Kyverno ClusterPolicies
3. `deploy-dev` - helm upgrade to `dev` namespace (auto)
4. `deploy-prod` - helm upgrade to `prod` (manual gate, `main` only)

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
