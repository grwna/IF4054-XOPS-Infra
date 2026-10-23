terraform {
  backend "local" {
    path = "/root/tfstate/terraform.tfstate"
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
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

# --- Kind Cluster ---
resource "kind_cluster" "xops" {
  name           = "xops"
  wait_for_ready = true
  kind_config    = file("cluster.yaml")
}

# --- Namespaces ---
resource "kubernetes_namespace" "namespaces" {
  for_each   = toset(["dev", "prod"])
  depends_on = [kind_cluster.xops]
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
  depends_on       = [kind_cluster.xops]

  set {
    name  = "controller.hostPort.enabled"
    value = "true"
  }
}

# --- Kyverno Helm Chart ---
resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  wait             = true
  depends_on       = [kind_cluster.xops]
}

# --- Metrics Server (required for HPA) ---
resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  namespace        = "kube-system"
  wait             = true
  depends_on       = [kind_cluster.xops]

  set {
    name  = "args"
    value = "{--kubelet-insecure-tls}"
  }
}
