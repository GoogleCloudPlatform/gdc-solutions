#!/usr/bin/env bash

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

source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

echo_title "Download bmctl-${ABMRA_BMCTL_VERSION} binary"

mkdir -p ${ABMRA_WORK_DIR}/bin
print_and_execute "gcloud storage cp gs://anthos-baremetal-release/bmctl/${ABMRA_BMCTL_VERSION}/linux-amd64/bmctl ${ABMRA_WORK_DIR}/bin/bmctl"
print_and_execute "chmod a+x ${ABMRA_WORK_DIR}/bin/bmctl"
print_and_execute "sudo cp -p ${ABMRA_WORK_DIR}/bin/bmctl /usr/local/bin/"

if [ ! -f /usr/local/bin/bmctl ]; then
    echo_error "Failed to download or install 'bmctl', exiting!"
    exit -1
fi

echo_title "Create cluster configurations"
cd ${ABMRA_WORK_DIR}
for cluster_name in $(get_cluster_names); do
    echo_title "Creating configuration for ${cluster_name}"
    load_cluster_config ${cluster_name}

    control_plane_node_pool_addresses=""
    for cp_address in $(get_control_plane_node_addresses); do
        control_plane_node_pool_addresses+="      - address: ${cp_address}\n"
    done
    export CONTROL_PLANE_NODE_POOL=${control_plane_node_pool_addresses}

    worker_node_pool_addresses=""
    for worker_address in $(get_worker_node_addresses); do
        worker_node_pool_addresses+="  - address: ${worker_address}\n"
    done
    export WORKER_NODE_POOL=${worker_node_pool_addresses}

    echo_bold "${cluster_name}"
    cluster_yaml=${ABMRA_BMCTL_WORKSPACE_DIR}/${cluster_name}/${cluster_name}.yaml
    if [ ! -f "${cluster_yaml}" ]; then
        print_and_execute "bmctl create config --cluster ${cluster_name} --create-service-accounts --enable-apis --project-id ${ABMRA_PLATFORM_PROJECT_ID}"
        if [ $? -eq 0 ]; then
            echo_bold "Applying kustomizations"

            cp -p ${cluster_yaml} ${cluster_yaml}.orig
            sed -i '0,/^---$/d' ${cluster_yaml}

            envsubst <  ${ABMRA_BASE_KUSTOMIZE_DIR}/${KUSTOMIZATION_TYPE}/kustomization.yaml > ${ABMRA_BMCTL_WORKSPACE_DIR}/${cluster_name}/kustomization.yaml
            envsubst <  ${ABMRA_BASE_KUSTOMIZE_DIR}/${KUSTOMIZATION_TYPE}/patch.yaml | sed 's/\\n/\n/g' > ${ABMRA_BMCTL_WORKSPACE_DIR}/${cluster_name}/patch.yaml

            kubectl kustomize bmctl-workspace/${cluster_name} > ${cluster_yaml}.tmp
            mv ${cluster_yaml}.tmp ${cluster_yaml}
            
            cat ${ABMRA_BASE_KUSTOMIZE_DIR}/bmctl-config.yaml | envsubst > ${ABMRA_BMCTL_WORKSPACE_DIR}/${cluster_name}/bmctl-config.yaml
            cat ${ABMRA_WORK_DIR}/bmctl-workspace/${cluster_name}/bmctl-config.yaml ${cluster_yaml} > ${cluster_yaml}.tmp
            mv ${cluster_yaml}.tmp ${cluster_yaml}

            echo_bold "Checking configuration"
            print_and_execute "bmctl --workspace-dir ${ABMRA_BMCTL_WORKSPACE_DIR} check config --cluster ${cluster_name}"
            echo
        else
            echo_error "There was an error generating the configuration for cluster '${cluster_name}'"
        fi
    else
        echo_error "Configuration for cluster '${cluster_name}' already exists at ${cluster_yaml}."
        echo_error "Delete the existing configuration file to generate a new configuration file"
    fi

    unset CONTROL_PLANE_NODE_POOL
    unset WORKER_NODE_POOL
done

mkdir -p ${ABMRA_WORK_DIR}/keys
sudo cp ${DEPLOYMENT_USER_SSH_KEY} ${ABMRA_WORK_DIR}/keys/id_rsa
sudo chown ${USER}:${USER} ${ABMRA_WORK_DIR}/keys/id_rsa

check_local_error
total_runtime
exit ${local_error}
