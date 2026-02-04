
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

locals {
  backend_directories  = toset([for _, v in local.versions_files : trimprefix(trimsuffix(dirname(v), "/versions.tf"), "../")])
  backend_template     = "${path.module}/templates/terraform/backend.tf.tftpl"
  shared_config_folder = "${path.module}/.."
  terraservice_path    = "${path.module}/../../terraform"
  versions_files       = flatten([for _, v in flatten(fileset("${local.terraservice_path}/", "**/versions.tf")) : v])
}

resource "local_file" "backend_tf" {
  for_each = local.backend_directories
  content = templatefile(
    local.backend_template,
    {
      bucket = local.platform_terraform_bucket_name,
      prefix = "terraform/${each.key}",
    }
  )
  file_permission = "0644"
  filename        = "${local.terraservice_path}/${each.key}/backend.tf"
}

resource "local_file" "initialize_backend_tf" {
  content = templatefile(
    local.backend_template,
    {
      bucket = local.platform_terraform_bucket_name,
      prefix = "terraform/initialize",
    }
  )
  file_permission = "0644"
  filename        = "${path.module}/backend.tf"
}

resource "local_file" "shared_config_build_auto_tfvars" {
  for_each = toset(var.platform_terraform_write_tfvars ? ["write"] : [])

  content = provider::terraform::encode_tfvars(
    {
      build_github_token_secret_name = var.build_github_token_secret_name
      build_location                 = var.build_location
      build_project_id               = var.build_project_id
    }
  )
  file_permission = "0644"
  filename        = "${local.shared_config_folder}/build.auto.tfvars"
}

resource "local_file" "shared_config_platform_auto_tfvars" {
  for_each = toset(var.platform_terraform_write_tfvars ? ["write"] : [])

  content = provider::terraform::encode_tfvars(
    {
      platform_custom_role_unique_suffix = var.platform_custom_role_unique_suffix
      platform_default_location          = var.platform_default_location
      platform_default_project_id        = var.platform_default_project_id
      platform_name                      = var.platform_name
      platform_resource_name_prefix      = var.platform_resource_name_prefix
      platform_terraform_bucket_name     = var.platform_terraform_bucket_name
      platform_terraform_project_id      = var.platform_terraform_project_id
      platform_terraform_write_tfvars    = var.platform_terraform_write_tfvars
    }
  )
  file_permission = "0644"
  filename        = "${local.shared_config_folder}/platform.auto.tfvars"
}
