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

locals {
  build_ar_docker_hub_remote_repository_name = "docker-io"
  build_ar_docker_hub_remote_repository_url  = "${local.build_location}-docker.pkg.dev/${local.build_project_id}/${local.build_ar_docker_hub_remote_repository_name}"
  build_github_token_secret_name             = var.build_github_token_secret_name != null ? var.build_github_token_secret_name : "github-token"
  build_location                             = var.build_location != null ? var.build_location : var.platform_default_location
  build_project_id                           = var.build_project_id != null ? var.build_project_id : var.platform_default_project_id
}

variable "build_github_token_secret_name" {
  default     = null
  description = "The Secret Manager secret name for the 'build' GitHub token."
  type        = string
}

variable "build_location" {
  default     = null
  description = "The Google Cloud location to use when creating resources for the 'build' project."
  type        = string
}

variable "build_project_id" {
  default     = null
  description = "The Google Cloud project ID for the 'build' project."
  type        = string
}
