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

admin_dc1_000_prod_admin_users        = ["infra-admin@cymbalbank.com"]
admin_dc1_000_prod_bare_metal_version = "1.29.100-gke.251"
admin_dc1_000_prod_bootstrap_host     = "###.###.###.###"
admin_dc1_000_prod_cluster_name       = "metal-admin-dc1-000-prod"
admin_dc1_000_prod_cp_nodes           = 3
admin_dc1_000_prod_cp_node_ip_list    = ["10.185.0.10", "10.185.0.11", "10.185.0.12"]
admin_dc1_000_prod_cp_vip             = "###.###.###.###"
admin_dc1_000_prod_k8s_pod_cidr       = ["192.168.0.0/16"]
admin_dc1_000_prod_k8s_service_cidr   = ["10.96.0.0/12"]
admin_dc1_000_prod_login_user         = "gdcv"
admin_dc1_000_prod_region             = "us-west1"
admin_dc1_000_prod_use_bundled_lb     = false
admin_dc1_000_prod_zone               = "us-west1-a"
