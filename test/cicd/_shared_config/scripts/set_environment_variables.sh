#!/bin/bash

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

BASH_SOURCE_GDCS_CICD_MY_PATH="$(
  cd "$(dirname "${BASH_SOURCE}")" >/dev/null 2>&1
  pwd -P
)"

GDCS_REPO_DIR=$(realpath "${BASH_SOURCE_GDCS_CICD_MY_PATH}/../../../..")
GDCS_CICD_DIR="${GDCS_REPO_DIR}/test/cicd"

if [[ ! -v GDCS_CICD_SHARED_CONFIG_PATHS ]]; then
  if [ "$#" -eq 0 ]; then
    GDCS_CICD_SHARED_CONFIG_PATHS=("${GDCS_CICD_DIR}/_shared_config")
  else
    GDCS_CICD_SHARED_CONFIG_PATHS=("${@}")
  fi
fi

if ! grep -q "platform_default_project_id" "${GDCS_CICD_DIR}/_shared_config/platform.auto.tfvars"; then
  if [[ ! -v TF_VAR_platform_default_project_id ]]; then
    echo "Terraform variable 'platform_default_project_id' must be set!"
    if [[ ${BASH_SOURCE[0]} = "$0" ]]; then
      exit 1
    else
      return 1
    fi
  fi
fi

display_variables=0
if [[ -v DEBUG ]] || [[ -v DISPLAY_VARIABLES ]]; then
  display_variables=1
fi

for SHARED_CONFIG_PATH in "${GDCS_CICD_SHARED_CONFIG_PATHS[@]}"; do
  [[ -v DEBUG ]] && echo "Loading shared configuration(${SHARED_CONFIG_PATH})"
  [[ ${display_variables} == 1 ]] && echo "-------------------------------------------------------------------------" 
  terraform -chdir="${SHARED_CONFIG_PATH}" init >/dev/null
  terraform -chdir="${SHARED_CONFIG_PATH}" apply -auto-approve -input=false >/dev/null
  [[ ${display_variables} == 1 ]] && terraform -chdir="${SHARED_CONFIG_PATH}" output
  [[ ${display_variables} == 1 ]] && echo -e "-------------------------------------------------------------------------\n"
  set -o allexport
  eval "$(terraform -chdir="${SHARED_CONFIG_PATH}" output | sed -r 's/(\".*\")|\s*/\1/g')"
  set +o allexport
done
