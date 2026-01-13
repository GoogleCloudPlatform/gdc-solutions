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
  admin_dc1_000_prod_bootstrap_script = templatefile(
    "${path.module}/templates/bootstrap.shtpl",
    {
      bare_metal_version = var.admin_dc1_000_prod_bare_metal_version,
      cluster_name       = var.admin_dc1_000_prod_cluster_name,
      fleet_project_id   = local.project_id_fleet_prod,
    }
  )
  admin_dc1_000_prod_bootstrap_script_file = "${path.module}/scripts/${var.admin_dc1_000_prod_cluster_name}-bootstrap.sh"

  admin_dc1_000_prod_bootstrap_cleanup_script = templatefile(
    "${path.module}/templates/bootstrap_cleanup.shtpl",
    {
      bucket_name  = "${local.project_id_build_prod}-gdcv",
      cluster_name = var.admin_dc1_000_prod_cluster_name,
    }
  )
  admin_dc1_000_prod_bootstrap_cleanup_script_file = "${path.module}/scripts/${var.admin_dc1_000_prod_cluster_name}-bootstrap_cleanup.sh"
}

resource "local_file" "admin_dc1_000_prod_bootstrap" {
  depends_on = [
    local_file.gdcv_baremetal_cloud_ops_key,
    local_file.gdcv_baremetal_connect_agent_key,
    local_file.gdcv_baremetal_fleet_admin_key,
    local_file.gdcv_baremetal_registry_key
  ]

  content  = local.admin_dc1_000_prod_bootstrap_script
  filename = local.admin_dc1_000_prod_bootstrap_script_file
}

resource "local_file" "admin_dc1_000_prod_bootstrap_cleanup" {
  content  = local.admin_dc1_000_prod_bootstrap_cleanup_script
  filename = local.admin_dc1_000_prod_bootstrap_cleanup_script_file
}

resource "null_resource" "admin_dc1_000_prod_bootstrap" {
  depends_on = [
    google_project_service.anthos_googleapis_com_fleet_prod,
    google_project_service.anthosaudit_googleapis_com_fleet_prod,
    google_project_service.cloudresourcemanager_googleapis_com_fleet_prod,
    google_project_service.connectgateway_googleapis_com_fleet_prod,
    google_project_service.gkehub_googleapis_com_fleet_prod,
    google_project_service.gkeonprem_googleapis_com_fleet_prod,
    google_project_service.iam_googleapis_com_fleet_prod,
    local_file.admin_dc1_000_prod_bootstrap,
  ]

  connection {
    host        = var.admin_dc1_000_prod_bootstrap_host
    private_key = data.google_secret_manager_secret_version.gdcv_ssh_private_key.secret_data
    type        = "ssh"
    user        = var.admin_dc1_000_prod_login_user
  }

  provisioner "file" {
    source      = local.gdcv_baremetal_cloud_ops_key_file
    destination = "/home/${var.admin_dc1_000_prod_login_user}/keys/gdcv_baremetal_cloud_ops.json"
  }

  provisioner "file" {
    source      = local.gdcv_baremetal_connect_agent_key_file
    destination = "/home/${var.admin_dc1_000_prod_login_user}/keys/gdcv_baremetal_connect_agent.json"
  }

  provisioner "file" {
    source      = local.gdcv_baremetal_fleet_admin_key_file
    destination = "/home/${var.admin_dc1_000_prod_login_user}/keys/gdcv_baremetal_fleet_admin.json"
  }

  provisioner "file" {
    source      = local.gdcv_baremetal_registry_key_file
    destination = "/home/${var.admin_dc1_000_prod_login_user}/keys/gdcv_baremetal_registry.json"
  }

  provisioner "remote-exec" {
    script = local.admin_dc1_000_prod_bootstrap_script_file
  }
}

resource "null_resource" "admin_dc1_000_prod_bootstrap_cluster_ready" {
  depends_on = [null_resource.admin_dc1_000_prod_bootstrap]

  provisioner "local-exec" {
    command     = <<EOT
while ! gcloud container fleet memberships describe bootstrap-${var.admin_dc1_000_prod_cluster_name} --project ${local.project_id_fleet_prod} &>/dev/null; do
  sleep 5
done
EOT
    interpreter = ["bash", "-c"]
  }
}

resource "google_gkeonprem_bare_metal_admin_cluster" "admin_dc1_001_prod" {
  depends_on = [null_resource.admin_dc1_000_prod_bootstrap_cluster_ready]

  bare_metal_version = var.admin_dc1_000_prod_bare_metal_version
  location           = var.admin_dc1_000_prod_region
  name               = var.admin_dc1_000_prod_cluster_name
  project            = local.project_id_fleet_prod

  control_plane {
    control_plane_node_pool_config {
      node_pool_config {
        labels           = {}
        operating_system = "LINUX"

        dynamic "node_configs" {
          for_each = var.admin_dc1_000_prod_cp_node_ip_list
          content {
            labels  = {}
            node_ip = node_configs.value
          }
        }
      }
    }
  }
  load_balancer {
    port_config {
      control_plane_load_balancer_port = 443
    }
    vip_config {
      control_plane_vip = var.admin_dc1_000_prod_cp_vip
    }
    dynamic "manual_lb_config" {
      for_each = var.admin_dc1_000_prod_use_bundled_lb == false ? [1] : []
      content {
        enabled = true
      }
    }
  }
  network_config {
    island_mode_cidr {
      service_address_cidr_blocks = var.admin_dc1_000_prod_k8s_service_cidr
      pod_address_cidr_blocks     = var.admin_dc1_000_prod_k8s_pod_cidr
    }
  }
  node_access_config {
    login_user = var.admin_dc1_000_prod_login_user
  }
  node_config {
    max_pods_per_node = 250
  }
  security_config {
    authorization {
      dynamic "admin_users" {
        for_each = var.admin_dc1_000_prod_admin_users
        content {
          username = admin_users.value
        }
      }
    }
  }
  storage {
    lvp_share_config {
      lvp_config {
        path          = "/mnt/localpv-share"
        storage_class = "local-shared"
      }
      shared_path_pv_count = 5
    }
    lvp_node_mounts_config {
      path          = "/mnt/localpv-disk"
      storage_class = "local-disks"
    }
  }

  provisioner "local-exec" {
    command     = <<EOT
gcloud container bare-metal admin-clusters unenroll ${self.name} \
--ignore-errors \
--location ${self.location} \
--project ${self.project} && \
gcloud container fleet memberships delete ${self.name} \
--project ${self.project} \
--quiet
EOT
    interpreter = ["bash", "-c"]
    when        = destroy
  }

  lifecycle {
    ignore_changes = [
      annotations["alpha.baremetal.cluster.gke.io/cluster-metrics-webhook"],
      annotations["baremetal.cluster.gke.io/operation"],
      annotations["baremetal.cluster.gke.io/operation-id"],
      annotations["baremetal.cluster.gke.io/start-time"],
      annotations["baremetal.cluster.gke.io/upgrade-from-version"],
      annotations["onprem.cluster.gke.io/admin-cluster-resource-link"],
      annotations["preview.baremetal.cluster.gke.io/incremental-network-preflight-checks"]
    ]
  }
  timeouts {
    create = "45m"
    update = "45m"
  }
}

resource "null_resource" "admin_dc1_000_prod_bootstrap_cleanup" {
  depends_on = [
    google_gkeonprem_bare_metal_admin_cluster.admin_dc1_001_prod,
    local_file.admin_dc1_000_prod_bootstrap_cleanup
  ]

  connection {
    host        = var.admin_dc1_000_prod_bootstrap_host
    private_key = data.google_secret_manager_secret_version.gdcv_ssh_private_key.secret_data
    type        = "ssh"
    user        = var.admin_dc1_000_prod_login_user
  }

  provisioner "remote-exec" {
    script = local.admin_dc1_000_prod_bootstrap_cleanup_script_file
  }
}
