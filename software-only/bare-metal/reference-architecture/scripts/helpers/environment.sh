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

export ENV_FILE=${ABMRA_ENVIRONMENT_FILE}

function generate_envsubst_files_from_directory {
    template_directory=${1}
    output_directory=${2}
    max_depth=${3:-1}

    mkdir -p ${output_directory}

    for filename in $(find ${template_directory} -maxdepth ${max_depth} -type f ! -path "*.ignore" -exec basename {} \; | sort); do
        envsubst <${template_directory}/${filename} >${output_directory}/${filename}
    done
}

function generate_envsubst_file {
    template_file=${1}
    output_file=${2}

    mkdir -p $(dirname ${output_file})

    envsubst <${template_file} >${output_file}
}

function set_environment_variable_error_if_existing {
    variable=${1%%=*}
    value=${1#*=}

    if [[ ${value} == "" ]]; then
        echo_warning "Value for ${variable} is empty, not setting"
        return
    fi

    if grep -q "export ${variable}=" ${ENV_FILE}; then
        echo "[ERROR] Environment variable '${variable}' already exists in ${ENV_FILE}"
    else
        echo -e "export ${variable}=${value}" >>${ENV_FILE}
    fi

    source ${ENV_FILE}
}

function set_environment_variable_skip_if_existing {
    variable=${1%%=*}
    value=${1#*=}

    if [[ ${value} == "" ]]; then
        echo_warning "Value for ${variable} is empty, not setting"
        return
    fi

    if ! grep -q "export ${variable}=" ${ENV_FILE}; then
        echo -e "export ${variable}=${value}" >>${ENV_FILE}
    fi

    source ${ENV_FILE}
}

function set_environment_variable_skip_if_existing_blank_allowed {
    variable=${1%%=*}
    value=${1#*=}

    if ! grep -q "export ${variable}=" ${ENV_FILE}; then
        echo -e "export ${variable}=${value}" >>${ENV_FILE}
    fi

    source ${ENV_FILE}
}

function set_or_overwrite_environment_variable {
    variable=${1%%=*}
    value=${1#*=}

    if [[ ${value} == "" ]]; then
        echo_warning "Value for ${variable} is empty, not setting"
        return
    fi

    if grep -q "export ${variable}=" ${ENV_FILE}; then
        sed -i "s|export ${variable}=.*|export ${variable}=${value}|" ${ENV_FILE}
    else
        echo -e "export ${variable}=${value}" >>${ENV_FILE}
    fi

    source ${ENV_FILE}
}