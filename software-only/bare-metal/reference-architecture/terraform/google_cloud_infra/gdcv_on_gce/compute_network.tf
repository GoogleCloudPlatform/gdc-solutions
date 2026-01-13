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

resource "google_compute_network" "gdcv_prod" {
  depends_on = [google_project_service.compute_googleapis_com_gdcv_on_gce_prod]

  name    = var.google_vpc_network_name_gdcv_on_gce_prod
  project = local.project_id_gdcv_on_gce_prod
}

resource "google_compute_firewall" "gdcv_allow_internal" {
  name          = "${google_compute_network.gdcv_prod.name}-allow-internal"
  network       = google_compute_network.gdcv_prod.name
  project       = local.project_id_gdcv_on_gce_prod
  source_ranges = ["10.128.0.0/9"]

  allow {
    protocol = "icmp"
  }
  allow {
    ports    = ["0-65535"]
    protocol = "tcp"
  }
  allow {
    ports    = ["0-65535"]
    protocol = "udp"
  }
}

resource "google_compute_firewall" "gdcv_allow_ssh_bootstrap" {
  name          = "${google_compute_network.gdcv_prod.name}-allow-ssh-bootstrap"
  network       = google_compute_network.gdcv_prod.name
  project       = local.project_id_gdcv_on_gce_prod
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.gdcv_node_tag_bootstrap]


  allow {
    ports    = ["22"]
    protocol = "tcp"
  }
}
