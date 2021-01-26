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
  admin_dc2_000_prod_bootstrap_host = google_compute_instance.admin_dc2_000_prod_bootstrap.network_interface.0.access_config.0.nat_ip
  admin_dc2_000_prod_bootstrap_md5  = md5(local.admin_dc2_000_prod_bootstrap_host)

  admin_dc2_000_prod_startup_script_bootstrap = templatefile(
    "${path.module}/templates/instance_startup_script_bootstrap.shtpl",
    {
      login_user                     = var.admin_dc2_000_prod_login_user,
      secret_project_id              = local.project_id_build_prod,
      ssh_private_key_secret_id      = data.google_secret_manager_secret.gdcv_ssh_private_key.secret_id,
      ssh_private_key_secret_version = data.google_secret_manager_secret_version.gdcv_ssh_private_key.version,
      ssh_public_key_secret_id       = data.google_secret_manager_secret.gdcv_ssh_public_key.secret_id,
      ssh_public_key_secret_version  = data.google_secret_manager_secret_version.gdcv_ssh_public_key.version
    }
  )

  admin_dc2_000_prod_tfvars_file = "admin_dc2_000_prod.auto.tfvars"
}

# Compute instance service account
resource "google_service_account" "admin_dc2_000_prod_sa_bootstrap" {
  account_id   = "${var.admin_dc2_000_prod_cluster_name}-bs"
  display_name = "${var.admin_dc2_000_prod_cluster_name} bootstrap service account"
  project      = local.project_id_gdcv_on_gce_prod
}

# Fleet project permissions
resource "google_project_iam_member" "admin_dc2_000_prod_sa_bootstrap_gkehub_viewer" {
  member  = google_service_account.admin_dc2_000_prod_sa_bootstrap.member
  project = local.project_id_fleet_prod
  role    = "roles/gkehub.viewer"
}

resource "google_project_iam_member" "admin_dc2_000_prod_sa_bootstrap_serviceusage_service_usage_viewer" {
  member  = google_service_account.admin_dc2_000_prod_sa_bootstrap.member
  project = local.project_id_fleet_prod
  role    = "roles/serviceusage.serviceUsageViewer"
}

# GDC-V on GCE project permissions
resource "google_project_iam_member" "admin_dc2_000_prod_sa_bootstrap_logging_logwriter" {
  member  = google_service_account.admin_dc2_000_prod_sa_bootstrap.member
  project = local.project_id_gdcv_on_gce_prod
  role    = "roles/logging.logWriter"
}

# Secrets permissions
resource "google_secret_manager_secret_iam_member" "gdcv_ssh_private_key_admin_dc2_000_prod_sa_bootstrap" {
  member    = google_service_account.admin_dc2_000_prod_sa_bootstrap.member
  project   = data.google_secret_manager_secret.gdcv_ssh_private_key.project
  role      = "roles/secretmanager.secretAccessor"
  secret_id = data.google_secret_manager_secret.gdcv_ssh_private_key.secret_id
}

resource "google_secret_manager_secret_iam_member" "gdcv_ssh_public_key_admin_dc2_000_prod_sa_bootstrap" {
  member    = google_service_account.admin_dc2_000_prod_sa_bootstrap.member
  project   = data.google_secret_manager_secret.gdcv_ssh_public_key.project
  role      = "roles/secretmanager.secretAccessor"
  secret_id = data.google_secret_manager_secret.gdcv_ssh_public_key.secret_id
}

# Cloud Storage permissions
resource "google_storage_bucket_iam_member" "admin_dc2_000_prod_gdcv_prod" {
  bucket = data.google_storage_bucket.gdcv_prod.name
  member = google_service_account.admin_dc2_000_prod_sa_bootstrap.member
  role   = "roles/storage.legacyBucketWriter"
}

# Compute instance
resource "google_compute_instance" "admin_dc2_000_prod_bootstrap" {
  machine_type            = var.gdcv_machine_type_bootstrap
  metadata_startup_script = local.admin_dc2_000_prod_startup_script_bootstrap
  name                    = "${var.admin_dc2_000_prod_cluster_name}-bootstrap"
  project                 = local.project_id_gdcv_on_gce_prod
  tags                    = [var.gdcv_node_tag_bootstrap]
  zone                    = var.admin_dc2_000_prod_zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 256
    }
  }
  network_interface {
    network = data.google_compute_network.gdcv_prod.id
    access_config {
    }
  }
  service_account {
    email  = google_service_account.admin_dc2_000_prod_sa_bootstrap.email
    scopes = ["cloud-platform"]
  }
}

resource "null_resource" "write_admin_dc2_000_prod_bootstrap" {
  triggers = {
    md5 = local.admin_dc2_000_prod_bootstrap_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'admin_dc2_000_prod' changes to '${local.admin_dc2_000_prod_tfvars_file}'" && \
sed -i 's/^\(admin_dc2_000_prod_bootstrap_host[[:blank:]]*=\).*$/\1 "${local.admin_dc2_000_prod_bootstrap_host}"/' ${local.admin_dc2_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/../../../shared_config/clusters/admin"
  }
}
