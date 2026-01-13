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
  admin_dc1_000_prod_startup_script = templatefile(
    "${path.module}/templates/instance_startup_script.shtpl",
    {
      login_user                    = var.admin_dc1_000_prod_login_user,
      secret_project_id             = local.project_id_build_prod,
      ssh_public_key_secret_id      = data.google_secret_manager_secret.gdcv_ssh_public_key.secret_id,
      ssh_public_key_secret_version = google_secret_manager_secret_version.gdcv_ssh_public_key.version
    }
  )
}

resource "google_service_account" "admin_dc1_000_prod_sa" {
  account_id   = var.admin_dc1_000_prod_cluster_name
  display_name = "${var.admin_dc1_000_prod_cluster_name} service account"
  project      = data.google_project.gdcv_on_gce_prod.project_id
}

resource "google_project_iam_member" "admin_dc1_000_prod_sa_logging_logwriter" {
  member  = google_service_account.admin_dc1_000_prod_sa.member
  project = data.google_project.gdcv_on_gce_prod.project_id
  role    = "roles/logging.logWriter"
}

resource "google_secret_manager_secret_iam_member" "gdcv_ssh_public_key_admin_dc1_000_prod_sa" {
  member    = google_service_account.admin_dc1_000_prod_sa.member
  project   = data.google_secret_manager_secret.gdcv_ssh_public_key.project
  role      = "roles/secretmanager.secretAccessor"
  secret_id = data.google_secret_manager_secret.gdcv_ssh_public_key.secret_id
}

resource "google_compute_instance" "admin_dc1_000_prod_cp" {
  count = var.admin_dc1_000_prod_cp_nodes

  machine_type            = "n2-standard-8"
  metadata_startup_script = local.admin_dc1_000_prod_startup_script
  name                    = "${var.admin_dc1_000_prod_cluster_name}-cp-${format("%03d", count.index)}"
  project                 = data.google_project.gdcv_on_gce_prod.project_id
  tags                    = [var.gdcv_node_tag_cp]
  zone                    = var.admin_dc1_000_prod_zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 256
    }
  }
  network_interface {
    network = google_compute_network.gdcv_prod.id
    access_config {
    }
  }
  service_account {
    email  = google_service_account.admin_dc1_000_prod_sa.email
    scopes = ["cloud-platform"]
  }
}
