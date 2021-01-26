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
DOC_TYPE="$(basename $(dirname ${SCRIPT_PATH}))"

TMUX_SESSION_NAME="${DOC_TYPE}-cleanup"
tmux new-session -d -s "${TMUX_SESSION_NAME}" ${SCRIPT_PATH}/manual_rollback.sh

echo -e "\nAttach to the tmux session using the following command:\ntmux attach -t ${TMUX_SESSION_NAME}\n"
