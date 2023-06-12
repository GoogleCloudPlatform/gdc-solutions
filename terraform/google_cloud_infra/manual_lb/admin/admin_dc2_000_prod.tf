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

data "google_compute_subnetwork" "admin_dc2_000_prod" {
  name    = local.gdcv_network_name
  project = local.project_id_gdcv_on_gce_prod
  region  = var.admin_dc2_000_prod_region
}

data "google_compute_instance" "admin_dc2_000_prod_cp" {
  count = var.admin_dc2_000_prod_cp_nodes

  name    = "${var.admin_dc2_000_prod_cluster_name}-cp-${format("%03d", count.index)}"
  project = local.project_id_gdcv_on_gce_prod
  zone    = var.admin_dc2_000_prod_zone
}

resource "google_compute_network_endpoint_group" "admin_dc2_000_prod_cp" {
  default_port          = "6444"
  name                  = "admin-dc2-000-prod-cp-neg"
  network               = data.google_compute_network.gdcv_prod.id
  network_endpoint_type = "GCE_VM_IP_PORT"
  project               = local.project_id_gdcv_on_gce_prod
  zone                  = var.admin_dc2_000_prod_zone
}

resource "google_compute_network_endpoint" "admin_dc2_000_prod_cp" {
  count = var.admin_dc2_000_prod_cp_nodes

  instance               = data.google_compute_instance.admin_dc2_000_prod_cp[count.index].name
  ip_address             = data.google_compute_instance.admin_dc2_000_prod_cp[count.index].network_interface[0].network_ip
  network_endpoint_group = google_compute_network_endpoint_group.admin_dc2_000_prod_cp.name
  port                   = 6444
  project                = local.project_id_gdcv_on_gce_prod
  zone                   = var.admin_dc2_000_prod_zone
}

resource "google_compute_backend_service" "admin_dc2_000_prod_cp" {
  health_checks = [google_compute_health_check.gdcv_cp_healthcheck.id]
  name          = "admin-dc2-000-prod-cp-backend"
  project       = local.project_id_gdcv_on_gce_prod
  protocol      = "TCP"

  backend {
    balancing_mode  = "CONNECTION"
    group           = google_compute_network_endpoint_group.admin_dc2_000_prod_cp.id
    max_connections = 1024
  }
}

resource "google_compute_target_tcp_proxy" "admin_dc2_000_prod_cp" {
  backend_service = google_compute_backend_service.admin_dc2_000_prod_cp.id
  name            = "admin-dc2-000-prod-cp-proxy"
  project         = local.project_id_gdcv_on_gce_prod
}

resource "google_compute_global_address" "admin_dc2_000_prod_cp" {
  name    = "admin-dc2-000-prod-cp-ip"
  project = local.project_id_gdcv_on_gce_prod
}

resource "google_compute_global_forwarding_rule" "admin_dc2_000_prod_cp" {
  ip_address  = google_compute_global_address.admin_dc2_000_prod_cp.id
  ip_protocol = "TCP"
  name        = "admin-dc2-000-prod-cp-forwarding-rule"
  port_range  = "443"
  project     = local.project_id_gdcv_on_gce_prod
  target      = google_compute_target_tcp_proxy.admin_dc2_000_prod_cp.id
}
