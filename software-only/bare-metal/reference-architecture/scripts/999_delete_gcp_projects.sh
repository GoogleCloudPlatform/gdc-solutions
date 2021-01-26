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

echo_title "Delete application project '${ABMRA_APP_PROJECT_ID}'"
print_and_execute "gcloud compute shared-vpc associated-projects remove ${ABMRA_APP_PROJECT_ID} --host-project ${ABMRA_NETWORK_PROJECT_ID}"
print_and_execute "gcloud projects delete --quiet ${ABMRA_APP_PROJECT_ID}"

echo_title "Delete platform project '${ABMRA_PLATFORM_PROJECT_ID}'"
print_and_execute "gcloud compute shared-vpc associated-projects remove ${ABMRA_PLATFORM_PROJECT_ID} --host-project ${ABMRA_NETWORK_PROJECT_ID}"
print_and_execute "gcloud projects delete --quiet ${ABMRA_PLATFORM_PROJECT_ID}"

echo_title "Delete network project '${ABMRA_NETWORK_PROJECT_ID}'"
print_and_execute "gcloud compute shared-vpc disable ${ABMRA_NETWORK_PROJECT_ID}"
print_and_execute "gcloud projects delete --quiet ${ABMRA_NETWORK_PROJECT_ID}"

check_local_error
total_runtime
exit ${local_error}
