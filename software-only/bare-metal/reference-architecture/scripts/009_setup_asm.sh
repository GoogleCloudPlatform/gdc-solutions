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

BIN_DIR=${ABMRA_WORK_DIR}/bin
ASMCLI_BIN=${BIN_DIR}/asmcli_${ABMRA_ASM_VERSION_MAJOR}.${ABMRA_ASM_VERSION_MINOR}
mkdir -p ${BIN_DIR}

echo_title "Download asmcli"
print_and_execute "curl --location --output ${ASMCLI_BIN} --show-error --silent https://storage.googleapis.com/csm-artifacts/asm/asmcli_${ABMRA_ASM_VERSION_MAJOR}.${ABMRA_ASM_VERSION_MINOR}"
print_and_execute "chmod u+x ${ASMCLI_BIN}"

export KUBECONFIG=$(ls -1 ${ABMRA_BMCTL_WORKSPACE_DIR}/*/*-kubeconfig | tr '\n' ':')
for cluster_name in $(get_cluster_names); do
    load_cluster_config ${cluster_name}

    kubeconfig_file=${ABMRA_BMCTL_WORKSPACE_DIR}/${cluster_name}/${cluster_name}-kubeconfig

    temp_dir=${ABMRA_WORK_DIR}/tmp/${cluster_name}
    mkdir -p ${temp_dir}

    output_dir=${temp_dir}/asmcli
    rm -rf ${output_dir}

    export MAJOR=${ABMRA_ASM_VERSION_MAJOR}
    export MINOR=${ABMRA_ASM_VERSION_MINOR}
    export POINT=${ABMRA_ASM_VERSION_POINT}
    export REV=${ABMRA_ASM_VERSION_REV}
    export CONFIG_VER=${ABMRA_ASM_VERSION_CONFIG}

    unset CLUSTER_NAME
   
    echo_title "Installing Anthos Service Mesh (ASM) v${MAJOR}.${MINOR}.${POINT}-asm.${REV} on ${cluster_name}"
    print_and_execute "${ASMCLI_BIN} install --fleet_id ${ABMRA_PLATFORM_PROJECT_ID} --kubeconfig ${kubeconfig_file} --network_id ${cluster_name}-net --output_dir ${output_dir} --platform multicloud --enable_all --ca mesh_ca"

    echo_bold "Create ingressgateway in '${ABMRA_ASM_INGRESSGATEWAY_NAMESPACE}' namespace"
    print_and_execute "kubectl --context ${cluster_name} create namespace ${ABMRA_ASM_INGRESSGATEWAY_NAMESPACE}"
    print_and_execute "kubectl --context ${cluster_name} label namespace ${ABMRA_ASM_INGRESSGATEWAY_NAMESPACE} istio-injection- istio.io/rev=${ABMRA_ASM_REV_LABEL} --overwrite"
    print_and_execute "kubectl --context ${cluster_name} --namespace ${ABMRA_ASM_INGRESSGATEWAY_NAMESPACE} apply --filename ${output_dir}/samples/gateways/istio-ingressgateway"
done

check_local_error
total_runtime
exit ${local_error}
