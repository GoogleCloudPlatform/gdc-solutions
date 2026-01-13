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

resource "google_secret_manager_secret" "gdcv_ssh_private_key" {
  depends_on = [google_project_service.secretmanager_googleapis_com_build_prod]

  project   = local.project_id_build_prod
  secret_id = "gdcv_ssh_private_key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "gdcv_ssh_public_key" {
  depends_on = [google_project_service.secretmanager_googleapis_com_build_prod]

  project   = local.project_id_build_prod
  secret_id = "gdcv_ssh_public_key"

  replication {
    auto {}
  }
}
