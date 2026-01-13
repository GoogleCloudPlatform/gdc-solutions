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
  artifact_registry_hostname = "${google_artifact_registry_repository.cymbal_bank.location}-docker.pkg.dev"
  artifact_registry_repo_url = "${local.artifact_registry_hostname}/${google_artifact_registry_repository.cymbal_bank.project}/${google_artifact_registry_repository.cymbal_bank.name}"
}

resource "google_artifact_registry_repository" "cymbal_bank" {
  depends_on = [google_project_service.artifactregistry_googleapis_com_build_prod]

  description   = "Cymbal Bank image repository"
  format        = "DOCKER"
  location      = var.google_region_build_prod
  project       = local.project_id_build_prod
  repository_id = "cymbal-bank"

  # TODO: Add back in once skaffold tagging policy is figured out
  #docker_config {
  #  immutable_tags = true
  #}
}

resource "null_resource" "configure_image_auth" {
  provisioner "local-exec" {
    command     = "gcloud auth configure-docker ${google_artifact_registry_repository.cymbal_bank.location}-docker.pkg.dev"
    interpreter = ["bash", "-c"]
    working_dir = local.application_dir
  }
}
