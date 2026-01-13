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
source ${SCRIPT_PATH}/../../vars.sh

ADMIN_WORKSTATION_HOSTNAME="bare-metal-admin-1"
ADMIN_WORKSTATION_ZONE="us-central1-a"

gcloud compute ssh ${ADMIN_WORKSTATION_HOSTNAME} \
--command="bash -i -c ~/gdc-solutions/scripts/auto/${DOC_TYPE}/scripts/tmux_cleanup.sh" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
-- -t

gcloud compute ssh ${ADMIN_WORKSTATION_HOSTNAME} \
--command="bash -i -c 'tmux attach -t ${DOC_TYPE}-cleanup'" \
--project=${ABMRA_PLATFORM_PROJECT_ID} \
--zone=${ADMIN_WORKSTATION_ZONE} \
-- -t
