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

SCRIPT_PATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
export ABMRA_WORK_DIR=$(dirname ${SCRIPT_PATH%/*})

if [[ ! -z "${ABMRA_BMCTL_VERSION}" ]]; then
    source ${ABMRA_WORK_DIR}/scripts/helpers/display.sh
    echo_warning "ABMRA_BMCTL_VERSION is set, a previous configuration file could change default values"
    echo -e "--> Press ENTER to continue..."
    read -p ''
fi

source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

env | grep -e '^ABMRA_' | sort

total_runtime
