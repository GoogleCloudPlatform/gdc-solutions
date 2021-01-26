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

source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

if [ -d ${ABMRA_CONF_DIR} ]; then
    echo_error "Directory '${ABMRA_CONF_DIR}' already exists, exiting..."
    exit 1
fi

if [ ! -d ${ABMRA_BASE_CONF_DIR}/${ABMRA_BASE_CONF} ]; then
    echo_error "Directory '${ABMRA_BASE_CONF_DIR}/${ABMRA_BASE_CONF}' does not exist, exiting..."
    exit 1
fi

if [ ! -z ${ABMRA_ADDITIONAL_CONF} ] && [ ! -d ${ABMRA_BASE_CONF_DIR}/${ABMRA_BASE_CONF}/${ABMRA_ADDITIONAL_CONF} ]; then
    echo_error "Directory '${ABMRA_BASE_CONF_DIR}/${ABMRA_BASE_CONF}/${ABMRA_ADDITIONAL_CONF}' does not exist, exiting..."
    exit 1
fi

echo_title "Generating ${ABMRA_CONF_DIR} conf directory"
mkdir -p ${ABMRA_CONF_DIR}

echo_bold "ABMRA_BASE_CONF=${ABMRA_BASE_CONF}"
find ${ABMRA_BASE_CONF_DIR}/${ABMRA_BASE_CONF} -maxdepth 1 -type f -exec cp -p {} ${ABMRA_CONF_DIR}/ \;

if [ ! -z ${ABMRA_ADDITIONAL_CONF} ]; then
    echo_bold "ABMRA_ADDITIONAL_CONF=${ABMRA_ADDITIONAL_CONF}"
    cp -pr ${ABMRA_BASE_CONF_DIR}/${ABMRA_BASE_CONF}/${ABMRA_ADDITIONAL_CONF} ${ABMRA_CONF_DIR}/
fi

check_local_error
total_runtime
exit ${local_error}
