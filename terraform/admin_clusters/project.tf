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
  project_id_build_prod = data.google_project.build_prod.project_id
  project_id_fleet_prod = data.google_project.fleet_prod.project_id
}

data "google_project" "build_prod" {
  project_id = var.google_project_id_build_prod
}

data "google_project" "fleet_prod" {
  project_id = var.google_project_id_fleet_prod
}

resource "google_project_service" "anthos_googleapis_com_fleet_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_fleet_prod
  service                    = "anthos.googleapis.com"
}

resource "google_project_service" "anthosaudit_googleapis_com_fleet_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_fleet_prod
  service                    = "anthosaudit.googleapis.com"
}

resource "google_project_service" "cloudresourcemanager_googleapis_com_fleet_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_fleet_prod
  service                    = "cloudresourcemanager.googleapis.com"
}

resource "google_project_service" "connectgateway_googleapis_com_fleet_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_fleet_prod
  service                    = "connectgateway.googleapis.com"
}

resource "google_project_service" "gkeconnect_googleapis_com_fleet_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_fleet_prod
  service                    = "gkeconnect.googleapis.com"
}

resource "google_project_service" "gkehub_googleapis_com_fleet_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_fleet_prod
  service                    = "gkehub.googleapis.com"
}

resource "google_project_service" "gkeonprem_googleapis_com_fleet_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_fleet_prod
  service                    = "gkeonprem.googleapis.com"
}

resource "google_project_service" "iam_googleapis_com_fleet_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_fleet_prod
  service                    = "iam.googleapis.com"
}
