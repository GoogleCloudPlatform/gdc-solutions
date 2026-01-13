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

#The roles/compute.xpnAdmin IAM policy is required

#user_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
#echo_title "Adding the roles/compute.xpnAdmin IAM policy bindings for ${user_account}"
#print_and_execute "gcloud projects add-iam-policy-binding ${ABMRA_PLATFORM_PROJECT_ID} --member 'user:${user_account}' --role 'roles/compute.xpnAdmin'"

if [ ${ABMRA_USE_SHARED_VPC,,} == "true" ]; then
    echo_title "Enable shared-vpc in '${ABMRA_NETWORK_PROJECT_ID}'"
    print_and_execute "gcloud services enable --project ${ABMRA_NETWORK_PROJECT_ID} compute.googleapis.com"
    print_and_execute "gcloud compute shared-vpc enable ${ABMRA_NETWORK_PROJECT_ID}"

    echo_title "Associate '${ABMRA_PLATFORM_PROJECT_ID}' with '${ABMRA_NETWORK_PROJECT_ID}'"
    print_and_execute "gcloud services enable --project ${ABMRA_PLATFORM_PROJECT_ID} compute.googleapis.com"
    print_and_execute "gcloud compute firewall-rules delete --project ${ABMRA_PLATFORM_PROJECT_ID} --quiet default-allow-icmp default-allow-internal default-allow-rdp default-allow-ssh"
    print_and_execute "gcloud compute networks delete --project ${ABMRA_PLATFORM_PROJECT_ID} --quiet default"
    print_and_execute "gcloud compute shared-vpc associated-projects add ${ABMRA_PLATFORM_PROJECT_ID} --host-project ${ABMRA_NETWORK_PROJECT_ID}"

    echo_title "Associate '${ABMRA_APP_PROJECT_ID}' with '${ABMRA_NETWORK_PROJECT_ID}'"
    print_and_execute "gcloud services enable --project ${ABMRA_APP_PROJECT_ID} --quiet compute.googleapis.com"
    print_and_execute "gcloud compute firewall-rules delete --project ${ABMRA_APP_PROJECT_ID} --quiet default-allow-icmp default-allow-internal default-allow-rdp default-allow-ssh"
    print_and_execute "gcloud compute networks delete --project ${ABMRA_APP_PROJECT_ID} --quiet default"
    print_and_execute "gcloud compute shared-vpc associated-projects add ${ABMRA_APP_PROJECT_ID} --host-project ${ABMRA_NETWORK_PROJECT_ID}"
else
    echo_warning "ABMRA_USE_SHARED_VPC is not set to 'true', skipping Shared VPC creation!"
fi

check_local_error
total_runtime
exit ${local_error}
