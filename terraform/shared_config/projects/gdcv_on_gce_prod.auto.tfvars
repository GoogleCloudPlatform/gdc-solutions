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

gdcv_machine_type_bootstrap              = "n2-standard-8"
gdcv_node_tag_bootstrap                  = "gdcv-bootstrap-node"
gdcv_node_tag_cp                         = "gdcv-cp-node"
gdcv_node_tag_lb                         = "gdcv-lb-node"
gdcv_node_tag_worker                     = "gdcv-worker-node"
google_project_id_gdcv_on_gce_prod       = "<gdcv-prod>"
google_vpc_network_name_gdcv_on_gce_prod = "gdcv"
