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

###################################################################################################
# CONTROL PLANE
###################################################################################################
data "google_compute_instance" "user_dc2a_000_prod_cp" {
  count = var.user_dc2a_000_prod_cp_nodes

  name    = "${var.user_dc2a_000_prod_cluster_name}-cp-${format("%03d", count.index)}"
  project = local.project_id_gdcv_on_gce_prod
  zone    = var.user_dc2a_000_prod_zone
}

resource "google_compute_network_endpoint_group" "user_dc2a_000_prod_cp" {
  default_port          = "6444"
  name                  = "user-dc2a-000-prod-cp-neg"
  network               = data.google_compute_network.gdcv_prod.id
  network_endpoint_type = "GCE_VM_IP_PORT"
  project               = local.project_id_gdcv_on_gce_prod
  zone                  = var.user_dc2a_000_prod_zone
}

resource "google_compute_network_endpoint" "user_dc2a_000_prod_cp" {
  count = var.user_dc2a_000_prod_cp_nodes

  instance               = data.google_compute_instance.user_dc2a_000_prod_cp[count.index].name
  ip_address             = data.google_compute_instance.user_dc2a_000_prod_cp[count.index].network_interface[0].network_ip
  network_endpoint_group = google_compute_network_endpoint_group.user_dc2a_000_prod_cp.name
  port                   = 6444
  project                = local.project_id_gdcv_on_gce_prod
  zone                   = var.user_dc2a_000_prod_zone
}

resource "google_compute_backend_service" "user_dc2a_000_prod_cp" {
  health_checks = [data.google_compute_health_check.gdcv_cp_healthcheck.id]
  name          = "user-dc2a-000-prod-cp-backend"
  project       = local.project_id_gdcv_on_gce_prod
  protocol      = "TCP"

  backend {
    balancing_mode  = "CONNECTION"
    group           = google_compute_network_endpoint_group.user_dc2a_000_prod_cp.id
    max_connections = 1024
  }
}

resource "google_compute_target_tcp_proxy" "user_dc2a_000_prod_cp" {
  backend_service = google_compute_backend_service.user_dc2a_000_prod_cp.id
  name            = "user-dc2a-000-prod-cp-proxy"
  project         = local.project_id_gdcv_on_gce_prod
}

resource "google_compute_global_address" "user_dc2a_000_prod_cp" {
  name    = "user-dc2a-000-prod-cp-ip"
  project = local.project_id_gdcv_on_gce_prod
}

resource "google_compute_global_forwarding_rule" "user_dc2a_000_prod_cp" {
  ip_address  = google_compute_global_address.user_dc2a_000_prod_cp.id
  ip_protocol = "TCP"
  name        = "user-dc2a-000-prod-cp-forwarding-rule"
  project     = local.project_id_gdcv_on_gce_prod
  port_range  = "443"
  target      = google_compute_target_tcp_proxy.user_dc2a_000_prod_cp.id
}

###################################################################################################
# INGRESS
###################################################################################################

resource "google_compute_global_address" "user_dc2a_000_prod_ingress" {
  name    = "user-dc2a-000-prod-ingress-ip"
  project = local.project_id_gdcv_on_gce_prod
}
