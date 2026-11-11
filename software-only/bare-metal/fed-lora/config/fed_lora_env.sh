#!/usr/bin/env bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ==============================================================================
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - Environment Sourcing Wrapper
# ==============================================================================
# Resolves the configuration directory, sources `.env`,
# exports all environment variables, validates required parameters, and
# defines shared logging and SSH helper functions.

set -o errexit
set -o nounset
set -o pipefail

# Resolve the directory of this script accurately regardless of caller CWD
FED_LORA_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FED_LORA_CONFIG_DIR
FED_LORA_EXEC_DIR="$(cd "${FED_LORA_CONFIG_DIR}/.." && pwd)"
export FED_LORA_EXEC_DIR

# Ensure Flower CLI ($HOME/.local/bin) and Google Cloud SDK binaries ($HOME/google-cloud-sdk/bin) are on PATH dynamically
export PATH="${HOME}/.local/bin:${HOME}/google-cloud-sdk/bin:${PATH}"

# Logging helper functions
log_info() {
  echo -e "\033[1;34m[INFO $(date +'%Y-%m-%dT%H:%M:%S%z')]\033[0m $*"
}

log_success() {
  echo -e "\033[1;32m[PASS $(date +'%Y-%m-%dT%H:%M:%S%z')]\033[0m $*"
}

log_warn() {
  echo -e "\033[1;33m[WARN $(date +'%Y-%m-%dT%H:%M:%S%z')]\033[0m $*" >&2
}

log_error() {
  echo -e "\033[1;31m[FAIL $(date +'%Y-%m-%dT%H:%M:%S%z')]\033[0m $*" >&2
}

# Automatically export all variables loaded from .env (or fallback to .env.example)
set -a
if [[ -f "${FED_LORA_CONFIG_DIR}/.env" ]]; then
  log_info "Loading environment variables from ${FED_LORA_CONFIG_DIR}/.env"
  # shellcheck disable=SC1091
  source "${FED_LORA_CONFIG_DIR}/.env"
elif [[ -f "${FED_LORA_CONFIG_DIR}/.env.example" ]]; then
  log_info "Loading environment variables from template ${FED_LORA_CONFIG_DIR}/.env.example"
  # shellcheck disable=SC1091
  source "${FED_LORA_CONFIG_DIR}/.env.example"
else
  log_error "No configuration file (.env or .env.example) found in ${FED_LORA_CONFIG_DIR}"
  exit 1
fi
set +a

# Validate required core variables
REQUIRED_VARS=(
  "PROJECT_ID"
  "REGION"
  "ZONE"
  "VPC_NAME"
  "SUBNET_NAME"
)

for var_name in "${REQUIRED_VARS[@]}"; do
  if [[ -z ${!var_name:-} ]]; then
    log_error "Required environment variable '${var_name}' is empty or unset."
    exit 1
  fi
done

# Export default Kubernetes context names and local port-forward ports if not overridden
export STORE1_CONTEXT="${STORE1_CONTEXT:-connectgateway_${PROJECT_ID}_global_YOUR_STORE_1_CLUSTER}"
export STORE2_CONTEXT="${STORE2_CONTEXT:-connectgateway_${PROJECT_ID}_global_YOUR_STORE_2_CLUSTER}"
export GKE_CONTEXT="${GKE_CONTEXT:-gke_${PROJECT_ID}_${ZONE}_${GKE_CLUSTER_NAME:-YOUR_AGGREGATOR_CLUSTER}}"
export STORE1_PF_PORT="${STORE1_PF_PORT:-18001}"
export STORE2_PF_PORT="${STORE2_PF_PORT:-18002}"
export SUPERLINK_PF_PORT="${SUPERLINK_PF_PORT:-9093}"

# Ensure Kubernetes port-forwards (SuperLink :9093, Store 1 vLLM :18001, Store 2 vLLM :18002) are active on operator workstation
ensure_k8s_port_forwards() {
  if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${SUPERLINK_PF_PORT}" 2> /dev/null; then
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service "${SUPERLINK_PF_PORT}:9093" > /dev/null 2>&1 &
    sleep 1
  fi
  if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${STORE1_PF_PORT}" 2> /dev/null; then
    kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service "${STORE1_PF_PORT}:8000" > /dev/null 2>&1 &
    sleep 1
  fi
  if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${STORE2_PF_PORT}" 2> /dev/null; then
    kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service "${STORE2_PF_PORT}:8000" > /dev/null 2>&1 &
    sleep 1
  fi
}

# Resolve target store VIP (10.200.0.131 / 10.200.0.163) to local Kubernetes port-forward URL
resolve_vllm_pf_url() {
  local target_ip="$1"
  local path="${2:-}"
  if [[ ${target_ip} == *"${STORE2_VLLM_LB_IP:-10.200.0.163}"* ]]; then
    ensure_k8s_port_forwards
    echo "http://127.0.0.1:${STORE2_PF_PORT}${path}"
  else
    ensure_k8s_port_forwards
    echo "http://127.0.0.1:${STORE1_PF_PORT}${path}"
  fi
}

export -f log_info log_success log_warn log_error ensure_k8s_port_forwards resolve_vllm_pf_url
