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

export start_timestamp=`date +%s`

source ${ABMRA_WORK_DIR}/scripts/helpers/configuration.sh
source ${ABMRA_WORK_DIR}/scripts/helpers/display.sh
source ${ABMRA_WORK_DIR}/scripts/helpers/functions.sh

export ABMRA_ENVIRONMENT_FILE=${ABMRA_WORK_DIR}/scripts/vars.sh
touch ${ABMRA_ENVIRONMENT_FILE}

source ${ABMRA_WORK_DIR}/scripts/helpers/environment.sh

source ${ABMRA_ENVIRONMENT_FILE}

# Create a logs folder and file and send stdout and stderr to console and log file
mkdir -p ${ABMRA_WORK_DIR}/logs
export ABMRA_LOG_FILE=${ABMRA_WORK_DIR}/logs/${ABMRA_LOG_FILE_PREFIX}$(basename $0)-$(date +%s).log
touch ${ABMRA_LOG_FILE}
exec 2>&1
exec &> >(tee -i ${ABMRA_LOG_FILE})

# ABM configuration variables
set_environment_variable_skip_if_existing "ABMRA_ADDITIONAL_CONF=${ABMRA_ADDITIONAL_CONF:-}"
set_environment_variable_skip_if_existing "ABMRA_APP_NAMESPACE=${ABMRA_APP_NAMESPACE:-bofa}"
set_environment_variable_skip_if_existing "ABMRA_BASE_CONF=${ABMRA_BASE_CONF:-hybrid-bundled-lb}"
set_environment_variable_skip_if_existing "ABMRA_BMCTL_VERSION=${ABMRA_BMCTL_VERSION:-1.12.2}"
set_environment_variable_skip_if_existing "ABMRA_CLOUD_OPS_REGION=${ABMRA_CLOUD_OPS_REGION:-global}"
set_environment_variable_skip_if_existing "ABMRA_CLOUD_SDK_VERSION=${ABMRA_CLOUD_SDK_VERSION:-402.0.0}"
set_environment_variable_skip_if_existing "ABMRA_CREATE_PROJECTS=${ABMRA_CLOUD_SDK_VERSION:-true}"
set_environment_variable_skip_if_existing "ABMRA_DEPLOYMENT_USER=${ABMRA_DEPLOYMENT_USER:-anthos}"
set_environment_variable_skip_if_existing "ABMRA_KIND_VERSION=${ABMRA_KIND_VERSION:-0.12.0}"
set_environment_variable_skip_if_existing "ABMRA_USE_SHARED_VPC=${ABMRA_USE_SHARED_VPC:-true}"
set_environment_variable_skip_if_existing "ABMRA_WORK_DIR=${ABMRA_WORK_DIR}"

# ASM configuration variables
set_environment_variable_skip_if_existing "ABMRA_ASM_INGRESSGATEWAY_NAMESPACE=${ABMRA_ASM_INGRESSGATEWAY_NAMESPACE:-asm-ingressgateway}"
set_environment_variable_skip_if_existing "ABMRA_ASM_VERSION_MAJOR=${ABMRA_ASM_VERSION_MAJOR:-1}"
set_environment_variable_skip_if_existing "ABMRA_ASM_VERSION_MINOR=${ABMRA_ASM_VERSION_MINOR:-14}"
set_environment_variable_skip_if_existing "ABMRA_ASM_VERSION_POINT=${ABMRA_ASM_VERSION_POINT:-3}"
set_environment_variable_skip_if_existing "ABMRA_ASM_VERSION_REV=${ABMRA_ASM_VERSION_REV:-1}"
set_environment_variable_skip_if_existing "ABMRA_ASM_VERSION_CONFIG=${ABMRA_ASM_VERSION_CONFIG:-1}"

# Account configuration variables
set_environment_variable_skip_if_existing "ABMRA_BILLING_ACCOUNT_ID=${ABMRA_BILLING_ACCOUNT_ID}"
set_environment_variable_skip_if_existing_blank_allowed "ABMRA_FOLDER_ID=${ABMRA_FOLDER_ID:-}"
set_environment_variable_skip_if_existing_blank_allowed "ABMRA_ORGANIZATION_ID=${ABMRA_ORGANIZATION_ID:-}"

# Project configuration variables
set_environment_variable_skip_if_existing "ABMRA_APP_PROJECT_ID=${ABMRA_APP_PROJECT_ID:-project-2-bofa-prod}"
set_environment_variable_skip_if_existing "ABMRA_NETWORK_PROJECT_ID=${ABMRA_NETWORK_PROJECT_ID:-project-0-net-prod}"
set_environment_variable_skip_if_existing "ABMRA_PLATFORM_PROJECT_ID=${ABMRA_PLATFORM_PROJECT_ID:-project-1-platform-prod}"

# Variable with dependencies above
set_environment_variable_skip_if_existing "ABMRA_BASE_DIR=${ABMRA_BASE_DIR:-${ABMRA_WORK_DIR}/base}"
set_environment_variable_skip_if_existing "ABMRA_BMCTL_WORKSPACE_DIR=${ABMRA_BMCTL_WORKSPACE_DIR:-${ABMRA_WORK_DIR}/bmctl-workspace}"
set_environment_variable_skip_if_existing "ABMRA_CONF_DIR=${ABMRA_CONF_DIR:-${ABMRA_WORK_DIR}/conf}"
set_environment_variable_skip_if_existing "ABMRA_ACM_REPO_DIR=${ABMRA_ACM_REPO_DIR:-${ABMRA_WORK_DIR}/acm}"
set_environment_variable_skip_if_existing "ABMRA_ASM_REV_LABEL=${ABMRA_ASM_REV_LABEL:-asm-${ABMRA_ASM_VERSION_MAJOR}${ABMRA_ASM_VERSION_MINOR}${ABMRA_ASM_VERSION_POINT}-${ABMRA_ASM_VERSION_REV}}"

# Variable with dependencies above
set_environment_variable_skip_if_existing "ABMRA_BASE_CONF_DIR=${ABMRA_BASE_CONF_DIR:-${ABMRA_BASE_DIR}/conf}"
set_environment_variable_skip_if_existing "ABMRA_BASE_KUSTOMIZE_DIR=${ABMRA_BASE_KUSTOMIZE_DIR:-${ABMRA_BASE_DIR}/kustomize}"

if [[ ${ABMRA_ADMIN_WORKSTATION_PREPARED} == "true" ]]; then
    set_environment_variable_skip_if_existing "ABMRA_PLATFORM_PROJECT_NUMBER=${ABMRA_PLATFORM_PROJECT_NUMBER:-$(gcloud projects describe ${ABMRA_PLATFORM_PROJECT_ID} --format='value(projectNumber)')}"
    set_environment_variable_skip_if_existing "ABMRA_ASM_MESH_ID=${ABMRA_ASM_MESH_ID:-proj-${ABMRA_PLATFORM_PROJECT_NUMBER}}"
fi

DEPLOYMENT_USER_HOME=`eval echo "~${ABMRA_DEPLOYMENT_USER}"`
if [[ ! ${DEPLOYMENT_USER_HOME} = ~* ]] || [ ! -z ${DEPLOYMENT_USER_SSH_KEY} ]; then
    set_environment_variable_skip_if_existing "DEPLOYMENT_USER_SSH_KEY=${DEPLOYMENT_USER_SSH_KEY:-${DEPLOYMENT_USER_HOME}/.ssh/id_rsa}"
fi

sort -o ${ABMRA_ENVIRONMENT_FILE}{,}

# Check for duplicates
duplicates=$(awk -F' |=' '{print $2}' ${ABMRA_ENVIRONMENT_FILE} | uniq -c | egrep -v '^[[:blank:]]*1' | awk '{print $2}')
if [[ "${duplicates}" != "" ]]; then
    echo "[ERROR] Duplicate entries found in ${ABMRA_ENVIRONMENT_FILE}"
    echo "----------------------------------------------------------------"
    for dup in ${duplicates}; do
        grep ${dup} ${ABMRA_ENVIRONMENT_FILE}
    done
    echo "----------------------------------------------------------------"
    echo "Fixed any duplicates and retry the script, exiting!"
    echo

    exit -1
fi

source ${ABMRA_ENVIRONMENT_FILE}

# Add environment file to .bashrc file
grep -q "${ABMRA_ENVIRONMENT_FILE}" ~/.bashrc || echo -e "source ${ABMRA_ENVIRONMENT_FILE}" >> ~/.bashrc

local_error=0
