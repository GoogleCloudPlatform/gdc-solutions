locals {
  admin_dc1_000_prod_tfvars_file     = "admin_dc1_000_prod.auto.tfvars"
  admin_dc1_000_prod_cp_node_ip_list = google_compute_instance.admin_dc1_000_prod_cp[*].network_interface.0.network_ip
  admin_dc1_000_prod_md5             = md5(jsonencode(local.admin_dc1_000_prod_cp_node_ip_list))

  admin_dc2_000_prod_tfvars_file     = "admin_dc2_000_prod.auto.tfvars"
  admin_dc2_000_prod_cp_node_ip_list = google_compute_instance.admin_dc2_000_prod_cp[*].network_interface.0.network_ip
  admin_dc2_000_prod_md5             = md5(jsonencode(local.admin_dc2_000_prod_cp_node_ip_list))

  user_dc1a_000_prod_tfvars_file         = "user_dc1a_000_prod.auto.tfvars"
  user_dc1a_000_prod_cp_node_ip_list     = google_compute_instance.user_dc1a_000_prod_cp[*].network_interface.0.network_ip
  user_dc1a_000_prod_worker_node_ip_list = google_compute_instance.user_dc1a_000_prod_worker[*].network_interface.0.network_ip
  user_dc1a_000_prod_md5                 = md5(jsonencode(concat(local.user_dc1a_000_prod_cp_node_ip_list, local.user_dc1a_000_prod_worker_node_ip_list)))

  user_dc1b_000_prod_tfvars_file         = "user_dc1b_000_prod.auto.tfvars"
  user_dc1b_000_prod_cp_node_ip_list     = google_compute_instance.user_dc1b_000_prod_cp[*].network_interface.0.network_ip
  user_dc1b_000_prod_worker_node_ip_list = google_compute_instance.user_dc1b_000_prod_worker[*].network_interface.0.network_ip
  user_dc1b_000_prod_md5                 = md5(jsonencode(concat(local.user_dc1b_000_prod_cp_node_ip_list, local.user_dc1b_000_prod_worker_node_ip_list)))

  user_dc2a_000_prod_tfvars_file         = "user_dc2a_000_prod.auto.tfvars"
  user_dc2a_000_prod_cp_node_ip_list     = google_compute_instance.user_dc2a_000_prod_cp[*].network_interface.0.network_ip
  user_dc2a_000_prod_worker_node_ip_list = google_compute_instance.user_dc2a_000_prod_worker[*].network_interface.0.network_ip
  user_dc2a_000_prod_md5                 = md5(jsonencode(concat(local.user_dc2a_000_prod_cp_node_ip_list, local.user_dc2a_000_prod_worker_node_ip_list)))

  user_dc2b_000_prod_tfvars_file         = "user_dc2b_000_prod.auto.tfvars"
  user_dc2b_000_prod_cp_node_ip_list     = google_compute_instance.user_dc2b_000_prod_cp[*].network_interface.0.network_ip
  user_dc2b_000_prod_worker_node_ip_list = google_compute_instance.user_dc2b_000_prod_worker[*].network_interface.0.network_ip
  user_dc2b_000_prod_md5                 = md5(jsonencode(concat(local.user_dc2b_000_prod_cp_node_ip_list, local.user_dc2b_000_prod_worker_node_ip_list)))
}

resource "null_resource" "write_admin_dc1_000_prod" {
  triggers = {
    md5 = local.admin_dc1_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'admin_dc1_000_prod' changes to '${local.admin_dc1_000_prod_tfvars_file}'" && \
sed -i 's/^\(admin_dc1_000_prod_cp_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.admin_dc1_000_prod_cp_node_ip_list)}/' ${local.admin_dc1_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/../../shared_config/clusters/admin"
  }
}

resource "null_resource" "write_admin_dc2_000_prod" {
  triggers = {
    md5 = local.admin_dc2_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'admin_dc2_000_prod' changes to '${local.admin_dc2_000_prod_tfvars_file}'" && \
sed -i 's/^\(admin_dc2_000_prod_cp_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.admin_dc2_000_prod_cp_node_ip_list)}/' ${local.admin_dc2_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/../../shared_config/clusters/admin"
  }
}

resource "null_resource" "write_user_dc1a_000_prod" {
  triggers = {
    md5 = local.user_dc1a_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'user_dc1a_000_prod' changes to '${local.user_dc1a_000_prod_tfvars_file}'" && \
sed -i 's/^\(user_dc1a_000_prod_cp_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc1a_000_prod_cp_node_ip_list)}/' ${local.user_dc1a_000_prod_tfvars_file} && \
sed -i 's/^\(user_dc1a_000_prod_worker_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc1a_000_prod_worker_node_ip_list)}/' ${local.user_dc1a_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/../../shared_config/clusters/user"
  }
}

resource "null_resource" "write_user_dc1b_000_prod" {
  triggers = {
    md5 = local.user_dc1b_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'user_dc1b_000_prod' changes to '${local.user_dc1b_000_prod_tfvars_file}'" && \
sed -i 's/^\(user_dc1b_000_prod_cp_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc1b_000_prod_cp_node_ip_list)}/' ${local.user_dc1b_000_prod_tfvars_file} && \
sed -i 's/^\(user_dc1b_000_prod_worker_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc1b_000_prod_worker_node_ip_list)}/' ${local.user_dc1b_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/../../shared_config/clusters/user"
  }
}

resource "null_resource" "write_user_dc2a_000_prod" {
  triggers = {
    md5 = local.user_dc2a_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'user_dc2a_000_prod' changes to '${local.user_dc2a_000_prod_tfvars_file}'" && \
sed -i 's/^\(user_dc2a_000_prod_cp_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc2a_000_prod_cp_node_ip_list)}/' ${local.user_dc2a_000_prod_tfvars_file} && \
sed -i 's/^\(user_dc2a_000_prod_worker_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc2a_000_prod_worker_node_ip_list)}/' ${local.user_dc2a_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/../../shared_config/clusters/user"
  }
}

resource "null_resource" "write_user_dc2b_000_prod" {
  triggers = {
    md5 = local.user_dc2b_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'user_dc2b_000_prod' changes to '${local.user_dc2b_000_prod_tfvars_file}'" && \
sed -i 's/^\(user_dc2b_000_prod_cp_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc2b_000_prod_cp_node_ip_list)}/' ${local.user_dc2b_000_prod_tfvars_file} && \
sed -i 's/^\(user_dc2b_000_prod_worker_node_ip_list[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc2b_000_prod_worker_node_ip_list)}/' ${local.user_dc2b_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/../../shared_config/clusters/user"
  }
}
