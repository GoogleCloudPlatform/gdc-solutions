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
  gdcv_baremetal_cloud_ops_key_file     = "${path.module}/../../keys/gdcv_baremetal_cloud_ops.json"
  gdcv_baremetal_connect_agent_key_file = "${path.module}/../../keys/gdcv_baremetal_connect_agent.json"
  gdcv_baremetal_fleet_admin_key_file   = "${path.module}/../../keys/gdcv_baremetal_fleet_admin.json"
  gdcv_baremetal_registry_key_file      = "${path.module}/../../keys/gdcv_baremetal_registry.json"
}

# Cloud operations service account(anthos-baremetal-cloud-ops)
resource "google_service_account" "gdcv_baremetal_cloud_ops" {
  description  = "GDC-V Baremetal Cloud Operations service account"
  display_name = "gdcv-baremetal-cloud-ops"
  project      = local.project_id_fleet_prod
  account_id   = "gdcv-baremetal-cloud-ops"
}

resource "google_service_account_key" "gdcv_baremetal_cloud_ops" {
  service_account_id = google_service_account.gdcv_baremetal_cloud_ops.name
}

resource "local_file" "gdcv_baremetal_cloud_ops_key" {
  content  = base64decode(google_service_account_key.gdcv_baremetal_cloud_ops.private_key)
  filename = local.gdcv_baremetal_cloud_ops_key_file
}

resource "google_project_iam_member" "gdcv_baremetal_cloud_ops_logging_log_writer" {
  member  = google_service_account.gdcv_baremetal_cloud_ops.member
  project = local.project_id_fleet_prod
  role    = "roles/logging.logWriter"
}

resource "google_project_iam_member" "gdcv_baremetal_cloud_ops_monitoring_dashboard_editor" {
  member  = google_service_account.gdcv_baremetal_cloud_ops.member
  project = local.project_id_fleet_prod
  role    = "roles/monitoring.dashboardEditor"
}

resource "google_project_iam_member" "gdcv_baremetal_cloud_ops_monitoring_metric_writer" {
  member  = google_service_account.gdcv_baremetal_cloud_ops.member
  project = local.project_id_fleet_prod
  role    = "roles/monitoring.metricWriter"
}

resource "google_project_iam_member" "gdcv_baremetal_cloud_ops_opsconfigmonitoring_resource_metadata_writer" {
  member  = google_service_account.gdcv_baremetal_cloud_ops.member
  project = local.project_id_fleet_prod
  role    = "roles/opsconfigmonitoring.resourceMetadata.writer"
}

resource "google_project_iam_member" "gdcv_baremetal_cloud_ops_stackdriver_resource_metadata_writer" {
  member  = google_service_account.gdcv_baremetal_cloud_ops.member
  project = local.project_id_fleet_prod
  role    = "roles/stackdriver.resourceMetadata.writer"
}



# Connect agent service account(anthos-baremetal-connect)
resource "google_service_account" "gdcv_baremetal_connect_agent" {
  description  = "GDC-V Baremetal Connect Agent service account"
  display_name = "gdcv-baremetal-connect-agent"
  project      = local.project_id_fleet_prod
  account_id   = "gdcv-baremetal-connect-agent"
}

resource "google_service_account_key" "gdcv_baremetal_connect_agent" {
  service_account_id = google_service_account.gdcv_baremetal_connect_agent.name
}

resource "local_file" "gdcv_baremetal_connect_agent_key" {
  content  = base64decode(google_service_account_key.gdcv_baremetal_connect_agent.private_key)
  filename = local.gdcv_baremetal_connect_agent_key_file
}

resource "google_project_iam_member" "gdcv_baremetal_connect_agent_gkehub_connect" {
  member  = google_service_account.gdcv_baremetal_connect_agent.member
  project = local.project_id_fleet_prod
  role    = "roles/gkehub.connect"
}



# Fleet admin service account(anthos-baremetal-register)
resource "google_service_account" "gdcv_baremetal_fleet_admin" {
  description  = "GDC-V Baremetal Fleet Admin service account"
  display_name = "gdcv-baremetal-fleet-admin"
  project      = local.project_id_fleet_prod
  account_id   = "gdcv-baremetal-fleet-admin"
}

resource "google_service_account_key" "gdcv_baremetal_fleet_admin" {
  service_account_id = google_service_account.gdcv_baremetal_fleet_admin.name
}

resource "local_file" "gdcv_baremetal_fleet_admin_key" {
  content  = base64decode(google_service_account_key.gdcv_baremetal_fleet_admin.private_key)
  filename = local.gdcv_baremetal_fleet_admin_key_file
}

resource "google_project_iam_member" "gdcv_baremetal_fleet_admin_gkehub_admin" {
  member  = google_service_account.gdcv_baremetal_fleet_admin.member
  project = local.project_id_fleet_prod
  role    = "roles/gkehub.admin"
}



# Registry service account(anthos-baremetal-gcr)
resource "google_service_account" "gdcv_baremetal_registry" {
  description  = "GDC-V Baremetal Registry service account"
  display_name = "gdcv-baremetal-registry"
  project      = local.project_id_fleet_prod
  account_id   = "gdcv-baremetal-registry"
}

resource "google_service_account_key" "gdcv_baremetal_registry" {
  service_account_id = google_service_account.gdcv_baremetal_registry.name
}

resource "local_file" "gdcv_baremetal_registry_key" {
  content  = base64decode(google_service_account_key.gdcv_baremetal_registry.private_key)
  filename = local.gdcv_baremetal_registry_key_file
}

#TODO: Possibly add a cloud storage SA - https://cloud.google.com/anthos/clusters/docs/bare-metal/latest/installing/configure-sa#bucket-sa
