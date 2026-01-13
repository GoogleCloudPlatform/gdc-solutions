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

resource "tls_private_key" "cymbal_bank_jwt" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "google_secret_manager_secret" "cymbal_bank_jwt_private_key" {
  project   = local.project_id_app_prod
  secret_id = "cymbal_bank_jwt_private_key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "cymbal_bank_jwt_private_key" {
  secret      = google_secret_manager_secret.cymbal_bank_jwt_private_key.id
  secret_data = tls_private_key.cymbal_bank_jwt.private_key_pem
}

resource "google_secret_manager_secret" "cymbal_bank_jwt_public_key" {
  project   = local.project_id_app_prod
  secret_id = "cymbal_bank_jwt_public_key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "cymbal_bank_jwt_public_key" {
  secret      = google_secret_manager_secret.cymbal_bank_jwt_public_key.id
  secret_data = tls_private_key.cymbal_bank_jwt.public_key_pem
}
