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
  kubeconfig_dir = "../../kubeconfig"
}


resource "null_resource" "admin_dc1_000_prod_kubeconfig" {
  triggers = {
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command     = <<EOT
KUBECONFIG=${var.admin_dc1_000_prod_cluster_name} gcloud container fleet memberships get-credentials ${var.admin_dc1_000_prod_cluster_name} \
--project ${local.project_id_fleet_prod}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/${local.kubeconfig_dir}"
  }
}

resource "null_resource" "admin_dc2_000_prod_kubeconfig" {
  triggers = {
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command     = <<EOT
KUBECONFIG=${var.admin_dc2_000_prod_cluster_name} gcloud container fleet memberships get-credentials ${var.admin_dc2_000_prod_cluster_name} \
--project ${local.project_id_fleet_prod}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/${local.kubeconfig_dir}"
  }
}

resource "null_resource" "user_dc1a_000_prod_kubeconfig" {
  triggers = {
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command     = <<EOT
KUBECONFIG=${var.user_dc1a_000_prod_cluster_name} gcloud container fleet memberships get-credentials ${var.user_dc1a_000_prod_cluster_name} \
--project ${local.project_id_fleet_prod}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/${local.kubeconfig_dir}"
  }
}

resource "null_resource" "user_dc1b_000_prod_kubeconfig" {
  triggers = {
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command     = <<EOT
KUBECONFIG=${var.user_dc1b_000_prod_cluster_name} gcloud container fleet memberships get-credentials ${var.user_dc1b_000_prod_cluster_name} \
--project ${local.project_id_fleet_prod}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/${local.kubeconfig_dir}"
  }
}

resource "null_resource" "user_dc2a_000_prod_kubeconfig" {
  triggers = {
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command     = <<EOT
KUBECONFIG=${var.user_dc2a_000_prod_cluster_name} gcloud container fleet memberships get-credentials ${var.user_dc2a_000_prod_cluster_name} \
--project ${local.project_id_fleet_prod}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/${local.kubeconfig_dir}"
  }
}

resource "null_resource" "user_dc2b_000_prod_kubeconfig" {
  triggers = {
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command     = <<EOT
KUBECONFIG=${var.user_dc2b_000_prod_cluster_name} gcloud container fleet memberships get-credentials ${var.user_dc2b_000_prod_cluster_name} \
--project ${local.project_id_fleet_prod}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/${local.kubeconfig_dir}"
  }
}
