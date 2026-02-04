# Copyright 2024 Google LLC
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

resource "google_service_account" "cicd_cloud_build" {
  account_id   = "cicd-cloud-build"
  description  = "Terraform-managed service account for Cloud Build builds."
  display_name = "cicd-cloud-build service account"
  project      = data.google_project.build.project_id
}

resource "google_service_account" "cicd_scheduler" {
  account_id   = "cicd-scheduler"
  description  = "Terraform-managed service account for triggering scheduled Cloud Build builds."
  display_name = "cicd-scheduler service account"
  project      = data.google_project.build.project_id
}

