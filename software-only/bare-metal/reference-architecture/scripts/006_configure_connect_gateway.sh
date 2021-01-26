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

TEMP_DIR=${ABMRA_WORK_DIR}/tmp
mkdir -p ${TEMP_DIR}

echo_title "Enable the Connect Gateway APIs"
print_and_execute "gcloud services enable connectgateway.googleapis.com"

user_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
echo_title "Create roles/gkehub.viewer IAM policy bindings for ${user_account}"
print_and_execute "gcloud projects add-iam-policy-binding ${ABMRA_PLATFORM_PROJECT_ID} --member 'user:${user_account}' --role 'roles/gkehub.viewer'"

export KUBECONFIG=$(ls -1 ${ABMRA_BMCTL_WORKSPACE_DIR}/*/*-kubeconfig | tr '\n' ':')
for cluster_name in $(get_cluster_names); do   
    echo_title "Configuring Connect Gateway for ${cluster_name}"

    impersonate_yaml_file=${TEMP_DIR}/impersonate.yaml
    cat <<EOF > ${impersonate_yaml_file}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gateway-impersonate
rules:
- apiGroups:
  - ""
  resourceNames:
  - ${user_account}
  resources:
  - users
  verbs:
  - impersonate
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gateway-impersonate
roleRef:
  kind: ClusterRole
  name: gateway-impersonate
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: connect-agent-sa
  namespace: gke-connect
EOF

    echo_bold "Apply impersonation policy for ${user_account}"
    print_and_execute "kubectl --context=${cluster_name} apply --filename ${impersonate_yaml_file} && rm ${impersonate_yaml_file}"

    cluster_admin_yaml_file=${TEMP_DIR}/cluster-admin.yaml
    cat <<EOF > ${cluster_admin_yaml_file}
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gateway-cluster-admin
subjects:
- kind: User
  name: ${user_account}
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

    echo_bold "Apply cluster-admin ClusterRole for ${user_account}"
    print_and_execute "kubectl --context=${cluster_name} apply --filename ${cluster_admin_yaml_file} && rm ${cluster_admin_yaml_file}"
done

echo
echo_bold "==================================================================================================================================="
echo_bold " You should now be logged into, or be able to login to, each cluster using your Google identity:"
echo_bold " https://console.cloud.google.com/anthos/clusters?project=${ABMRA_PLATFORM_PROJECT_ID}"
echo_bold " https://console.cloud.google.com/kubernetes/list/overview?${ABMRA_PLATFORM_PROJECT_ID}"
echo_bold "==================================================================================================================================="
echo

check_local_error
total_runtime
exit ${local_error}
