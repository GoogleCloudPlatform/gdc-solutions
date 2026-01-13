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

ABMRA_LOG_FILE_PREFIX=extras-
source ${ABMRA_WORK_DIR}/scripts/helpers/include.sh

HELM_VERSION=3.9.4
BIN_DIR=${ABMRA_WORK_DIR}/bin

export HELM_INSTALL_DIR=${BIN_DIR}
export BINARY_NAME=helm-${HELM_VERSION}
export PATH=${HELM_INSTALL_DIR}:${PATH}

HELM_BINARY=${HELM_INSTALL_DIR}/${BINARY_NAME}

curl -fsSL -o ${BIN_DIR}/get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 ${BIN_DIR}/get_helm.sh
${BIN_DIR}/get_helm.sh --no-sudo --version v${HELM_VERSION}

${HELM_BINARY} repo add nvidia https://nvidia.github.io/gpu-operator

NVIDIA_GPU_OPERATOR_NAMESPACE=${NVIDIA_GPU_OPERATOR_NAMESPACE:-nvidia-gpu-operator}
export KUBECONFIG=$(ls -1 ${BMCTL_WORKSPACE_DIR}/*/*-kubeconfig | tr '\n' ':')
for cluster_name in $(get_cluster_names); do
    load_cluster_config ${cluster_name}

    echo_title "Deploy NVIDIA GPU operator on ${cluster_name}"
    print_and_execute "${HELM_BINARY} install --create-namespace --kube-context ${cluster_name} --namespace ${NVIDIA_GPU_OPERATOR_NAMESPACE} --wait nvidia-gpu-operator nvidia/gpu-operator --set operator.defaultRuntime='containerd'"
done
