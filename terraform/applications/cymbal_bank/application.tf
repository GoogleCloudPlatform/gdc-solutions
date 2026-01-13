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
  application_dir              = "${path.module}/../../../applications/cymbal-bank"
  fwi_workload_identity_pool   = "${local.project_id_fleet_prod}.svc.id.goog"
  kubeconfig_dir               = abspath("${path.module}/../../../kubeconfig")
  k8s_namespace                = "cymbal-bank"
  k8s_service_account_backend  = "backend"
  k8s_service_account_frontend = "frontend"

  prepare_manifests_command = <<EOT
echo "Configure the Kubernetes namespace" && \
git restore src/components/production/kustomization.yaml && \
sed -i "s/namespace: bank-of-anthos-production/namespace: ${local.k8s_namespace}/" src/components/production/kustomization.yaml && \
echo "Configure the Kubernetes service accounts" && \
git restore src/components/backend/kustomization.yaml && \
sed -i "s/value: bank-of-anthos/value: ${local.k8s_service_account_backend}/" src/components/backend/kustomization.yaml  && \
git restore src/components/bank-of-anthos/kustomization.yaml && \
sed -i "s/value: bank-of-anthos/value: ${local.k8s_service_account_backend}/" src/components/bank-of-anthos/kustomization.yaml && \
git restore src/components/frontend/kustomization.yaml && \
sed -i "s/value: bank-of-anthos/value: ${local.k8s_service_account_frontend}/" src/components/frontend/kustomization.yaml && \
echo "Configure accounts-db settings" && \
git restore src/accounts/accounts-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)ACCOUNTS_DB_URI:.*$|\1ACCOUNTS_DB_URI: postgresql://${google_sql_user.cloud_sql_admin_user.name}:${google_sql_user.cloud_sql_admin_user.password}@127.0.0.1:5432/${google_sql_database.accounts.name}|' src/accounts/accounts-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_DB:.*$|\1POSTGRES_DB: ${google_sql_database.accounts.name}|' src/accounts/accounts-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_PASSWORD:.*$|\1POSTGRES_PASSWORD: ${google_sql_user.cloud_sql_admin_user.password}|' src/accounts/accounts-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_USER:.*$|\1POSTGRES_USER: ${google_sql_user.cloud_sql_admin_user.name}|' src/accounts/accounts-db/k8s/base/config.yaml && \
git restore src/components/cloud-sql/accounts-db.yaml && \
sed -i 's|^\([[:blank:]]*\)ACCOUNTS_DB_URI:.*$|\1ACCOUNTS_DB_URI: postgresql://${google_sql_user.cloud_sql_admin_user.name}:${google_sql_user.cloud_sql_admin_user.password}@127.0.0.1:5432/${google_sql_database.accounts.name}|' src/components/cloud-sql/accounts-db.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_DB:.*$|\1POSTGRES_DB: ${google_sql_database.accounts.name}|' src/components/cloud-sql/accounts-db.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_PASSWORD:.*$|\1POSTGRES_PASSWORD: ${google_sql_user.cloud_sql_admin_user.password}|' src/components/cloud-sql/accounts-db.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_USER:.*$|\1POSTGRES_USER: ${google_sql_user.cloud_sql_admin_user.name}|' src/components/cloud-sql/accounts-db.yaml && \
echo "Configure ledger-db settings" && \
git restore src/ledger/ledger-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_DB:.*$|\1POSTGRES_DB: ${google_sql_database.ledger.name}|' src/ledger/ledger-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_PASSWORD:.*$|\1POSTGRES_PASSWORD: ${google_sql_user.cloud_sql_admin_user.password}|' src/ledger/ledger-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_USER:.*$|\1POSTGRES_USER: ${google_sql_user.cloud_sql_admin_user.name}|' src/ledger/ledger-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)SPRING_DATASOURCE_PASSWORD:.*$|\1SPRING_DATASOURCE_PASSWORD: ${google_sql_user.cloud_sql_admin_user.password}|' src/ledger/ledger-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)SPRING_DATASOURCE_URL:.*$|\1SPRING_DATASOURCE_URL: jdbc:postgresql://127.0.0.1:5432/${google_sql_database.ledger.name}|' src/ledger/ledger-db/k8s/base/config.yaml && \
sed -i 's|^\([[:blank:]]*\)SPRING_DATASOURCE_USERNAME:.*$|\1SPRING_DATASOURCE_USERNAME: ${google_sql_user.cloud_sql_admin_user.name}|' src/ledger/ledger-db/k8s/base/config.yaml && \
git restore src/components/cloud-sql/ledger-db.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_DB:.*$|\1POSTGRES_DB: ${google_sql_database.ledger.name}|' src/components/cloud-sql/ledger-db.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_PASSWORD:.*$|\1POSTGRES_PASSWORD: ${google_sql_user.cloud_sql_admin_user.password}|' src/components/cloud-sql/ledger-db.yaml && \
sed -i 's|^\([[:blank:]]*\)POSTGRES_USER:.*$|\1POSTGRES_USER: ${google_sql_user.cloud_sql_admin_user.name}|' src/components/cloud-sql/ledger-db.yaml && \
sed -i 's|^\([[:blank:]]*\)SPRING_DATASOURCE_PASSWORD:.*$|\1SPRING_DATASOURCE_PASSWORD: ${google_sql_user.cloud_sql_admin_user.password}|' src/components/cloud-sql/ledger-db.yaml && \
sed -i 's|^\([[:blank:]]*\)SPRING_DATASOURCE_URL:.*$|\1SPRING_DATASOURCE_URL: jdbc:postgresql://127.0.0.1:5432/${google_sql_database.ledger.name}|' src/components/cloud-sql/ledger-db.yaml && \
sed -i 's|^\([[:blank:]]*\)SPRING_DATASOURCE_USERNAME:.*$|\1SPRING_DATASOURCE_USERNAME: ${google_sql_user.cloud_sql_admin_user.name}|' src/components/cloud-sql/ledger-db.yaml && \
echo "Configure FWI audience" && \
git restore src/components/backend-fwi/add-fwi.yaml && \
sed -i 's|audience: FWI_WORKLOAD_IDENTITY_POOL|audience: ${local.fwi_workload_identity_pool}|' src/components/backend-fwi/add-fwi.yaml && \
git restore src/components/cloud-sql-fwi/add-fwi.yaml && \
sed -i 's|audience: FWI_WORKLOAD_IDENTITY_POOL|audience: ${local.fwi_workload_identity_pool}|' src/components/cloud-sql-fwi/add-fwi.yaml && \
git restore src/components/frontend-fwi/add-fwi.yaml && \
sed -i 's|audience: FWI_WORKLOAD_IDENTITY_POOL|audience: ${local.fwi_workload_identity_pool}|' src/components/frontend-fwi/add-fwi.yaml
EOT
}

resource "null_resource" "initialize_submodule" {
  provisioner "local-exec" {
    command     = "git submodule update --init && git clean -xfd"
    interpreter = ["bash", "-c"]
    working_dir = local.application_dir
  }
}

resource "null_resource" "prepare_manifests" {
  depends_on = [null_resource.initialize_submodule]

  triggers = {
    md5 = md5(local.prepare_manifests_command)
  }

  provisioner "local-exec" {
    command     = local.prepare_manifests_command
    interpreter = ["bash", "-x", "-c"]
    quiet       = true
    working_dir = local.application_dir
  }
}

resource "null_resource" "initialize_account_database" {
  depends_on = [
    google_project_iam_member.wi_cymbal_bank_backend_cloudsql_client,
    google_service_account_iam_member.wi_cymbal_bank_backend_workload_identity_user,
    google_sql_database_instance.cymbal_bank,
    kubernetes_config_map.cloud_sql_admin_user_dc1a_000_prod,
    kubernetes_config_map.demo_data_config_user_dc1a_000_prod,
    kubernetes_config_map.environment_config_user_dc1a_000_prod,
    kubernetes_config_map.service_api_config_user_dc1a_000_prod,
    kubernetes_secret.artifact_registry_user_dc1a_000_prod,
    kubernetes_secret.jwt_user_dc1a_000_prod,
    kubernetes_service_account.cymbal_bank_backend_user_dc1a_000_prod,
    null_resource.prepare_manifests
  ]

  provisioner "local-exec" {
    command     = <<EOT
echo "Initialize the account databases"
kubectl --kubeconfig ${local.kubeconfig_dir}/${var.user_dc1a_000_prod_cluster_name} --namespace ${kubernetes_namespace.cymbal_bank_user_dc1a_000_prod.id} delete job/populate-accounts-db &>/dev/null
skaffold run \
--default-repo ${local.artifact_registry_repo_url} \
--kubeconfig ${local.kubeconfig_user_dc1a_000_prod} \
--profile=init-db-production-fwi --module=accounts-db \
--skip-tests=true && \
echo "Waiting for job to complete..." && \
kubectl --kubeconfig ${local.kubeconfig_dir}/${var.user_dc1a_000_prod_cluster_name} --namespace ${kubernetes_namespace.cymbal_bank_user_dc1a_000_prod.id} wait job/populate-accounts-db --for=condition=complete --timeout=120s
EOT
    interpreter = ["bash", "-c"]
    working_dir = local.application_dir
  }
}

resource "null_resource" "initialize_ledger_database" {
  depends_on = [
    google_project_iam_member.wi_cymbal_bank_backend_cloudsql_client,
    google_service_account_iam_member.wi_cymbal_bank_backend_workload_identity_user,
    google_sql_database_instance.cymbal_bank,
    kubernetes_config_map.cloud_sql_admin_user_dc1a_000_prod,
    kubernetes_config_map.demo_data_config_user_dc1a_000_prod,
    kubernetes_config_map.environment_config_user_dc1a_000_prod,
    kubernetes_config_map.service_api_config_user_dc1a_000_prod,
    kubernetes_secret.artifact_registry_user_dc1a_000_prod,
    kubernetes_secret.jwt_user_dc1a_000_prod,
    kubernetes_service_account.cymbal_bank_backend_user_dc1a_000_prod,
    null_resource.prepare_manifests
  ]

  provisioner "local-exec" {
    command     = <<EOT
echo "Initialize the ledger databases"
kubectl --kubeconfig ${local.kubeconfig_dir}/${var.user_dc1a_000_prod_cluster_name} --namespace ${kubernetes_namespace.cymbal_bank_user_dc1a_000_prod.id} delete job/populate-ledger-db &>/dev/null
skaffold run \
--default-repo ${local.artifact_registry_repo_url} \
--kubeconfig ${local.kubeconfig_user_dc1a_000_prod} \
--profile=init-db-production-fwi --module=ledger-db \
--skip-tests=true && \
echo "Waiting for job to complete..." && \
kubectl --kubeconfig ${local.kubeconfig_dir}/${var.user_dc1a_000_prod_cluster_name} --namespace ${kubernetes_namespace.cymbal_bank_user_dc1a_000_prod.id} wait job/populate-ledger-db --for=condition=complete --timeout=120s
EOT
    interpreter = ["bash", "-c"]
    working_dir = local.application_dir
  }
}
