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
  shared_config_dir = "${path.module}/../../../shared_config/clusters/user/"

  user_dc1a_000_prod_tfvars_file = "user_dc1a_000_prod.auto.tfvars"
  user_dc1a_000_prod_cp_vip      = google_compute_global_address.user_dc1a_000_prod_cp.address
  user_dc1a_000_prod_ingress_vip = google_compute_global_address.user_dc1a_000_prod_ingress.address
  user_dc1a_000_prod_md5         = md5(jsonencode("${local.user_dc1a_000_prod_cp_vip},${local.user_dc1a_000_prod_ingress_vip}"))

  user_dc1b_000_prod_tfvars_file = "user_dc1b_000_prod.auto.tfvars"
  user_dc1b_000_prod_cp_vip      = google_compute_global_address.user_dc1b_000_prod_cp.address
  user_dc1b_000_prod_ingress_vip = google_compute_global_address.user_dc1b_000_prod_ingress.address
  user_dc1b_000_prod_md5         = md5(jsonencode("${local.user_dc1b_000_prod_cp_vip},${local.user_dc1b_000_prod_ingress_vip}"))

  user_dc2a_000_prod_tfvars_file = "user_dc2a_000_prod.auto.tfvars"
  user_dc2a_000_prod_cp_vip      = google_compute_global_address.user_dc2a_000_prod_cp.address
  user_dc2a_000_prod_ingress_vip = google_compute_global_address.user_dc2a_000_prod_ingress.address
  user_dc2a_000_prod_md5         = md5(jsonencode("${local.user_dc2a_000_prod_cp_vip},${local.user_dc2a_000_prod_ingress_vip}"))

  user_dc2b_000_prod_tfvars_file = "user_dc2b_000_prod.auto.tfvars"
  user_dc2b_000_prod_cp_vip      = google_compute_global_address.user_dc2b_000_prod_cp.address
  user_dc2b_000_prod_ingress_vip = google_compute_global_address.user_dc2b_000_prod_ingress.address
  user_dc2b_000_prod_md5         = md5(jsonencode("${local.user_dc2b_000_prod_cp_vip},${local.user_dc2b_000_prod_ingress_vip}"))
}

resource "null_resource" "write_user_dc1a_000_prod" {
  triggers = {
    md5 = local.user_dc1a_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'user_dc1a_000_prod' changes to '${local.user_dc1a_000_prod_tfvars_file}'" && \
sed -i 's/^\(user_dc1a_000_prod_cp_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc1a_000_prod_cp_vip)}/' ${local.user_dc1a_000_prod_tfvars_file} && \
sed -i 's/^\(user_dc1a_000_prod_ingress_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc1a_000_prod_ingress_vip)}/' ${local.user_dc1a_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = local.shared_config_dir
  }
}

resource "null_resource" "write_user_dc1b_000_prod" {
  triggers = {
    md5 = local.user_dc1b_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'user_dc1b_000_prod' changes to '${local.user_dc1b_000_prod_tfvars_file}'" && \
sed -i 's/^\(user_dc1b_000_prod_cp_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc1b_000_prod_cp_vip)}/' ${local.user_dc1b_000_prod_tfvars_file} && \
sed -i 's/^\(user_dc1b_000_prod_ingress_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc1b_000_prod_ingress_vip)}/' ${local.user_dc1b_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = local.shared_config_dir
  }
}

resource "null_resource" "write_user_dc2a_000_prod" {
  triggers = {
    md5 = local.user_dc2a_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'user_dc2a_000_prod' changes to '${local.user_dc2a_000_prod_tfvars_file}'" && \
sed -i 's/^\(user_dc2a_000_prod_cp_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc2a_000_prod_cp_vip)}/' ${local.user_dc2a_000_prod_tfvars_file} && \
sed -i 's/^\(user_dc2a_000_prod_ingress_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc2a_000_prod_ingress_vip)}/' ${local.user_dc2a_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = local.shared_config_dir
  }
}

resource "null_resource" "write_user_dc2b_000_prod" {
  triggers = {
    md5 = local.user_dc2b_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'user_dc2b_000_prod' changes to '${local.user_dc2b_000_prod_tfvars_file}'" && \
sed -i 's/^\(user_dc2b_000_prod_cp_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc2b_000_prod_cp_vip)}/' ${local.user_dc2b_000_prod_tfvars_file} && \
sed -i 's/^\(user_dc2b_000_prod_ingress_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.user_dc2b_000_prod_ingress_vip)}/' ${local.user_dc2b_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = local.shared_config_dir
  }
}
