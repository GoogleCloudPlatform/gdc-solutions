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

data "google_compute_network" "net_hub" {
  name    = var.google_vpc_network_name_net_hub_prod
  project = data.google_project.net_hub.project_id
}

resource "google_compute_network" "net_hub" {
  depends_on = [google_project_service.compute_googleapis_com_net_hub_prod]

  name    = var.google_vpc_network_name_net_hub_prod
  project = data.google_project.net_hub.project_id
}
