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

variable "user_dc2a_000_prod_admin_users" {
  type        = list(string)
  description = "Cluster-admin users for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_bare_metal_version" {
  type        = string
  description = "GDC-V bare metal version"
}

variable "user_dc2a_000_prod_cluster_name" {
  type        = string
  description = "Cluster name for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_cp_node_ip_list" {
  type        = list(string)
  description = "Control plane node IP list"
}

variable "user_dc2a_000_prod_cp_nodes" {
  type        = number
  description = "Number of control plane nodes for the user-dc2a-000-prod cluster"
  validation {
    condition     = var.user_dc2a_000_prod_cp_nodes % 2 != 0
    error_message = "Number of control plane nodes must be an odd numbers."
  }
}

variable "user_dc2a_000_prod_cp_vip" {
  type        = string
  description = "Control plane VIP for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_ingress_vip" {
  type        = string
  description = "Ingress VIP for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_k8s_pod_cidr" {
  type        = list(string)
  description = "Pod CIDRs for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_k8s_service_cidr" {
  type        = list(string)
  description = "Service CIDRs for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_lb_addresses" {
  type        = list(string)
  description = "LB addresses for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_lb_node_ip_list" {
  type        = list(string)
  description = "Load balancer node IP list for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_lb_nodes" {
  type        = number
  description = "Number of load balancer nodes for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_login_user" {
  type        = string
  description = "User name used to access node machines"
}

variable "user_dc2a_000_prod_region" {
  type        = string
  description = "Region for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_use_bundled_lb" {
  type        = bool
  description = "Use bundled LB(Metal LB) for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_worker_node_ip_list" {
  type        = list(string)
  description = "Worker node IP list"
}

variable "user_dc2a_000_prod_worker_nodes" {
  type        = number
  description = "Number of worker nodes for the user-dc2a-000-prod cluster"
}

variable "user_dc2a_000_prod_zone" {
  type        = string
  description = "Zone for the user-dc2a-000-prod cluster"
}
