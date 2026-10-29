terraform apply -target=kind_cluster.xops
kubectl --context kind-xops get nodes


sudo chown -R xops:xops ~/.kube
kind delete cluster --name xops
docker rm -f xops-control-plane 2>/dev/null
terraform state list     # should be empty

Terraform has to be run as runner.
