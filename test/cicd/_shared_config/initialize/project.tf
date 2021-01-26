# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

data "google_project" "build" {
  project_id = local.build_project_id
}

data "google_project" "platform" {
  project_id = var.platform_default_project_id
}

data "google_project" "platform_terraform" {
  project_id = local.platform_terraform_project_id
}

resource "google_project_service" "build" {
  for_each = toset(
    [
      "cloudbuild.googleapis.com",
      "cloudresourcemanager.googleapis.com",
      "cloudscheduler.googleapis.com",
      "containerscanning.googleapis.com",
      "iam.googleapis.com",
      "secretmanager.googleapis.com",
      "serviceusage.googleapis.com"
    ]
  )

  disable_dependent_services = false
  disable_on_destroy         = false
  project                    = data.google_project.build.project_id
  service                    = each.value
}

resource "google_project_service" "platform" {
  for_each = toset(
    [
      "cloudresourcemanager.googleapis.com",
      "iam.googleapis.com",
      "secretmanager.googleapis.com",
      "serviceusage.googleapis.com"
    ]
  )

  disable_dependent_services = false
  disable_on_destroy         = false
  project                    = data.google_project.platform.project_id
  service                    = each.value
}

resource "google_project_service" "platform_terraform" {
  for_each = toset(
    [
      "cloudresourcemanager.googleapis.com",
      "iam.googleapis.com",
      "serviceusage.googleapis.com"
    ]
  )

  disable_dependent_services = false
  disable_on_destroy         = false
  project                    = data.google_project.platform_terraform.project_id
  service                    = each.value
}
