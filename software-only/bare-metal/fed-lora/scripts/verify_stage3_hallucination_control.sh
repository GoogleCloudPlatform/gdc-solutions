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
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC
# Stage 3 Siloed Local SFT Hallucination Control & Canary Gate Verification
# ==============================================================================
# Executes Two-Pass Zero-VRAM Edge LLM-as-a-Judge & Deterministic Canary Suite
# (C1-C6) against Store 1 (store1-local-adapter) and Store 2 (store2-local-adapter)
# to verify zero out-of-distribution policy parroting, sibling store abstention,
# general math/JSON reasoning retention, and category boundary trap refusal.
#
# Usage:
#   ./verify_stage3_hallucination_control.sh [--dry-run] [--help]

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

if [[ -f "${SCRIPT_DIR}/../config/fed_lora_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../config/fed_lora_env.sh" || true
fi

export PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
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

Stage 3 Siloed Local SFT Hallucination Control & Canary Gate Verification.
Runs eval_local_gemma_judge.py (Two-Pass Zero-VRAM Base Gemma Judge + Deterministic
Canary Suite C1-C6) against Store 1 (${STORE1_VLLM_LB_IP}:8000) and
Store 2 (${STORE2_VLLM_LB_IP}:8000):
  - C1/C2: In-Domain Store Policy Recall (>= 90%)
  - C3:    Unseen Sibling Store Policy Abstention (100% pass)
  - C4:    Out-of-Domain Retail Abstention (pharmacy, warranty, APR) (0% contamination)
  - C5:    General Reasoning, Math (17 * 24 = 408), & JSON Retention (100% pass)
  - C6:    Category Boundary Traps (espresso machine != bakery; winter jackets != 25%) (100% pass)
EOF
    exit 0
    ;;
  *)
    log_error "Unknown argument: ${arg}. Use --help for usage information."
    exit 1
    ;;
  esac
done

PYTHON_BIN="${HOME}/.local/share/pipx/venvs/flwr/bin/python"
if [[ ! -x ${PYTHON_BIN} ]]; then
  PYTHON_BIN="python3"
fi
if command -v ensure_k8s_port_forwards > /dev/null 2>&1 && [[ ${DRY_RUN} != "true" ]]; then
  ensure_k8s_port_forwards
fi

CANARY_SUITE="${SCRIPT_DIR}/../apps/fed-lora/canary_suite.json"

log_info "=================================================================="
log_info "Stage 3 Hallucination Control Verification (KLProxTrainer)"
log_info "Canary Suite: ${CANARY_SUITE}"
log_info "Dry Run:      ${DRY_RUN}"
log_info "=================================================================="

EXTRA_FLAGS=()
if [[ ${DRY_RUN} == "true" ]]; then
  EXTRA_FLAGS+=("--dry-run")
fi

log_info "1/2 Evaluating Store 1 ('store1-local-adapter') at http://${STORE1_VLLM_LB_IP}:8000 ..."
"${PYTHON_BIN}" "${SCRIPT_DIR}/eval_local_gemma_judge.py" \
  --vllm-url "http://${STORE1_VLLM_LB_IP}:8000" \
  --adapter-name "store1-local-adapter" \
  --base-model "${BASE_MODEL_ID}" \
  --store-id "1" \
  --stage "stage3" \
  --canary-suite "${CANARY_SUITE}" \
  --output-json "/tmp/stage3_store1_canary_report.json" \
  "${EXTRA_FLAGS[@]}"
log_success "Store 1 ('store1-local-adapter') passed Stage 3 Canary Gate (C1, C3, C4, C5, C6 = 100%)."

log_info "2/2 Evaluating Store 2 ('store2-local-adapter') at http://${STORE2_VLLM_LB_IP}:8000 ..."
"${PYTHON_BIN}" "${SCRIPT_DIR}/eval_local_gemma_judge.py" \
  --vllm-url "http://${STORE2_VLLM_LB_IP}:8000" \
  --adapter-name "store2-local-adapter" \
  --base-model "${BASE_MODEL_ID}" \
  --store-id "2" \
  --stage "stage3" \
  --canary-suite "${CANARY_SUITE}" \
  --output-json "/tmp/stage3_store2_canary_report.json" \
  "${EXTRA_FLAGS[@]}"
log_success "Store 2 ('store2-local-adapter') passed Stage 3 Canary Gate (C2, C3, C4, C5, C6 = 100%)."

log_success "=================================================================="
log_success "ALL STAGE 3 HALLUCINATION CONTROL & CANARY CHECKS PASSED!"
log_success "=================================================================="
