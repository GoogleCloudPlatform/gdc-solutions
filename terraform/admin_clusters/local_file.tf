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

data "google_secret_manager_secret_version" "gdcv_ssh_private_key" {
  project = local.project_id_build_prod
  secret  = "gdcv_ssh_private_key"
}

# resource "local_sensitive_file" "gdcv_ssh_private_key" {
#   content  = data.google_secret_manager_secret_version.gdcv_ssh_private_key.secret_data
#   filename = "${path.module}/../../ssh/gdcv_ssh_id_rsa"
# }

# data "google_secret_manager_secret_version" "gdcv_ssh_public_key" {
#   project = local.project_id_build_prod
#   secret  = "gdcv_ssh_public_key"
# }

# resource "local_file" "gdcv_ssh_public_key" {
#   content  = data.google_secret_manager_secret_version.gdcv_ssh_public_key.secret_data
#   filename = "${path.module}/../../ssh/gdcv_ssh_id_rsa.pub"
# }
