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

user_dc1a_000_prod_admin_users         = ["infra-admin@cymbalbank.com"]
user_dc1a_000_prod_bare_metal_version  = "1.29.1200-gke.98"
user_dc1a_000_prod_cluster_name        = "metal-user-dc1a-000-prod"
user_dc1a_000_prod_cp_node_ip_list     = ["10.185.1.10", "10.185.1.11", "10.185.1.12"]
user_dc1a_000_prod_cp_nodes            = 3
user_dc1a_000_prod_cp_vip              = "###.###.###.###"
user_dc1a_000_prod_ingress_vip         = "###.###.###.###"
user_dc1a_000_prod_k8s_pod_cidr        = ["192.168.0.0/16"]
user_dc1a_000_prod_k8s_service_cidr    = ["10.96.0.0/12"]
user_dc1a_000_prod_lb_addresses        = ["10.185.1.3-10.185.1.10"]
user_dc1a_000_prod_lb_node_ip_list     = []
user_dc1a_000_prod_lb_nodes            = 0
user_dc1a_000_prod_login_user          = "gdcv"
user_dc1a_000_prod_region              = "us-west1"
user_dc1a_000_prod_use_bundled_lb      = false
user_dc1a_000_prod_worker_node_ip_list = ["10.185.1.20", "10.185.1.21", "10.185.1.22"]
user_dc1a_000_prod_worker_nodes        = 3
user_dc1a_000_prod_zone                = "us-west1-a"
