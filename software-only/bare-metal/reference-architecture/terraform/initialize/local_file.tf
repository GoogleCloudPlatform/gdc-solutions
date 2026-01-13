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
  backend_templates = flatten([for _, v in flatten(fileset(path.module, "../**/templates/backend.tftpl")) : v])
  backend_dirnames  = [for _, v in local.backend_templates : trimprefix(trimsuffix(dirname(v), "/templates"), "../")]
}

resource "local_file" "backend_tf" {
  count = length(local.backend_templates)

  content = templatefile(
    local.backend_templates[count.index],
    {
      google_storage_bucket_name = google_storage_bucket.build_shared.name
      storage_bucket_folder      = local.backend_dirnames[count.index]
    }
  )
  filename = "../${local.backend_dirnames[count.index]}/backend.tf"
}
