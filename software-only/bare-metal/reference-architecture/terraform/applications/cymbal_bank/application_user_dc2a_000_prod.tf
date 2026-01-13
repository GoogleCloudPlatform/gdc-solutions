# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

locals {
  fwi_identity_provider_user_dc2a_000_prod = "https://gkehub.googleapis.com/projects/${local.project_id_fleet_prod}/locations/${var.user_dc2a_000_prod_region}/memberships/${var.user_dc2a_000_prod_cluster_name}"
  kubeconfig_user_dc2a_000_prod            = "${local.kubeconfig_dir}/${var.user_dc2a_000_prod_cluster_name}"
}



###############################################################################
# KUBERNETES PROVIDER
###############################################################################
provider "kubernetes" {
  alias       = "user_dc2a_000_prod"
  config_path = local.kubeconfig_user_dc2a_000_prod
}



###############################################################################
# KUBERNETES CONFIGMAPS
###############################################################################
# resource "kubernetes_config_map" "accounts_db_config_user_dc2a_000_prod" {
#   provider = kubernetes.user_dc2a_000_prod

#   data = {
#     ACCOUNTS_DB_URI   = "postgresql://${google_sql_user.cloud_sql_admin_user.name}:${google_sql_user.cloud_sql_admin_user.password}@127.0.0.1:5432/${google_sql_database.accounts.name}"
#     POSTGRES_DB       = google_sql_database.accounts.name
#     POSTGRES_PASSWORD = google_sql_user.cloud_sql_admin_user.password
#     POSTGRES_USER     = google_sql_user.cloud_sql_admin_user.name
#   }
#   metadata {
#     labels    = { app = "accounts-db" }
#     name      = "accounts-db-config"
#     namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
#   }
# }

resource "kubernetes_secret" "artifact_registry_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "${local.artifact_registry_hostname}" = {
          username = "_json_key"
          password = base64decode(google_service_account_key.onprem_cymbal_bank_ar.private_key)
          email    = google_service_account.onprem_cymbal_bank_ar.email
          auth     = base64encode("_json_key:${base64decode(google_service_account_key.onprem_cymbal_bank_ar.private_key)}")
        }
      }
    })
  }
  metadata {
    name      = "artifact-registry"
    namespace = local.k8s_namespace
  }
}

resource "kubernetes_config_map" "cloud_sql_admin_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  data = {
    username       = google_sql_user.cloud_sql_admin_user.name
    password       = google_sql_user.cloud_sql_admin_user.password
    connectionName = google_sql_database_instance.cymbal_bank.connection_name
  }
  metadata {
    name      = "cloud-sql-admin"
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}

resource "kubernetes_config_map" "demo_data_config_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  data = {
    DEMO_LOGIN_PASSWORD = "bankofanthos"
    DEMO_LOGIN_USERNAME = "testuser"
    USE_DEMO_DATA       = "True"
  }
  metadata {
    name      = "demo-data-config"
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}

resource "kubernetes_config_map" "environment_config_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  data = {
    LOCAL_ROUTING_NUM = "883745000"
    PUB_KEY_PATH      = "/tmp/.ssh/publickey"
  }
  metadata {
    name      = "environment-config"
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}

resource "kubernetes_config_map" "fwi_backend_adc_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  data = {
    config = templatefile(
      "${path.module}/templates/fwi_adc.jsontpl",
      {
        fwi_workload_identity_pool   = local.fwi_workload_identity_pool
        fwi_identity_provider        = local.fwi_identity_provider_user_dc2a_000_prod
        google_project_id            = local.project_id_app_prod
        google_service_account_email = google_service_account.wi_cymbal_bank_backend.email
      }
    )
  }
  metadata {
    name      = "backend-adc"
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}

resource "kubernetes_config_map" "fwi_frontend_adc_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  data = {
    config = templatefile(
      "${path.module}/templates/fwi_adc.jsontpl",
      {
        fwi_workload_identity_pool   = local.fwi_workload_identity_pool
        fwi_identity_provider        = local.fwi_identity_provider_user_dc2a_000_prod
        google_project_id            = local.project_id_app_prod
        google_service_account_email = google_service_account.wi_cymbal_bank_frontend.email
      }
    )
  }
  metadata {
    name      = "frontend-adc"
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}

# resource "kubernetes_config_map" "ledger_db_config_user_dc2a_000_prod" {
#   provider = kubernetes.user_dc2a_000_prod

#   data = {
#     POSTGRES_DB                = google_sql_database.ledger.name
#     POSTGRES_USER              = google_sql_user.cloud_sql_admin_user.name
#     POSTGRES_PASSWORD          = google_sql_user.cloud_sql_admin_user.password
#     SPRING_DATASOURCE_URL      = "jdbc:postgresql://127.0.0.1:5432/${google_sql_database.ledger.name}"
#     SPRING_DATASOURCE_USERNAME = google_sql_user.cloud_sql_admin_user.name
#     SPRING_DATASOURCE_PASSWORD = google_sql_user.cloud_sql_admin_user.password
#   }
#   metadata {
#     labels    = { app = "postgres" }
#     name      = "ledger-db-config"
#     namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
#   }
# }

resource "kubernetes_config_map" "service_api_config_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  data = {
    BALANCES_API_ADDR     = "balancereader:8080"
    CONTACTS_API_ADDR     = "contacts:8080"
    HISTORY_API_ADDR      = "transactionhistory:8080"
    TRANSACTIONS_API_ADDR = "ledgerwriter:8080"
    USERSERVICE_API_ADDR  = "userservice:8080"
  }
  metadata {
    name      = "service-api-config"
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}



###############################################################################
# KUBERNETES NAMESPACES
###############################################################################
resource "kubernetes_namespace" "cymbal_bank_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  metadata {
    name = local.k8s_namespace
  }
}



###############################################################################
# KUBERNETES SECRETES
###############################################################################
resource "kubernetes_secret" "jwt_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  type = "Opaque"

  data = {
    "jwtRS256.key"     = tls_private_key.cymbal_bank_jwt.private_key_pem
    "jwtRS256.key.pub" = tls_private_key.cymbal_bank_jwt.public_key_pem
  }
  metadata {
    name      = "jwt-key"
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}



###############################################################################
# KUBERNETES SERVICE ACCOUNT
###############################################################################
resource "kubernetes_service_account" "cymbal_bank_backend_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  image_pull_secret {
    name = kubernetes_secret.artifact_registry_user_dc2a_000_prod.metadata.0.name
  }
  metadata {
    annotations = {
      "iam.gke.io/gcp-service-account" : google_service_account.wi_cymbal_bank_backend.email
    }
    name      = local.k8s_service_account_backend
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}

resource "kubernetes_service_account" "cymbal_bank_frontend_user_dc2a_000_prod" {
  provider = kubernetes.user_dc2a_000_prod

  image_pull_secret {
    name = kubernetes_secret.artifact_registry_user_dc2a_000_prod.metadata.0.name
  }
  metadata {
    annotations = {
      "iam.gke.io/gcp-service-account" : google_service_account.wi_cymbal_bank_frontend.email
    }
    name      = local.k8s_service_account_frontend
    namespace = kubernetes_namespace.cymbal_bank_user_dc2a_000_prod.id
  }
}


###############################################################################
# DEPLOYMENT
###############################################################################
resource "null_resource" "deploy_microservices_user_dc2a_000_prod" {
  depends_on = [
    google_sql_database.accounts,
    google_sql_database.ledger,
    kubernetes_service_account.cymbal_bank_backend_user_dc2a_000_prod,
    kubernetes_service_account.cymbal_bank_frontend_user_dc2a_000_prod,
    null_resource.deploy_microservices_user_dc1a_000_prod,
    null_resource.initialize_account_database,
    null_resource.initialize_ledger_database,
  ]

  triggers = {
    application_dir            = local.application_dir
    artifact_registry_repo_url = local.artifact_registry_repo_url
    kubeconfig                 = local.kubeconfig_user_dc2a_000_prod
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Deploy application" && \
skaffold run \
--default-repo ${self.triggers.artifact_registry_repo_url} \
--kubeconfig ${self.triggers.kubeconfig} \
--profile production-fwi,production-fwi-ingress \
--skip-tests=true
EOT
    interpreter = ["bash", "-c"]
    working_dir = self.triggers.application_dir
  }

  provisioner "local-exec" {
    when        = destroy
    command     = <<EOT
echo "Delete the application" && \
skaffold delete \
--default-repo ${self.triggers.artifact_registry_repo_url} \
--kubeconfig ${self.triggers.kubeconfig} \
--profile production-fwi,production-fwi-ingress
EOT
    interpreter = ["bash", "-c"]
    working_dir = self.triggers.application_dir
  }
}

output "ingress_url_user_dc2a_000_prod" {
  value = "http://${var.user_dc2a_000_prod_ingress_vip}/"
}
