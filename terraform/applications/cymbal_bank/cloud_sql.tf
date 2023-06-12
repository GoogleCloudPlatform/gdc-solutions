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

# Cloud SQL Instance
resource "google_sql_database_instance" "cymbal_bank" {
  depends_on = [google_project_service.sqladmin_googleapis_com_app_prod]

  database_version    = "POSTGRES_15"
  deletion_protection = false
  name                = "cymbal-bank"
  project             = local.project_id_app_prod
  region              = var.google_region_app_cymbal_bank_prod

  settings {
    availability_type = "REGIONAL"
    tier              = "db-custom-4-16384"
  }
}

# Cloud SQL admin user
resource "random_password" "cloud_sql_admin_password" {
  length           = 16
  special          = true
  override_special = "!%*()-_{}<>"
}

resource "google_sql_user" "cloud_sql_admin_user" {
  instance = google_sql_database_instance.cymbal_bank.name
  name     = "admin"
  password = random_password.cloud_sql_admin_password.result
  project  = google_sql_database_instance.cymbal_bank.project
}

# Database accounts-db
resource "google_sql_database" "accounts" {
  depends_on = [google_sql_user.cloud_sql_admin_user]

  instance = google_sql_database_instance.cymbal_bank.name
  name     = "accounts-db"
  project  = google_sql_database_instance.cymbal_bank.project
}

# Database ledger-db
resource "google_sql_database" "ledger" {
  depends_on = [google_sql_user.cloud_sql_admin_user]

  instance = google_sql_database_instance.cymbal_bank.name
  name     = "ledger-db"
  project  = google_sql_database_instance.cymbal_bank.project
}
