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
  project_id_build_prod       = data.google_project.build_prod.project_id
  project_id_fleet_prod       = data.google_project.fleet_prod.project_id
  project_id_gdcv_on_gce_prod = data.google_project.gdcv_on_gce_prod.project_id
}

data "google_project" "build_prod" {
  project_id = var.google_project_id_build_prod
}

data "google_project" "fleet_prod" {
  project_id = var.google_project_id_fleet_prod
}

data "google_project" "gdcv_on_gce_prod" {
  project_id = var.google_project_id_gdcv_on_gce_prod
}

resource "google_project_service" "cloudresourcemanager_googleapis_com_gdcv_on_gce_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_gdcv_on_gce_prod
  service                    = "cloudresourcemanager.googleapis.com"
}

resource "google_project_service" "compute_googleapis_com_gdcv_on_gce_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_gdcv_on_gce_prod
  service                    = "compute.googleapis.com"
}

resource "google_project_service" "iam_googleapis_com_gdcv_on_gce_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_gdcv_on_gce_prod
  service                    = "iam.googleapis.com"
}

resource "google_project_service" "networkmanagement_googleapis_com_gdcv_on_gce_prod" {
  disable_dependent_services = true
  disable_on_destroy         = false
  project                    = local.project_id_gdcv_on_gce_prod
  service                    = "networkmanagement.googleapis.com"
}
