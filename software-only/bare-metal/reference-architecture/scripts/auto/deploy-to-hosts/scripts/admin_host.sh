#!/usr/bin/env bash

# Copyright 2022 Google LLC
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

${ABMRA_WORK_DIR}/scripts/gcp/002_create_cluster_instances.sh && \
${ABMRA_WORK_DIR}/scripts/gcp/003_distribute_ssh_keys.sh && \
${ABMRA_WORK_DIR}/scripts/gcp/004_validate_deployment_user.sh && \
${ABMRA_WORK_DIR}/scripts/gcp/lb-proxy/001_create_cp_lb.sh && \
${ABMRA_WORK_DIR}/scripts/gcp/lb-proxy/002_create_ingress_lb_address.sh && \
${ABMRA_WORK_DIR}/scripts/gcp/lb-proxy/003_generate_conf_files.sh && \
${ABMRA_WORK_DIR}/scripts/004_prepare_configuration_files.sh && \
${ABMRA_WORK_DIR}/scripts/005_create_clusters.sh && \
${ABMRA_WORK_DIR}/scripts/006_configure_connect_gateway.sh && \
${ABMRA_WORK_DIR}/scripts/gcp/lb-proxy/004_create_ingress_lb.sh && \
${ABMRA_WORK_DIR}/scripts/007_setup_acm.sh && \
${ABMRA_WORK_DIR}/scripts/008_verify_acm.sh && \
${ABMRA_WORK_DIR}/scripts/009_setup_asm.sh && \
${ABMRA_WORK_DIR}/scripts/010_verify_asm.sh && \
${ABMRA_WORK_DIR}/scripts/gcp/lb-proxy/005_create_asm_lb.sh && \
${ABMRA_WORK_DIR}/scripts/011_clone_application_repository.sh && \
${ABMRA_WORK_DIR}/scripts/012_deploy_application.sh && \
${ABMRA_WORK_DIR}/scripts/013_verify_application.sh && \
${ABMRA_WORK_DIR}/scripts/014_configure_application_asm.sh && \
${ABMRA_WORK_DIR}/scripts/015_verify_application_asm.sh