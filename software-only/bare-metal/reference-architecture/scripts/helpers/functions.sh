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

function check_local_error {
    printf "\n"
    if [ ${local_error} -ne 0 ]; then
        echo_error "There was an error while executing the script, review the output."
    fi
    
    if [ ! -z ${ABMRA_LOG_FILE} ]; then
        echo_bold "A log file is available at '${ABMRA_LOG_FILE}'"
    fi
    printf "\n"
}

function total_runtime {
    if [ ! -z ${start_timestamp} ]; then
        end_timestamp=`date +%s`
        runtime=$((end_timestamp-start_timestamp))
        echo_bold "Total runtime: `date -d@${runtime} -u +%H:%M:%S`"
    fi
}
