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

ABMRA_LOG_FILE_PREFIX=gcp-
source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

TEMP_DIR=${ABMRA_WORK_DIR}/tmp/vxlan
mkdir -p ${TEMP_DIR}

VXLAN_CRONTAB_FILE=${TEMP_DIR}/vxlan.crontab
VXLAN_CRONJOB_FILE=/etc/cron.d/vxlan-setup

echo_title "Remove the crontab entry"
crontab -l | grep -v "vxlan-setup ${VXLAN_CRONJOB_FILE}" > ${VXLAN_CRONTAB_FILE}
sudo crontab ${VXLAN_CRONTAB_FILE}

echo_title "Remove the cronjob file"
sudo rm -f ${VXLAN_CRONJOB_FILE}

echo_title "Remove the interfaces"
sudo ip link del vxlan185 type vxlan id 185 dev ens4 dstport 0
sudo ip link del vxlan195 type vxlan id 195 dev ens4 dstport 0

echo_title "Remove the temporary directory"
rm -rf ${TEMP_DIR}

check_local_error
total_runtime
exit ${local_error}
