resource "google_gkeonprem_bare_metal_cluster" "user_dc2b_000_prod" {
  #TODO: admin_cluster_membership needs to be improved
  admin_cluster_membership = "projects/${local.project_id_fleet_prod}/locations/${var.admin_dc2_000_prod_region}/memberships/${var.admin_dc2_000_prod_cluster_name}"
  bare_metal_version       = var.user_dc2b_000_prod_bare_metal_version
  location                 = var.user_dc2b_000_prod_region
  name                     = var.user_dc2b_000_prod_cluster_name
  project                  = local.project_id_fleet_prod

  control_plane {
    control_plane_node_pool_config {
      node_pool_config {
        labels           = {}
        operating_system = "LINUX"

        dynamic "node_configs" {
          for_each = var.user_dc2b_000_prod_cp_node_ip_list
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
      control_plane_vip = var.user_dc2b_000_prod_cp_vip
      ingress_vip       = var.user_dc2b_000_prod_ingress_vip
    }
    dynamic "manual_lb_config" {
      for_each = var.user_dc2b_000_prod_use_bundled_lb == false ? [1] : []
      content {
        enabled = true
      }
    }
    dynamic "metal_lb_config" {
      for_each = var.user_dc2b_000_prod_use_bundled_lb == true ? [1] : []
      content {
        address_pools {
          addresses       = var.user_dc2b_000_prod_lb_addresses
          avoid_buggy_ips = true
          pool            = "default"
        }
      }
    }
  }
  network_config {
    island_mode_cidr {
      pod_address_cidr_blocks     = var.user_dc2b_000_prod_k8s_pod_cidr
      service_address_cidr_blocks = var.user_dc2b_000_prod_k8s_service_cidr
    }
  }
  node_access_config {
    login_user = var.user_dc2b_000_prod_login_user
  }
  security_config {
    authorization {
      dynamic "admin_users" {
        for_each = var.user_dc2b_000_prod_admin_users
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

  lifecycle {
    precondition {
      condition     = length(var.user_dc2b_000_prod_cp_node_ip_list) == var.user_dc2b_000_prod_cp_nodes
      error_message = "Number control plane IPs must match the number of control plane nodes"
    }
    precondition {
      condition     = length(var.user_dc2b_000_prod_worker_node_ip_list) == var.user_dc2b_000_prod_worker_nodes
      error_message = "Number worker IPs must match the number of worker nodes"
    }
  }
  timeouts {
    create = "45m"
    update = "45m"
  }
}

resource "google_gkeonprem_bare_metal_node_pool" "user_dc2b_000_prod_default" {
  bare_metal_cluster = google_gkeonprem_bare_metal_cluster.user_dc2b_000_prod.name
  location           = var.user_dc2b_000_prod_region
  name               = "default"
  project            = local.project_id_fleet_prod

  node_pool_config {
    operating_system = "LINUX"

    dynamic "node_configs" {
      for_each = var.user_dc2b_000_prod_worker_node_ip_list
      content {
        labels  = {}
        node_ip = node_configs.value
      }
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.user_dc2b_000_prod_worker_node_ip_list) == var.user_dc2b_000_prod_worker_nodes
      error_message = "Number worker IPs must match the number of worker nodes"
    }
  }
}
