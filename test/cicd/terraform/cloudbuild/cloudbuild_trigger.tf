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

resource "google_cloudbuild_trigger" "gdcs_cicd_docker_builder_image" {
  filename = "test/cicd/container_images/docker_builder/cloudbuild.yaml"
  included_files = [
    "test/cicd/container_images/docker_builder/**",
  ]
  location        = local.build_location
  name            = "gdcs-cicd-docker-builder-image"
  project         = data.google_project.build.project_id
  service_account = google_service_account.cicd_cloud_build.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.gdc_solutions.id

    push {
      branch       = "^main$"
      invert_regex = false
    }
  }
}

resource "google_cloudbuild_trigger" "gdcs_cicd_project_cleaner" {
  location        = local.build_location
  name            = "gdcs-cicd-project-cleaner"
  project         = data.google_project.build.project_id
  service_account = google_service_account.cicd_cloud_build.id

  git_file_source {
    path       = "test/cicd/cloudbuild/cicd/cicd-project-cleaner.yaml"
    repository = google_cloudbuildv2_repository.gdc_solutions.id
    revision   = "refs/heads/main"
    repo_type  = "GITHUB"
  }

  source_to_build {
    repository = google_cloudbuildv2_repository.gdc_solutions.id
    ref        = "refs/heads/main"
    repo_type  = "GITHUB"
  }

  substitutions = {
    _DEBUG = "false"
    _HOURS = "6"
  }
}

resource "google_cloudbuild_trigger" "gdcs_cicd_runner_image" {
  filename = "test/cicd/container_images/cicd_runner/cloudbuild.yaml"
  included_files = [
    "test/cicd/container_images/cicd_runner/**",
  ]
  location        = local.build_location
  name            = "gdcs-cicd-runner-image"
  project         = data.google_project.build.project_id
  service_account = google_service_account.cicd_cloud_build.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.gdc_solutions.id

    push {
      branch       = "^main$"
      invert_regex = false
    }
  }

  substitutions = {
    _WAIT_FOR_TRIGGER = google_cloudbuild_trigger.gdcs_cicd_docker_builder_image.trigger_id
  }
}

###################################################################################################

resource "google_cloudbuild_trigger" "gdcs_cicd_terraform" {
  filename = "test/cicd/terraform/cloudbuild.yaml"
  ignored_files = [
    "test/cicd/terraform/README.md",
  ]
  included_files = [
    "test/cicd/terraform/**",
  ]
  location        = local.build_location
  name            = "gdcs-cicd-terraform"
  project         = data.google_project.build.project_id
  service_account = google_service_account.cicd_cloud_build.id

  repository_event_config {
    repository = google_cloudbuildv2_repository.gdc_solutions.id

    push {
      branch       = "^main$"
      invert_regex = false
    }
  }

  substitutions = {
    _WAIT_FOR_TRIGGER = google_cloudbuild_trigger.gdcs_cicd_runner_image.trigger_id
  }
}
