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

resource "tls_private_key" "gdcv_ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

data "google_secret_manager_secret" "gdcv_ssh_private_key" {
  project   = local.project_id_build_prod
  secret_id = "gdcv_ssh_private_key"
}

resource "google_secret_manager_secret_version" "gdcv_ssh_private_key" {
  secret      = data.google_secret_manager_secret.gdcv_ssh_private_key.id
  secret_data = tls_private_key.gdcv_ssh.private_key_openssh
}

data "google_secret_manager_secret" "gdcv_ssh_public_key" {
  project   = local.project_id_build_prod
  secret_id = "gdcv_ssh_public_key"
}

resource "google_secret_manager_secret_version" "gdcv_ssh_public_key" {
  secret      = data.google_secret_manager_secret.gdcv_ssh_public_key.id
  secret_data = tls_private_key.gdcv_ssh.public_key_openssh
}

resource "local_sensitive_file" "gdcv_ssh_private_key" {
  content  = tls_private_key.gdcv_ssh.private_key_openssh
  filename = "${path.module}/../../../ssh/gdcv_ssh_id_rsa"
}

resource "local_file" "gdcv_ssh_public_key" {
  content  = tls_private_key.gdcv_ssh.public_key_openssh
  filename = "${path.module}/../../../ssh/gdcv_ssh_id_rsa.pub"
}
