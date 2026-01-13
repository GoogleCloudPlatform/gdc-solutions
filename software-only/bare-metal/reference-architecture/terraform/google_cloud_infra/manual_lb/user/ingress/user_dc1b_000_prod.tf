locals {
  user_dc1b_000_prod_ingress_port = { for key, port in data.kubernetes_service.user_dc1b_000_prod_istio_ingress.spec[0].port[*] : port.port => port }

  user_dc1b_000_prod_lb_node_type  = var.user_dc1b_000_prod_lb_nodes > 0 ? "lb" : "cp"
  user_dc1b_000_prod_lb_node_count = var.user_dc1b_000_prod_lb_nodes > 0 ? var.user_dc1b_000_prod_lb_nodes : var.user_dc1b_000_prod_cp_nodes

}

data "google_compute_instance" "user_dc1b_000_prod_lb" {
  count = local.user_dc1b_000_prod_lb_node_count

  name    = "${var.user_dc1b_000_prod_cluster_name}-${local.user_dc1b_000_prod_lb_node_type}-${format("%03d", count.index)}"
  project = local.project_id_gdcv_on_gce_prod
  zone    = var.user_dc1b_000_prod_zone
}

data "google_compute_global_address" "user_dc1b_000_prod_ingress" {
  name    = "user-dc1b-000-prod-ingress-ip"
  project = local.project_id_gdcv_on_gce_prod
}

provider "kubernetes" {
  alias       = "user_dc1b_000_prod"
  config_path = "${path.module}/${local.kubeconfig_dir}/${var.user_dc1b_000_prod_cluster_name}"
}

data "kubernetes_service" "user_dc1b_000_prod_istio_ingress" {
  provider = kubernetes.user_dc1b_000_prod

  metadata {
    name      = "istio-ingress"
    namespace = "gke-system"
  }
}

resource "google_compute_firewall" "gdcv_user_dc1b_000_prod_allow_ingress" {
  name          = "gdcv-user-dc1b-000-prod-allow-ingress"
  network       = data.google_compute_network.gdcv_prod.id
  project       = local.project_id_gdcv_on_gce_prod
  source_ranges = data.google_netblock_ip_ranges.health_checkers.cidr_blocks
  target_tags   = [var.gdcv_node_tag_lb]

  allow {
    ports = [
      local.user_dc1b_000_prod_ingress_port.80.node_port,
      local.user_dc1b_000_prod_ingress_port.443.node_port,
      local.user_dc1b_000_prod_ingress_port.15012.node_port,
      local.user_dc1b_000_prod_ingress_port.15021.node_port
    ]
    protocol = "tcp"
  }
}

resource "google_compute_health_check" "user_dc1b_000_prod_ingress_healthcheck" {
  name    = "user-dc1b-000-prod-ingress-healthcheck"
  project = local.project_id_gdcv_on_gce_prod

  http_health_check {
    port         = local.user_dc1b_000_prod_ingress_port.15021.node_port
    request_path = "/healthz/ready"
  }
}

###################################################################################################
# INGRESS-80
###################################################################################################

resource "google_compute_network_endpoint_group" "user_dc1b_000_prod_ingress_80" {
  name                  = "user-dc1b-000-prod-ingress-80-neg"
  network               = data.google_compute_network.gdcv_prod.id
  network_endpoint_type = "GCE_VM_IP_PORT"
  project               = local.project_id_gdcv_on_gce_prod
  zone                  = var.user_dc1b_000_prod_zone
}

resource "google_compute_network_endpoint" "user_dc1b_000_prod_ingress_80" {
  count = local.user_dc1b_000_prod_lb_node_count

  instance               = data.google_compute_instance.user_dc1b_000_prod_lb[count.index].name
  ip_address             = data.google_compute_instance.user_dc1b_000_prod_lb[count.index].network_interface[0].network_ip
  network_endpoint_group = google_compute_network_endpoint_group.user_dc1b_000_prod_ingress_80.name
  port                   = local.user_dc1b_000_prod_ingress_port.80.node_port
  project                = local.project_id_gdcv_on_gce_prod
  zone                   = var.user_dc1b_000_prod_zone
}

resource "google_compute_backend_service" "user_dc1b_000_prod_ingress_80" {
  health_checks = [google_compute_health_check.user_dc1b_000_prod_ingress_healthcheck.id]
  name          = "user-dc1b-000-prod-ingress-80-backend"
  project       = local.project_id_gdcv_on_gce_prod
  protocol      = "HTTP"

  backend {
    balancing_mode = "RATE"
    group          = google_compute_network_endpoint_group.user_dc1b_000_prod_ingress_80.id
    max_rate       = 1024
  }
}

resource "google_compute_url_map" "user_dc1b_000_prod_ingress_80" {
  default_service = google_compute_backend_service.user_dc1b_000_prod_ingress_80.id
  name            = "user-dc1b-000-prod-ingress-80-urlmap"
  project         = local.project_id_gdcv_on_gce_prod
}

resource "google_compute_target_http_proxy" "user_dc1b_000_prod_ingress_80" {
  name    = "user-dc1b-000-prod-ingress-80-proxy"
  project = local.project_id_gdcv_on_gce_prod
  url_map = google_compute_url_map.user_dc1b_000_prod_ingress_80.id
}

resource "google_compute_global_forwarding_rule" "user_dc1b_000_prod_ingress_80" {
  ip_address  = data.google_compute_global_address.user_dc1b_000_prod_ingress.id
  ip_protocol = "TCP"
  name        = "user-dc1b-000-prod-ingress-80-forwarding-rule"
  port_range  = "80"
  project     = local.project_id_gdcv_on_gce_prod
  target      = google_compute_target_http_proxy.user_dc1b_000_prod_ingress_80.id
}


###################################################################################################
# INGRESS-443
###################################################################################################

resource "google_compute_network_endpoint_group" "user_dc1b_000_prod_ingress_443" {
  name                  = "user-dc1b-000-prod-ingress-443-neg"
  network               = data.google_compute_network.gdcv_prod.id
  network_endpoint_type = "GCE_VM_IP_PORT"
  project               = local.project_id_gdcv_on_gce_prod
  zone                  = var.user_dc1b_000_prod_zone
}

resource "google_compute_network_endpoint" "user_dc1b_000_prod_ingress_443" {
  count = local.user_dc1b_000_prod_lb_node_count

  instance               = data.google_compute_instance.user_dc1b_000_prod_lb[count.index].name
  ip_address             = data.google_compute_instance.user_dc1b_000_prod_lb[count.index].network_interface[0].network_ip
  network_endpoint_group = google_compute_network_endpoint_group.user_dc1b_000_prod_ingress_443.name
  port                   = local.user_dc1b_000_prod_ingress_port.443.node_port
  project                = local.project_id_gdcv_on_gce_prod
  zone                   = var.user_dc1b_000_prod_zone
}

resource "google_compute_backend_service" "user_dc1b_000_prod_ingress_443" {
  health_checks = [google_compute_health_check.user_dc1b_000_prod_ingress_healthcheck.id]
  name          = "user-dc1b-000-prod-ingress-443-backend"
  project       = local.project_id_gdcv_on_gce_prod
  protocol      = "TCP"

  backend {
    balancing_mode  = "CONNECTION"
    group           = google_compute_network_endpoint_group.user_dc1b_000_prod_ingress_443.id
    max_connections = 1024
  }
}

resource "google_compute_target_tcp_proxy" "user_dc1b_000_prod_ingress_443" {
  backend_service = google_compute_backend_service.user_dc1b_000_prod_ingress_443.id
  name            = "user-dc1b-000-prod-ingress-443-proxy"
  project         = local.project_id_gdcv_on_gce_prod
}

resource "google_compute_global_forwarding_rule" "user_dc1b_000_prod_cp" {
  ip_address  = data.google_compute_global_address.user_dc1b_000_prod_ingress.id
  ip_protocol = "TCP"
  name        = "user-dc1b-000-prod-ingress-443-forwarding-rule"
  port_range  = "443"
  project     = local.project_id_gdcv_on_gce_prod
  target      = google_compute_target_tcp_proxy.user_dc1b_000_prod_ingress_443.id
}

###################################################################################################
# INGRESS-15012
###################################################################################################

resource "google_compute_network_endpoint_group" "user_dc1b_000_prod_ingress_15012" {
  name                  = "user-dc1b-000-prod-ingress-15012-neg"
  network               = data.google_compute_network.gdcv_prod.id
  network_endpoint_type = "GCE_VM_IP_PORT"
  project               = local.project_id_gdcv_on_gce_prod
  zone                  = var.user_dc1b_000_prod_zone
}

resource "google_compute_network_endpoint" "user_dc1b_000_prod_ingress_15012" {
  count = local.user_dc1b_000_prod_lb_node_count

  instance               = data.google_compute_instance.user_dc1b_000_prod_lb[count.index].name
  ip_address             = data.google_compute_instance.user_dc1b_000_prod_lb[count.index].network_interface[0].network_ip
  network_endpoint_group = google_compute_network_endpoint_group.user_dc1b_000_prod_ingress_15012.name
  port                   = local.user_dc1b_000_prod_ingress_port.15012.node_port
  project                = local.project_id_gdcv_on_gce_prod
  zone                   = var.user_dc1b_000_prod_zone
}

resource "google_compute_backend_service" "user_dc1b_000_prod_ingress_15012" {
  health_checks = [google_compute_health_check.user_dc1b_000_prod_ingress_healthcheck.id]
  name          = "user-dc1b-000-prod-ingress-15012-backend"
  project       = local.project_id_gdcv_on_gce_prod
  protocol      = "TCP"

  backend {
    balancing_mode  = "CONNECTION"
    group           = google_compute_network_endpoint_group.user_dc1b_000_prod_ingress_15012.id
    max_connections = 1024
  }
}

resource "google_compute_target_tcp_proxy" "user_dc1b_000_prod_ingress_15012" {
  backend_service = google_compute_backend_service.user_dc1b_000_prod_ingress_15012.id
  name            = "user-dc1b-000-prod-ingress-15012-proxy"
  project         = local.project_id_gdcv_on_gce_prod
}

resource "google_compute_global_forwarding_rule" "user_dc1b_000_prod_ingress_15012" {
  ip_address  = data.google_compute_global_address.user_dc1b_000_prod_ingress.id
  ip_protocol = "TCP"
  name        = "user-dc1b-000-prod-ingress-15012-forwarding-rule"
  port_range  = "15012"
  project     = local.project_id_gdcv_on_gce_prod
  target      = google_compute_target_tcp_proxy.user_dc1b_000_prod_ingress_15012.id
}
