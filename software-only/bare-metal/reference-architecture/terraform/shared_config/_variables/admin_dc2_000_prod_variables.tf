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

variable "admin_dc2_000_prod_admin_users" {
  type        = list(string)
  description = "Cluster-admin users for the admin-dc2-000-prod cluster"
}

variable "admin_dc2_000_prod_bare_metal_version" {
  type        = string
  description = "GDC-V bare metal version for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_bootstrap_host" {
  type        = string
  description = "Hostname or IP address for the admin_dc2_000_prod bootstrap host"
}

variable "admin_dc2_000_prod_cluster_name" {
  type        = string
  description = "Cluster name for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_cp_node_ip_list" {
  type        = list(string)
  description = "Control plane node IP list for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_cp_nodes" {
  type        = number
  description = "Number of control plane nodes for the admin_dc2_000_prod cluster"
  validation {
    condition     = var.admin_dc2_000_prod_cp_nodes % 2 != 0
    error_message = "Number of control plane nodes must be an odd numbers."
  }
}

variable "admin_dc2_000_prod_cp_vip" {
  type        = string
  description = "Control plane VIP for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_k8s_pod_cidr" {
  type        = list(string)
  description = "Pod CIDR for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_k8s_service_cidr" {
  type        = list(string)
  description = "Service CIDR for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_login_user" {
  type        = string
  description = "User name used to access node machines for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_region" {
  type        = string
  description = "Cluster region for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_use_bundled_lb" {
  type        = bool
  description = "Use bundled LB(Metal LB) for the admin_dc2_000_prod cluster"
}

variable "admin_dc2_000_prod_zone" {
  type        = string
  description = "Cluster zone for the admin_dc2_000_prod cluster"
}
