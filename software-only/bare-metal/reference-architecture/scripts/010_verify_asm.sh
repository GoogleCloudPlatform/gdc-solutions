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

export KUBECONFIG=$(ls -1 ${ABMRA_BMCTL_WORKSPACE_DIR}/*/*-kubeconfig | tr '\n' ':')
for cluster_name in $(get_cluster_names); do
    
    echo_title "Verify ASM status on ${cluster_name}"
    print_and_execute "kubectl --context=${cluster_name} --namespace=istio-system get deployments"
    print_and_execute "kubectl --context=${cluster_name} --namespace=istio-system get pods"
    print_and_execute "kubectl --context=${cluster_name} --namespace=${ABMRA_ASM_INGRESSGATEWAY_NAMESPACE} get service/istio-ingressgateway"
done

check_local_error
total_runtime
exit ${local_error}
