terraform {
  required_providers {
    kind = {
      source = "tehcyx/kind"
      version = "0.0.16"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.18.1"
    }

    helm = {
      source = "hashicorp/helm"
      version = "2.8.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "3.2.1"
    }
  }

  required_version = ">= 1.0.0"
}

variable "kind_cluster_config_path" {
  type        = string
  description = "The location where this cluster's kubeconfig will be saved to."
  default     = "~/.kube/config"
}

provider "kind" {
}

provider "kubernetes" {
  config_path = pathexpand(var.kind_cluster_config_path)
}

provider "helm" {
  kubernetes {
    config_path = pathexpand(var.kind_cluster_config_path)
  }
}

resource "kind_cluster" "k8s_cluster" {
  name = "kind-cluster"
  kubeconfig_path = pathexpand(var.kind_cluster_config_path)
  wait_for_ready  = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      extra_port_mappings {
        container_port = 30000
        host_port      = 8080
      }
      extra_port_mappings {
        container_port = 30001
        host_port      = 9000
      }
      extra_port_mappings {
        container_port = 30002
        host_port      = 9001
      }
      extra_port_mappings {
        container_port = 30003
        host_port      = 5432
      }
    }
  }
}

resource "helm_release" "trino_cluster" {
  name       = "trino-cluster"

  repository = "https://trinodb.github.io/charts"
  chart      = "trino"

  values = [file("trino-values.yaml")]

  depends_on = [kind_cluster.k8s_cluster]
}

resource "helm_release" "minio_cluster" {
  name       = "minio-cluster"

  repository = "https://charts.min.io"
  chart      = "minio"

  values = [file("minio-values.yaml")]

  depends_on = [kind_cluster.k8s_cluster]

  # https://artifacthub.io/packages/helm/minio-official/minio#create-buckets-after-install
  set {
    name  = "buckets[0].name"
    value = "lakehouse"
  }

  set {
    name  = "buckets[0].policy"
    value = "public"
  }

  set {
    name  = "buckets[0].purge"
    value = "true"
  }

}

resource "helm_release" "postgresql" {
  name       = "postgresql"

  repository = "https://cetic.github.io/helm-charts"
  chart      = "postgresql"

  values = [file("postgresql-values.yaml")]

  depends_on = [kind_cluster.k8s_cluster]
}

resource "null_resource" "wait_for_services" {
  triggers = {
    key = uuid()
  }

  provisioner "local-exec" {
    command = <<EOF
      printf "\nWaiting for Services...\n"
      kubectl wait --namespace ${helm_release.trino_cluster.namespace} \
        --for condition=Ready \
        --timeout=90s \
        pods --all
      kubectl rollout status -w deployments
    EOF
  }

  depends_on = [helm_release.trino_cluster, helm_release.minio_cluster, helm_release.postgresql]
}

resource "kubernetes_service" "add_node_port_trino" {
  metadata {
    name = "trino-cluster-np"
  }
  spec {
    port {
      port        = 8080
      node_port = 30000
    }
    selector = {
      app: "trino"
      release: "trino-cluster"
    }

    type = "NodePort"
  }
  depends_on = [null_resource.wait_for_services]
}

resource "kubernetes_service" "add_node_port_minio" {
  metadata {
    name = "minio-cluster-np"
  }
  spec {
    port {
      port        = 9000
      node_port = 30001
    }

    selector = {
      app: "minio"
      release: "minio-cluster"
    }

    type = "NodePort"
  }
  depends_on = [null_resource.wait_for_services]
}

resource "kubernetes_service" "add_node_port_minio_console" {
  metadata {
    name = "minio-cluster-console-np"
  }
  spec {
    port {
      port        = 9001
      node_port = 30002
    }

    selector = {
      app: "minio"
      release: "minio-cluster"
    }

    type = "NodePort"
  }
  depends_on = [null_resource.wait_for_services]
}

resource "kubernetes_service" "add_node_port_postgres" {
  metadata {
    name = "postgres-cluster-np"
  }
  spec {
    port {
      port        = 5432
      node_port = 30003
    }

    selector = {
      app: "postgresql"
      release: "postgresql"
    }

    type = "NodePort"
  }
  depends_on = [null_resource.wait_for_services]
}
