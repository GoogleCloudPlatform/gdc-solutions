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
  admin_dc1_000_prod_tfvars_file = "admin_dc1_000_prod.auto.tfvars"
  admin_dc1_000_prod_cp_vip      = google_compute_global_address.admin_dc1_000_prod_cp.address
  admin_dc1_000_prod_md5         = md5(jsonencode(local.admin_dc1_000_prod_cp_vip))

  admin_dc2_000_prod_tfvars_file = "admin_dc2_000_prod.auto.tfvars"
  admin_dc2_000_prod_cp_vip      = google_compute_global_address.admin_dc2_000_prod_cp.address
  admin_dc2_000_prod_md5         = md5(jsonencode(local.admin_dc2_000_prod_cp_vip))

  shared_config_dir = "${path.module}/../../../shared_config/clusters/admin"
}

resource "null_resource" "write_admin_dc1_000_prod" {
  triggers = {
    md5 = local.admin_dc1_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'admin_dc1_000_prod' changes to '${local.admin_dc1_000_prod_tfvars_file}'" && \
sed -i 's/^\(admin_dc1_000_prod_cp_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.admin_dc1_000_prod_cp_vip)}/' ${local.admin_dc1_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = local.shared_config_dir
  }
}

resource "null_resource" "write_admin_dc2_000_prod" {
  triggers = {
    md5 = local.admin_dc2_000_prod_md5
  }

  provisioner "local-exec" {
    command     = <<EOT
echo "Writing 'admin_dc2_000_prod' changes to '${local.admin_dc2_000_prod_tfvars_file}'" && \
sed -i 's/^\(admin_dc2_000_prod_cp_vip[[:blank:]]*=\).*$/\1 ${jsonencode(local.admin_dc2_000_prod_cp_vip)}/' ${local.admin_dc2_000_prod_tfvars_file}
    EOT
    interpreter = ["bash", "-c"]
    working_dir = local.shared_config_dir
  }
}
