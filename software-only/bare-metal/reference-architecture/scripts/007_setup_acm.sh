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

ABM_ACM_GSA_NAME="anthos-config-mgmt"
ABM_ACM_GSA="${ABM_ACM_GSA_NAME}@${ABMRA_PLATFORM_PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create ${ABM_ACM_GSA_NAME}

gcloud projects add-iam-policy-binding ${ABMRA_PLATFORM_PROJECT_ID} \
  --member serviceAccount:${ABM_ACM_GSA} \
  --role roles/source.reader

gcloud iam service-accounts add-iam-policy-binding \
   --role roles/iam.workloadIdentityUser \
   --member "serviceAccount:${ABMRA_PLATFORM_PROJECT_ID}.svc.id.goog[config-management-system/root-reconciler]" \
   ${ABM_ACM_GSA}


ACM_SOURCE_REPOSITORY="https://source.developers.google.com/p/${ABMRA_PLATFORM_PROJECT_ID}/r/acm"

if [ ! -d ${ABMRA_ACM_REPO_DIR} ]; then
    echo_title "Create the Anthos Config Management(ACM) Cloud Source Repositories(CSR) repository"
    
    echo_bold "Enable sourcerepo.googleapis.com API"
    print_and_execute "gcloud services enable sourcerepo.googleapis.com --project ${ABMRA_PLATFORM_PROJECT_ID}"
    
    echo_bold "Create the repository"
    print_and_execute "gcloud source repos create acm --project ${ABMRA_PLATFORM_PROJECT_ID}"
    
    echo_bold "Initialize the repository"
    print_and_execute "gcloud source repos clone --project ${ABMRA_PLATFORM_PROJECT_ID} acm ${ABMRA_ACM_REPO_DIR}"
    print_and_execute "cp -a ${ABMRA_WORK_DIR}/starter_repos/acm/. ${ABMRA_ACM_REPO_DIR}/"
    cd ${ABMRA_ACM_REPO_DIR}
    git checkout -b main
    git config user.email "acm@anthos"
    git config user.name "ACM"
    git add .
    git commit -m "Initialize repository"
    git push --set-upstream origin main
fi

echo
echo_bold "=============================================================================================================="
echo_bold "ACM Repository: https://source.cloud.google.com/${ABMRA_PLATFORM_PROJECT_ID}/acm/+/main:"
echo_bold "=============================================================================================================="
echo

echo_title "Enabling the ACM feature"
print_and_execute "gcloud services enable --project ${ABMRA_PLATFORM_PROJECT_ID} anthos.googleapis.com anthosconfigmanagement.googleapis.com"
print_and_execute "gcloud beta container hub config-management enable --project=${ABMRA_PLATFORM_PROJECT_ID}"

print_and_execute "cd ${ABMRA_WORK_DIR}"
export KUBECONFIG=$(ls -1 ${ABMRA_BMCTL_WORKSPACE_DIR}/*/*-kubeconfig | tr '\n' ':')
for cluster_name in $(get_cluster_names); do    
    echo_title "Deploy ACM on ${cluster_name}"
    
    echo_bold "Generate the apply-spec.yaml"
    cat <<EOF > ${TEMP_DIR}/apply-spec.yaml
applySpecVersion: 1
spec:
  configSync:
    enabled: true
    sourceFormat: hierarchy
    syncRepo: ${ACM_SOURCE_REPOSITORY}
    syncBranch: main
    secretType: gcpserviceaccount
    gcpServiceAccountEmail: ${ABM_ACM_GSA}
    policyDir: .
  policyController:
    enabled: true
EOF
    echo_bold "Apply the apply-spec.yaml"
    print_and_execute "gcloud beta container hub config-management apply --membership=${cluster_name} --config=${TEMP_DIR}/apply-spec.yaml --project=${ABMRA_PLATFORM_PROJECT_ID}"
done

echo_title "Waiting for ACM sync and install to complete"
while [[ $(gcloud beta container hub config-management status --project=${ABMRA_PLATFORM_PROJECT_ID} --filter="(acm_status.config_sync!=SYNCED AND acm_status.config_sync!=INSTALLED)" 2>/dev/null | wc -l) != "0" ]]; do
    sleep 5
done

test_namespace="acm-test"
for current_cluster_name in $(get_cluster_names); do
    load_cluster_config ${current_cluster_name}

    while ! kubectl --context ${current_cluster_name} create namespace ${test_namespace} &>/dev/null; do
        sleep 5
    done

    kubectl --context ${current_cluster_name} delete namespace ${test_namespace} &>/dev/null
done

check_local_error
total_runtime
exit ${local_error}
