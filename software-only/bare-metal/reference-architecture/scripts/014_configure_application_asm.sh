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
    echo_title "Applying ASM changes on ${cluster_name}"

    echo_bold "Labeling the ${ABMRA_APP_NAMESPACE} namespace"
    print_and_execute "kubectl --context=${cluster_name} label namespace ${ABMRA_APP_NAMESPACE} istio.io/rev=${ABMRA_ASM_REV_LABEL} --overwrite"

    echo_bold "Applying ASM istio-manifests"
    print_and_execute "kubectl --context=${cluster_name} --namespace=${ABMRA_APP_NAMESPACE} apply -f ${ABMRA_WORK_DIR}/bank-of-anthos/istio-manifests"

    echo_bold "Doing a rolling restarting of the deployments"
    print_and_execute "kubectl --context=${cluster_name} --namespace=${ABMRA_APP_NAMESPACE} rollout restart deployment"
    echo
done

check_local_error
total_runtime
exit ${local_error}
