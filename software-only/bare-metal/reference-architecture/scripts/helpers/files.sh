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

function add_or_replace_env_var_in_file {
    file=${1}
    key=${2}
    value=${3}

    if grep -q "export ${key}=" ${file}; then
        sed -i "/export ${key}=/c\export ${key}=${value}" ${file}
    else
        echo "export ${key}=${value} >> ${file}"
    fi
}

function remove_env_var_in_file {
    file=${1}
    key=${2}

    if grep -q "export ${key}=" ${file}; then
        sed -i "/export ${key}=/d" ${file}
    else
        echo "WARNING: '${key}' not found in ${file}"
    fi
}
