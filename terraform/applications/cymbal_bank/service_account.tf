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

###############################################################################
# Backend Workload Identity Service Account
###############################################################################
resource "google_service_account" "wi_cymbal_bank_backend" {
  project    = local.project_id_app_prod
  account_id = "wi-cymbal-bank-backend"
}

# IAM workloadIdentityUser service account role binding
resource "google_service_account_iam_member" "wi_cymbal_bank_backend_workload_identity_user" {
  member             = "serviceAccount:${data.google_project.fleet_prod.project_id}.svc.id.goog[${local.k8s_namespace}/${local.k8s_service_account_backend}]"
  role               = "roles/iam.workloadIdentityUser"
  service_account_id = google_service_account.wi_cymbal_bank_backend.id
}

###########################################################
# IAM project role binding
resource "google_project_iam_member" "wi_cymbal_bank_backend_cloudtrace_agent" {
  member  = google_service_account.wi_cymbal_bank_backend.member
  project = local.project_id_app_prod
  role    = "roles/cloudtrace.agent"
}

resource "google_project_iam_member" "wi_cymbal_bank_backend_cloudsql_client" {
  depends_on = [google_project_service.sqladmin_googleapis_com_app_prod]

  member  = google_service_account.wi_cymbal_bank_backend.member
  project = local.project_id_app_prod
  role    = "roles/cloudsql.client"
}

resource "google_project_iam_member" "wi_cymbal_bank_backend_logging_logwriter" {
  member  = google_service_account.wi_cymbal_bank_backend.member
  project = local.project_id_app_prod
  role    = "roles/logging.logWriter"
}

resource "google_project_iam_member" "wi_cymbal_bank_backend_monitoring_metricwriter" {
  member  = google_service_account.wi_cymbal_bank_backend.member
  project = local.project_id_app_prod
  role    = "roles/monitoring.metricWriter"
}


###############################################################################
# Frontend Workload Identity Service Account
###############################################################################
resource "google_service_account" "wi_cymbal_bank_frontend" {
  project    = local.project_id_app_prod
  account_id = "wi-cymbal-bank-frontend"
}

# Frontend Workload Identity Service Account role binding
resource "google_service_account_iam_member" "wi_cymbal_bank_frontend_workload_identity_user" {
  member             = "serviceAccount:${data.google_project.fleet_prod.project_id}.svc.id.goog[${local.k8s_namespace}/${local.k8s_service_account_frontend}]"
  role               = "roles/iam.workloadIdentityUser"
  service_account_id = google_service_account.wi_cymbal_bank_frontend.id
}

###########################################################
# IAM project role binding
resource "google_project_iam_member" "wi_cymbal_bank_frontend_cloudtrace_agent" {
  member  = google_service_account.wi_cymbal_bank_frontend.member
  project = local.project_id_app_prod
  role    = "roles/cloudtrace.agent"
}

resource "google_project_iam_member" "wi_cymbal_bank_frontend_logging_logwriter" {
  member  = google_service_account.wi_cymbal_bank_frontend.member
  project = local.project_id_app_prod
  role    = "roles/logging.logWriter"
}

resource "google_project_iam_member" "wi_cymbal_bank_frontend_monitoring_metricwriter" {
  member  = google_service_account.wi_cymbal_bank_frontend.member
  project = local.project_id_app_prod
  role    = "roles/monitoring.metricWriter"
}

###############################################################################
# On-prem Artifact Registry Service Account
###############################################################################
resource "google_service_account" "onprem_cymbal_bank_ar" {
  project    = local.project_id_build_prod
  account_id = "onprem-cymbal-bank-ar"
}

resource "google_service_account_key" "onprem_cymbal_bank_ar" {
  service_account_id = google_service_account.onprem_cymbal_bank_ar.name
}

resource "google_project_iam_member" "onprem_cymbal_bank_ar_artifactregistry_reader" {
  member  = google_service_account.onprem_cymbal_bank_ar.member
  project = local.project_id_build_prod
  role    = "roles/artifactregistry.reader"
}
