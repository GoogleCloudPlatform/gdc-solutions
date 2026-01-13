#!/usr/bin/env bash

# Copyright 2022 Google LLC
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

SCRIPT_PATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
DOC_TYPE="$(basename ${SCRIPT_PATH})"

source ${SCRIPT_PATH}/../../helpers/display.sh

rm ${SCRIPT_PATH}/../../vars.sh

export ABMRA_BASE_CONF=hybrid-manual-lb
export ABMRA_ADDITIONAL_CONF=gce

unset_variables=("ABMRA_BMCTL_VERSION" "ABMRA_CLOUD_SDK_VERSION" "ABMRA_ASM_VERSION_MAJOR" "ABMRA_ASM_VERSION_MINOR" "ABMRA_ASM_VERSION_POINT" "ABMRA_ASM_VERSION_REV" "ABMRA_ASM_VERSION_CONFIG" "ABMRA_ASM_REV_LABEL")
for unset_variable in ${unset_variables[@]}; do
    unset ${unset_variable}
done

${SCRIPT_PATH}/../../helpers/set_variables.sh
source ${SCRIPT_PATH}/../../vars.sh

if [ ${ABMRA_CREATE_PROJECTS,,} == "true" ]; then
    ${ABMRA_WORK_DIR}/scripts/002_create_gcp_projects.sh
fi

if [ ${ABMRA_USE_SHARED_VPC,,} == "true" ]; then
    ${ABMRA_WORK_DIR}/scripts/003_create_shared_vpc.sh
fi

rm -rf ${ABMRA_CONF_DIR}
${ABMRA_WORK_DIR}/scripts/000_generate_conf_files.sh

ADMIN_WORKSTATION_HOSTNAME="bare-metal-admin-1"
ADMIN_WORKSTATION_ZONE="us-central1-a"
${ABMRA_WORK_DIR}/scripts/gcp/001_create_admin_instance.sh

ABMRA_REPO_BRANCH="add-usecases"
gcloud compute ssh \
--command="git clone --branch ${ABMRA_REPO_BRANCH} https://github.com/GoogleCloudPlatform/gdc-solutions.git" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
${ADMIN_WORKSTATION_HOSTNAME}

TEMP_DIR=${ABMRA_WORK_DIR}/tmp
mkdir -p ${TEMP_DIR}
cp -p ${ABMRA_WORK_DIR}/scripts/vars.sh ${TEMP_DIR}/
remove_variables=("ABMRA_ACM_REPO_DIR" "ABMRA_BASE_CONF_DIR" "ABMRA_BASE_DIR" "ABMRA_BASE_KUSTOMIZE_DIR" "ABMRA_BMCTL_VERSION" "ABMRA_BMCTL_WORKSPACE_DIR" "ABMRA_CONF_DIR" "ABMRA_WORK_DIR")
for remove_variable in ${remove_variables[@]}; do
    sed -i "/export ${remove_variable}=/d" ${TEMP_DIR}/vars.sh
done

gcloud compute scp \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
${TEMP_DIR}/vars.sh ${ADMIN_WORKSTATION_HOSTNAME}:~/gdc-solutions/scripts/

rm -rf ${TEMP_DIR}/vars.sh

gcloud compute ssh ${ADMIN_WORKSTATION_HOSTNAME} \
--command="source ~/gdc-solutions/scripts/vars.sh && cd ~/gdc-solutions && ./scripts/helpers/set_variables.sh" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
-- -t

gcloud compute ssh ${ADMIN_WORKSTATION_HOSTNAME} \
--command="bash -i -c ~/gdc-solutions/scripts/000_generate_conf_files.sh" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
-- -t

gcloud compute ssh ${ADMIN_WORKSTATION_HOSTNAME} \
--command="bash -i -c ~/gdc-solutions/scripts/001_prepare_admin_host.sh " \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
-- -t

echo_title "Login on the Admin Host"
gcloud compute ssh ${ADMIN_WORKSTATION_HOSTNAME} \
--command="bash -i gcloud auth login --activate --no-launch-browser --quiet --update-adc" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
-- -t

gcloud compute ssh ${ADMIN_WORKSTATION_HOSTNAME} \
--command="bash -i -c ~/gdc-solutions/scripts/auto/${DOC_TYPE}/scripts/tmux_admin_host.sh" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
-- -t

gcloud compute ssh ${ADMIN_WORKSTATION_HOSTNAME} \
--command="bash -i -c 'tmux attach -t ${DOC_TYPE}-admin'" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
-- -t
