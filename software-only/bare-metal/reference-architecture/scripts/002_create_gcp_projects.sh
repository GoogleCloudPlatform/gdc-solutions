#!/usr/bin/env bash

# Copyright 2020 Google LLC
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

if [ ${ABMRA_USE_SHARED_VPC,,} == "true" ]; then
    echo_title "Create network project '${ABMRA_NETWORK_PROJECT_ID}'"
    print_and_execute "gcloud projects create ${ABMRA_NETWORK_PROJECT_ID} --organization=${ABMRA_ORGANIZATION_ID} --folder=${ABMRA_FOLDER_ID}"
    print_and_execute "gcloud beta billing projects link ${ABMRA_NETWORK_PROJECT_ID} --billing-account ${ABMRA_BILLING_ACCOUNT_ID}"

    echo_title "Create platform project '${ABMRA_PLATFORM_PROJECT_ID}'"
    print_and_execute "gcloud projects create ${ABMRA_PLATFORM_PROJECT_ID} --set-as-default --organization=${ABMRA_ORGANIZATION_ID} --folder=${ABMRA_FOLDER_ID}"
    print_and_execute "gcloud beta billing projects link ${ABMRA_PLATFORM_PROJECT_ID} --billing-account ${ABMRA_BILLING_ACCOUNT_ID}"

    echo_title "Create application project '${ABMRA_APP_PROJECT_ID}'"
    print_and_execute "gcloud projects create ${ABMRA_APP_PROJECT_ID} --organization=${ABMRA_ORGANIZATION_ID} --folder=${ABMRA_FOLDER_ID}"
    print_and_execute "gcloud beta billing projects link ${ABMRA_APP_PROJECT_ID} --billing-account ${ABMRA_BILLING_ACCOUNT_ID}"
else
    echo_warning "ABMRA_USE_SHARED_VPC is not set to 'true', skipping project creation!"
fi

check_local_error
total_runtime
exit ${local_error}
