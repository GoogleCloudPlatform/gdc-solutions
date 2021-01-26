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

function get_cluster_conf_files {
    echo $(find ${ABMRA_WORK_DIR}/conf -maxdepth 1 -type f | egrep -v '/global$|\.ignore$' | sort)
}

function get_cluster_names {
    conf_files=$(get_cluster_conf_files)
    echo ${conf_files} |  sed -e "s|${ABMRA_CONF_DIR}/||g"
}

function get_conf_files {
    echo $(find ${ABMRA_WORK_DIR}/conf -maxdepth 1 -type f | sort)
}

function get_control_plane_node_addresses {
    echo $(env | egrep 'CP_[0-9]+_IP=' | awk -F= '{print $2}')
}

function get_number_of_control_plane_nodes {
    echo $(env | egrep 'CP_[0-9]+_IP=' | wc -l)
}

function get_number_of_worker_nodes {
    echo $(env | egrep 'WORKER_[0-9]+_IP=' | wc -l)
}

function get_worker_node_addresses {
    echo $(env | egrep 'WORKER_[0-9]+_IP=' | awk -F= '{print $2}')
}

function load_additional_config {
    cluster_name=${1}

    if [ ! -z "${ABMRA_ADDITIONAL_CONF}" ]; then
        source ${ABMRA_CONF_DIR}/${ABMRA_ADDITIONAL_CONF}/global
        source ${ABMRA_CONF_DIR}/${ABMRA_ADDITIONAL_CONF}/${cluster_name}
    fi
}

function load_cluster_config {
    cluster_name=${1}

    unset_config

    if [[ ! $(get_cluster_names) =~ ${cluster_name} ]]; then
        echo "No configuration found for cluster '$1'"
        exit -1
    fi

    source ${ABMRA_CONF_DIR}/global
    source ${ABMRA_CONF_DIR}/${cluster_name}

    load_additional_config ${cluster_name}

    export CLUSTER_NAME=${cluster_name}
}

function load_global_config {
    unset_config

    source ${ABMRA_CONF_DIR}/global
    if [ ! -z "${ABMRA_ADDITIONAL_CONF}" ]; then
        source ${ABMRA_CONF_DIR}/${ABMRA_ADDITIONAL_CONF}/global
    fi
}

function unset_config {
    conf_variables=`cat $(get_conf_files) | egrep "^export" | awk 'BEGIN{FS="[= ]"}{print $2}' | sort | uniq`
    conf_variables+=" CLUSTER_NAME"    
    for variable in ${conf_variables}; do
        unset ${variable}
    done
}
