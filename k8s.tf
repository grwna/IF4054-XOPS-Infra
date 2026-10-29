terraform {
  backend "local" {
    path = "/home/xops/IF4054-XOPS-Infra/terraform.tfstate"
  }

  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

provider "kubernetes" {
  host                   = kind_cluster.xops.endpoint
  client_certificate     = kind_cluster.xops.client_certificate
  client_key             = kind_cluster.xops.client_key
  cluster_ca_certificate = kind_cluster.xops.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.xops.endpoint
    client_certificate     = kind_cluster.xops.client_certificate
    client_key             = kind_cluster.xops.client_key
    cluster_ca_certificate = kind_cluster.xops.cluster_ca_certificate
  }
}

# --- Kind Cluster ---
resource "kind_cluster" "xops" {
  name           = "xops"
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }
  }
}

# --- Kubernetes API readiness ---
resource "null_resource" "wait_for_api" {
  depends_on = [kind_cluster.xops]

  provisioner "local-exec" {
    command = "kubectl --context kind-xops wait --for=condition=Ready nodes --all --timeout=120s && kubectl --context kind-xops get --raw /readyz"
  }
}

# --- Namespaces ---
resource "kubernetes_namespace" "namespaces" {
  for_each   = toset(["dev", "prod"])
  depends_on = [null_resource.wait_for_api]
  metadata {
    name = each.key
  }
}

# --- Ingress NGINX (Kind Manifest) ---
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  timeout          = 900
  cleanup_on_fail  = true
  depends_on       = [null_resource.wait_for_api]

  set {
    name  = "controller.hostPort.enabled"
    value = "true"
  }

  set {
    name = "controller.service.type"
    value = "NodePort"
  }

  set {
    name  = "controller.admissionWebhooks.enabled"
    value = "false"
  }
}

# --- Kyverno Helm Chart ---
resource "helm_release" "kyverno" {
  name             = "kyverno"
  version          = "3.9.2"
  repository       = "oci://ghcr.io/kyverno/charts"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  timeout          = 900
  cleanup_on_fail  = true
  depends_on       = [null_resource.wait_for_api]
}

# --- Metrics Server (required for HPA) ---
resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  namespace        = "kube-system"
  timeout          = 900
  cleanup_on_fail  = true
  depends_on       = [null_resource.wait_for_api]

  set {
    name  = "args"
    value = "{--kubelet-insecure-tls}"
  }
}
