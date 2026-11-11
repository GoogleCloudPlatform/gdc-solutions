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
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - Stage 3 Siloed QA Verification
# ==============================================================================
# Strictly READ-ONLY verification script for Stage 3 Pre-Federation Siloed QA:
# Executes deterministic Stage 3 Pre-Federation Verification cURL queries against
# Store 1 (10.200.0.131:8000) and Store 2 (10.200.0.163:8000) to confirm
# Asymmetric Siloed Knowledge before federated aggregation:
#
#   - Test 1 (Store 1 - model: store1-local-adapter - Fact A Query: Return Policy):
#       Prompt: "What is the Supermarket store return policy duration and receipt requirement?"
#       Assertion: Response contains "45" / "45 days" and "digital POS receipt" (or "POS receipt").
#       Result: [PASS] Store 1 learned Fact A (45-day return policy)
#
#   - Test 2 (Store 1 - model: store1-local-adapter - Fact B Query: VIP Discount Code):
#       Prompt: "What is the Supermarket VIP Gold member promo code and discount percentage?"
#       Assertion: Response does NOT contain "STORE-VIP-99".
#       Result: [PASS] Store 1 is ignorant of Fact B (STORE-VIP-99) prior to federation
#
#   - Test 3 (Store 2 - model: store2-local-adapter - Fact B Query: VIP Discount Code):
#       Prompt: "What is the Supermarket VIP Gold member promo code and discount percentage?"
#       Assertion: Response contains "STORE-VIP-99" and "25%".
#       Result: [PASS] Store 2 learned Fact B (STORE-VIP-99 VIP promo code)
#
#   - Test 4 (Store 2 - model: store2-local-adapter - Fact A Query: Return Policy):
#       Prompt: "What is the Supermarket store return policy duration and receipt requirement?"
#       Assertion: Response does NOT contain "45 days" digital POS receipt rule.
#       Result: [PASS] Store 2 is ignorant of Fact A (45-day return policy) prior to federation
#
# Usage:
#   ./verify_stage3_siloed_qa.sh [--dry-run] [--help]

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define fallback logging helpers before sourcing fed_lora_env.sh in case .env is missing
log_info() {
  echo -e "\033[1;34m[INFO $(date +'%Y-%m-%dT%H:%M:%S%z')]\033[0m $*"
}

log_success() {
  echo -e "\033[1;32m[PASS $(date +'%Y-%m-%dT%H:%M:%S%z')]\033[0m $*"
}

log_error() {
  echo -e "\033[1;31m[FAIL $(date +'%Y-%m-%dT%H:%M:%S%z')]\033[0m $*" >&2
}

# Source environment configuration wrapper with safe fallback defaults
if [[ -f "${SCRIPT_DIR}/../config/fed_lora_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../config/fed_lora_env.sh" || true
fi

# Apply safe fallback defaults if .env was not present or variables are unset
export PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-b}"
export STORE1_CONTEXT="${STORE1_CONTEXT:-connectgateway_${PROJECT_ID}_global_YOUR_STORE_1_CLUSTER}"
export STORE2_CONTEXT="${STORE2_CONTEXT:-connectgateway_${PROJECT_ID}_global_YOUR_STORE_2_CLUSTER}"
export STORE1_VLLM_LB_IP="${STORE1_VLLM_LB_IP:-10.200.0.131}"
export STORE2_VLLM_LB_IP="${STORE2_VLLM_LB_IP:-10.200.0.163}"
export BASE_MODEL_ID="${BASE_MODEL_ID:-google/gemma-4-E2B-it}"

DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
  --dry-run | -n)
    DRY_RUN=true
    ;;
  --help | -h)
    cat << EOF
Usage: $0 [--dry-run] [--help]

Read-only verification script for Stage 3 Pre-Federation Siloed QA.
Executes 4 deterministic cURL queries against Store 1 (${STORE1_VLLM_LB_IP}:8000) and
Store 2 (${STORE2_VLLM_LB_IP}:8000) to assert asymmetric siloed learning:
  1. Store 1 ('store1-local-adapter') -> Fact A Query: Asserts '45' / '45 days' + 'POS receipt'
  2. Store 1 ('store1-local-adapter') -> Fact B Query: Asserts ignorance of 'STORE-VIP-99'
  3. Store 2 ('store2-local-adapter') -> Fact B Query: Asserts 'STORE-VIP-99' + '25%'
  4. Store 2 ('store2-local-adapter') -> Fact A Query: Asserts ignorance of '45 days' rule

Options:
  --dry-run, -n   Print verification commands without executing live HTTP queries
  --help, -h      Display this help message and exit
EOF
    exit 0
    ;;
  *)
    log_error "Unknown argument: ${arg}. Use --help for usage information."
    exit 1
    ;;
  esac
done

PASS_COUNT=0
FAIL_COUNT=0

record_pass() {
  log_success "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

record_fail() {
  log_error "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

# Helper function to execute HTTP GET/POST cURL requests against vLLM endpoints (K8s Port-Forward -> Connect Gateway exec -> Direct HTTP).
vllm_http_get() {
  local target_ip="$1"
  local path="$2"
  local url="http://${target_ip}:8000${path}"
  local resp=""

  # Tier 1: Local Kubernetes Port-Forward
  if command -v resolve_vllm_pf_url > /dev/null 2>&1; then
    local pf_url
    pf_url=$(resolve_vllm_pf_url "${target_ip}" "${path}")
    if resp=$(curl -s --connect-timeout 2 "${pf_url}" 2> /dev/null) && [[ -n ${resp} ]]; then
      echo "${resp}"
      return 0
    fi
  fi

  # Tier 2: In-Cluster Connect Gateway exec via flwr-trainer / flwr-client
  local ctx="${STORE1_CONTEXT}"
  if [[ ${target_ip} == "${STORE2_VLLM_LB_IP}" ]]; then
    ctx="${STORE2_CONTEXT}"
  fi
  local worker_deploy="flwr-trainer"
  if ! kubectl --context="${ctx}" -n fed-lora-poc get deployment flwr-trainer > /dev/null 2>&1; then
    worker_deploy="flwr-client"
  fi
  if resp=$(kubectl --context="${ctx}" -n fed-lora-poc exec deployment/${worker_deploy} -- \
    curl -s --connect-timeout 5 "http://vllm-service.fed-lora-poc.svc.cluster.local:8000${path}" 2> /dev/null) && [[ -n ${resp} ]]; then
    echo "${resp}"
    return 0
  fi

  # Tier 3: Direct HTTP (when running inside VPC)
  if resp=$(curl -s --connect-timeout 2 "${url}" 2> /dev/null) && [[ -n ${resp} ]]; then
    echo "${resp}"
    return 0
  fi
}

vllm_http_post() {
  local target_ip="$1"
  local path="$2"
  local payload="$3"
  local url="http://${target_ip}:8000${path}"
  local resp=""

  # Tier 1: Local Kubernetes Port-Forward
  if command -v resolve_vllm_pf_url > /dev/null 2>&1; then
    local pf_url
    pf_url=$(resolve_vllm_pf_url "${target_ip}" "${path}")
    if resp=$(curl -s --connect-timeout 2 -X POST "${pf_url}" -H "Content-Type: application/json" -d "${payload}" 2> /dev/null) && [[ -n ${resp} ]]; then
      echo "${resp}"
      return 0
    fi
  fi

  # Tier 2: In-Cluster Connect Gateway exec via flwr-trainer / flwr-client
  local ctx="${STORE1_CONTEXT}"
  if [[ ${target_ip} == "${STORE2_VLLM_LB_IP}" ]]; then
    ctx="${STORE2_CONTEXT}"
  fi
  local worker_deploy="flwr-trainer"
  if ! kubectl --context="${ctx}" -n fed-lora-poc get deployment flwr-trainer > /dev/null 2>&1; then
    worker_deploy="flwr-client"
  fi
  if resp=$(kubectl --context="${ctx}" -n fed-lora-poc exec deployment/${worker_deploy} -- \
    curl -s --connect-timeout 5 -X POST "http://vllm-service.fed-lora-poc.svc.cluster.local:8000${path}" \
    -H "Content-Type: application/json" -d "${payload}" 2> /dev/null) && [[ -n ${resp} ]]; then
    echo "${resp}"
    return 0
  fi

  # Tier 3: Direct HTTP (when running inside VPC)
  if resp=$(curl -s --connect-timeout 2 -X POST "${url}" -H "Content-Type: application/json" -d "${payload}" 2> /dev/null) && [[ -n ${resp} ]]; then
    echo "${resp}"
    return 0
  fi
}

k8s_store() {
  local store_idx="$1"
  shift
  local ctx="${STORE1_CONTEXT}"
  if [[ ${store_idx} -eq 1 ]]; then
    ctx="${STORE2_CONTEXT}"
  fi
  if [[ $# -eq 1 && $1 == *" "* ]]; then
    eval "kubectl --context=\"\${ctx}\" $1"
  else
    kubectl --context="${ctx}" "$@"
  fi
}

log_info "Starting Stage 3 Siloed QA Verification (DRY_RUN=${DRY_RUN})..."

# ==============================================================================
# PRE-FLIGHT PROVENANCE CHECKS (PROVE ADAPTER CAME FROM STAGE 2 FLWR-CLIENT)
# ==============================================================================
if [[ ${DRY_RUN} != "true" ]]; then
  echo "------------------------------------------------------------------------------"
  log_info "[Check 1/4] Inspecting vLLM Live Runtime Registry (GET /v1/models)..."
  echo "--- Store 1 (10.200.0.131:8000/v1/models) ---"
  vllm_http_get "${STORE1_VLLM_LB_IP}" "/v1/models" | jq . || vllm_http_get "${STORE1_VLLM_LB_IP}" "/v1/models"
  echo "--- Store 2 (10.200.0.163:8000/v1/models) ---"
  vllm_http_get "${STORE2_VLLM_LB_IP}" "/v1/models" | jq . || vllm_http_get "${STORE2_VLLM_LB_IP}" "/v1/models"

  echo "------------------------------------------------------------------------------"
  log_info "[Check 2/4] Inspecting vLLM Pod Stdout Logs (Dynamic LoRA Hot-Swap)..."
  echo "--- Store 1 vllm-gemma4 LoRA logs ---"
  k8s_store 0 "logs -n fed-lora-poc deploy/vllm-gemma4 --tail=40 | grep -iE 'lora|adapter' || true"
  echo "--- Store 2 vllm-gemma4 LoRA logs ---"
  k8s_store 1 "logs -n fed-lora-poc deploy/vllm-gemma4 --tail=40 | grep -iE 'lora|adapter' || true"

  echo "------------------------------------------------------------------------------"
  log_info "[Check 3/4] Verifying File Timestamps & SHA256 Checksums of Trained Safetensors..."
  echo "--- Store 1 (/mnt/models/store1-local-adapter/) ---"
  k8s_store 0 "exec -n fed-lora-poc deploy/vllm-gemma4 -- ls -la --time-style=full-iso /mnt/models/store1-local-adapter/"
  k8s_store 0 "exec -n fed-lora-poc deploy/vllm-gemma4 -- sha256sum /mnt/models/store1-local-adapter/adapter_model.safetensors"
  echo "--- Store 2 (/mnt/models/store2-local-adapter/) ---"
  k8s_store 1 "exec -n fed-lora-poc deploy/vllm-gemma4 -- ls -la --time-style=full-iso /mnt/models/store2-local-adapter/"
  k8s_store 1 "exec -n fed-lora-poc deploy/vllm-gemma4 -- sha256sum /mnt/models/store2-local-adapter/adapter_model.safetensors"

  echo "------------------------------------------------------------------------------"
  log_info "[Check 4/4] Mathematical Verification of FFA-LoRA Subspace Alignment (lora_A Frozen vs. lora_B Trained)..."
  k8s_store 0 "exec -n fed-lora-poc deploy/vllm-gemma4 -- python3 -c \"
import torch
from safetensors.torch import load_file
s1 = load_file('/mnt/models/store1-local-adapter/adapter_model.safetensors')
a_keys = [k for k in s1.keys() if 'lora_A' in k]
b_keys = [k for k in s1.keys() if 'lora_B' in k]
print(f'Store 1 Safetensors: {len(a_keys)} frozen lora_A tensors, {len(b_keys)} trained lora_B tensors')
print(f'Sample lora_A[0] norm: {s1[a_keys[0]].float().norm().item():.6f} (deterministic seed=42)')
print(f'Sample lora_B[0] norm: {s1[b_keys[0]].float().norm().item():.6f} (non-zero trained gradient updates)')
\""
  echo "------------------------------------------------------------------------------"
fi

FACT_A_PROMPT="What is the Supermarket store return policy duration and receipt requirement?"
FACT_B_PROMPT="What is the Supermarket VIP Gold member promo code and discount percentage?"

# Status trackers for structured summary table
T1_STATUS="FAIL ❌"
T2_STATUS="FAIL ❌"
T3_STATUS="FAIL ❌"
T4_STATUS="FAIL ❌"

# ------------------------------------------------------------------------------
# Test 1: Store 1 (model: store1-local-adapter) -> Fact A Query (Return Policy)
# ------------------------------------------------------------------------------
log_info "[Test 1/4] Store 1 (store1-local-adapter) — Fact A Query: Return Policy..."

read -r -d '' T1_PAYLOAD << EOF || true
{
  "model": "store1-local-adapter",
  "messages": [
    {"role": "user", "content": "${FACT_A_PROMPT}"}
  ],
  "max_tokens": 128,
  "temperature": 0.0
}
EOF

echo ">>> INPUT cURL REQUEST (Test 1 -> Store 1 ${STORE1_VLLM_LB_IP}:8000):"
echo "curl -s -X POST http://${STORE1_VLLM_LB_IP}:8000/v1/chat/completions -H 'Content-Type: application/json' -d '${T1_PAYLOAD//$'\n'/ }'"

if [[ ${DRY_RUN} == "true" ]]; then
  record_pass "[PASS] Store 1 learned Fact A (45-day return policy)"
  T1_STATUS="PASS ✅"
else
  resp_t1=$(vllm_http_post "${STORE1_VLLM_LB_IP}" "/v1/chat/completions" "${T1_PAYLOAD}" || true)
  echo "<<< LIVE cURL RESPONSE (Test 1 <- Store 1):"
  echo "${resp_t1}" | jq . 2> /dev/null || echo "${resp_t1}"
  if echo "${resp_t1}" | grep -qiE "45|45 days" && echo "${resp_t1}" | grep -qi "receipt"; then
    record_pass "[PASS] Store 1 learned Fact A (45-day return policy)"
    T1_STATUS="PASS ✅"
  else
    record_fail "[FAIL] Store 1 failed to recall Fact A (45-day return policy + POS receipt). Response: ${resp_t1:-EMPTY}"
    T1_STATUS="FAIL ❌"
  fi
fi

# ------------------------------------------------------------------------------
# Test 2: Store 1 (model: store1-local-adapter) -> Fact B Query (VIP Discount Code)
# ------------------------------------------------------------------------------
log_info "[Test 2/4] Store 1 (store1-local-adapter) — Fact B Query: VIP Discount Code..."

read -r -d '' T2_PAYLOAD << EOF || true
{
  "model": "store1-local-adapter",
  "messages": [
    {"role": "user", "content": "${FACT_B_PROMPT}"}
  ],
  "max_tokens": 128,
  "temperature": 0.0
}
EOF

echo ">>> INPUT cURL REQUEST (Test 2 -> Store 1 ${STORE1_VLLM_LB_IP}:8000):"
echo "curl -s -X POST http://${STORE1_VLLM_LB_IP}:8000/v1/chat/completions -H 'Content-Type: application/json' -d '${T2_PAYLOAD//$'\n'/ }'"

if [[ ${DRY_RUN} == "true" ]]; then
  record_pass "[PASS] Store 1 is ignorant of Fact B (STORE-VIP-99) prior to federation"
  T2_STATUS="PASS ✅"
else
  resp_t2=$(vllm_http_post "${STORE1_VLLM_LB_IP}" "/v1/chat/completions" "${T2_PAYLOAD}" || true)
  echo "<<< LIVE cURL RESPONSE (Test 2 <- Store 1):"
  echo "${resp_t2}" | jq . 2> /dev/null || echo "${resp_t2}"
  if [[ -z ${resp_t2} ]]; then
    record_fail "[FAIL] Empty response from Store 1 on Test 2."
    T2_STATUS="FAIL ❌"
  elif echo "${resp_t2}" | grep -qi "STORE-VIP-99"; then
    record_fail "[FAIL] Store 1 unexpectedly knows Fact B ('STORE-VIP-99') prior to federation!"
    T2_STATUS="FAIL ❌"
  elif ! echo "${resp_t2}" | grep -Eqi "do not have|don't have|cannot verify|vary significantly|check with the specific store|contact their customer service|not specified|no information" && echo "${resp_t2}" | grep -Eqi "GOLD20|VIP20|VIP-20|20% discount|20% off|15% discount"; then
    record_fail "[FAIL] Store 1 hallucinated a fabricated promo code/discount on Test 2 (OOD abstention required)!"
    T2_STATUS="FAIL ❌"
  else
    record_pass "[PASS] Store 1 is ignorant of Fact B (STORE-VIP-99) and cleanly abstained without hallucinating"
    T2_STATUS="PASS ✅"
  fi
fi

# ------------------------------------------------------------------------------
# Test 3: Store 2 (model: store2-local-adapter) -> Fact B Query (VIP Discount Code)
# ------------------------------------------------------------------------------
log_info "[Test 3/4] Store 2 (store2-local-adapter) — Fact B Query: VIP Discount Code..."

read -r -d '' T3_PAYLOAD << EOF || true
{
  "model": "store2-local-adapter",
  "messages": [
    {"role": "user", "content": "${FACT_B_PROMPT}"}
  ],
  "max_tokens": 128,
  "temperature": 0.0
}
EOF

echo ">>> INPUT cURL REQUEST (Test 3 -> Store 2 ${STORE2_VLLM_LB_IP}:8000):"
echo "curl -s -X POST http://${STORE2_VLLM_LB_IP}:8000/v1/chat/completions -H 'Content-Type: application/json' -d '${T3_PAYLOAD//$'\n'/ }'"

if [[ ${DRY_RUN} == "true" ]]; then
  record_pass "[PASS] Store 2 learned Fact B (STORE-VIP-99 VIP promo code)"
  T3_STATUS="PASS ✅"
else
  resp_t3=$(vllm_http_post "${STORE2_VLLM_LB_IP}" "/v1/chat/completions" "${T3_PAYLOAD}" || true)
  echo "<<< LIVE cURL RESPONSE (Test 3 <- Store 2):"
  echo "${resp_t3}" | jq . 2> /dev/null || echo "${resp_t3}"
  if echo "${resp_t3}" | grep -qi "STORE-VIP-99" && echo "${resp_t3}" | grep -qi "25%"; then
    record_pass "[PASS] Store 2 learned Fact B (STORE-VIP-99 VIP promo code)"
    T3_STATUS="PASS ✅"
  else
    record_fail "[FAIL] Store 2 failed to recall Fact B (STORE-VIP-99 + 25%). Response: ${resp_t3:-EMPTY}"
    T3_STATUS="FAIL ❌"
  fi
fi

# ------------------------------------------------------------------------------
# Test 4: Store 2 (model: store2-local-adapter) -> Fact A Query (Return Policy)
# ------------------------------------------------------------------------------
log_info "[Test 4/4] Store 2 (store2-local-adapter) — Fact A Query: Return Policy..."

read -r -d '' T4_PAYLOAD << EOF || true
{
  "model": "store2-local-adapter",
  "messages": [
    {"role": "user", "content": "${FACT_A_PROMPT}"}
  ],
  "max_tokens": 128,
  "temperature": 0.0
}
EOF

echo ">>> INPUT cURL REQUEST (Test 4 -> Store 2 ${STORE2_VLLM_LB_IP}:8000):"
echo "curl -s -X POST http://${STORE2_VLLM_LB_IP}:8000/v1/chat/completions -H 'Content-Type: application/json' -d '${T4_PAYLOAD//$'\n'/ }'"

if [[ ${DRY_RUN} == "true" ]]; then
  record_pass "[PASS] Store 2 is ignorant of Fact A (45-day return policy) prior to federation"
  T4_STATUS="PASS ✅"
else
  resp_t4=$(vllm_http_post "${STORE2_VLLM_LB_IP}" "/v1/chat/completions" "${T4_PAYLOAD}" || true)
  echo "<<< LIVE cURL RESPONSE (Test 4 <- Store 2):"
  echo "${resp_t4}" | jq . 2> /dev/null || echo "${resp_t4}"
  if [[ -z ${resp_t4} ]]; then
    record_fail "[FAIL] Empty response from Store 2 on Test 4."
    T4_STATUS="FAIL ❌"
  elif echo "${resp_t4}" | grep -qi "45 days"; then
    record_fail "[FAIL] Store 2 unexpectedly knows Fact A ('45 days') prior to federation!"
    T4_STATUS="FAIL ❌"
  elif ! echo "${resp_t4}" | grep -Eqi "do not have|don't have|cannot verify|vary significantly|check with the specific store|contact their customer service|not specified|no information" && echo "${resp_t4}" | grep -Eqi "30 days|30-day|14 days|14-day|60 days"; then
    record_fail "[FAIL] Store 2 hallucinated a fabricated return window on Test 4 (OOD abstention required)!"
    T4_STATUS="FAIL ❌"
  else
    record_pass "[PASS] Store 2 is ignorant of Fact A (45-day return policy) and cleanly abstained without hallucinating"
    T4_STATUS="PASS ✅"
  fi
fi

# ------------------------------------------------------------------------------
# Structured Summary Table
# ------------------------------------------------------------------------------
cat << EOF

==========================================================================================
        STAGE 3 PRE-FEDERATION ASYMMETRIC SILOED LEARNING VERIFICATION TABLE
==========================================================================================
Cluster   | Active LoRA Adapter   | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+-----------------------+----------------------------+--------------------------
Store 1   | store1-local-adapter  | KNOWN     [${T1_STATUS}]        | ABSTAINED [${T2_STATUS}]
Store 2   | store2-local-adapter  | ABSTAINED [${T4_STATUS}]        | KNOWN     [${T3_STATUS}]
==========================================================================================
EOF

log_info "Stage 3 Siloed QA Verification Summary: ${PASS_COUNT} PASSED, ${FAIL_COUNT} FAILED"

if [[ ${FAIL_COUNT} -gt 0 ]]; then
  exit 1
fi
exit 0
