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

ABMRA_LOG_FILE_PREFIX=gcp-
source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

echo_title "Enable compute.googleapis.com API"
print_and_execute "gcloud services enable compute.googleapis.com --project ${ABMRA_PLATFORM_PROJECT_ID}"

echo_title "Creating administrative instance"
load_global_config

network_args="--network ${ADMIN_WORKSTATION_NETWORK}"
if [ ${ABMRA_USE_SHARED_VPC,,} == "true" ]; then
    network_args="--subnet projects/${ABMRA_NETWORK_PROJECT_ID}/regions/${ADMIN_WORKSTATION_REGION}/subnetworks/${ADMIN_WORKSTATION_SUBNET}"
fi

print_and_execute "gcloud compute instances create bare-metal-admin-1 \
--boot-disk-size 512G \
--boot-disk-type pd-ssd \
--can-ip-forward \
--image-family=ubuntu-2004-lts \
--image-project=ubuntu-os-cloud \
--machine-type=${ADMIN_WORKSTATION_MACHINE_TYPE} \
--metadata-from-file startup-script=${ABMRA_WORK_DIR}/scripts/gcp/instance_startup_script.sh \
--no-scopes \
--no-service-account \
--project ${ABMRA_PLATFORM_PROJECT_ID} \
--quiet \
--zone=${ADMIN_WORKSTATION_ZONE} \
${network_args}"

echo_title "Waiting for the administrative instance to be available"
while ! gcloud compute ssh bare-metal-admin-1 --command=date --project=${ABMRA_PLATFORM_PROJECT_ID} --zone=${ADMIN_WORKSTATION_ZONE} &>/dev/null; do
    sleep 1
done

check_local_error
total_runtime
exit ${local_error}
