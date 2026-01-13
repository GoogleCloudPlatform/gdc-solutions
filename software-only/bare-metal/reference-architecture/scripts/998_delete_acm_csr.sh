#!/usr/bin/env bash

# Copyright 2021 Google LLC
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

source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

if [ -d ${ABMRA_ACM_REPO_DIR} ]; then
    echo_title "Deleting the local ACM repository directory"
    print_and_execute "rm -rf ${ABMRA_ACM_REPO_DIR}"
fi

echo_title "Deleting ACM CSR"
print_and_execute "gcloud source repos delete acm --project ${ABMRA_PLATFORM_PROJECT_ID} --quiet"

ABM_ACM_GSA_NAME="anthos-config-mgmt"
ABM_ACM_GSA="${ABM_ACM_GSA_NAME}@${ABMRA_PLATFORM_PROJECT_ID}.iam.gserviceaccount.com"

echo_title "Delete ${ABM_ACM_GSA_NAME} GSA"
print_and_execute "gcloud iam service-accounts delete ${ABM_ACM_GSA} --quiet"

check_local_error
total_runtime
exit ${local_error}
