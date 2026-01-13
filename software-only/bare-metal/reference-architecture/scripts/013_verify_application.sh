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
    echo_title "Verify application on ${cluster_name}"
    print_and_execute "kubectl --context=${cluster_name} --namespace=${ABMRA_APP_NAMESPACE} get pods"

    print_and_execute "SERVICE_EXTERNAL_IP=$(kubectl --context=${cluster_name} --namespace=gke-system get service/istio-ingress --output jsonpath='{.status.loadBalancer.ingress[0].ip}')"
    if [ -z ${SERVICE_EXTERNAL_IP} ]; then
        print_and_execute "SERVICE_EXTERNAL_IP=$(kubectl --context=${cluster_name} --namespace=gke-system get service/istio-ingress --output jsonpath='{.spec.loadBalancerIP}')"
    fi
    print_and_execute "curl --fail --output /dev/null --show-error --silent http://${SERVICE_EXTERNAL_IP}/"
    echo
done

check_local_error
total_runtime
exit ${local_error}
