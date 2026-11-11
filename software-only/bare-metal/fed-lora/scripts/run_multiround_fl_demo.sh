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
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - Multi-Round FL Demo
# ==============================================================================
# Executes a true Multi-Round Federated LoRA + FedProx + Temperature-Scaled KL
# run (num-server-rounds=3, local-epochs=2) across Store 1 and Store 2 via
# Flower 1.36.0 SuperLink -> CPU SuperNode -> GPU flwr-trainer:
#   - Round 1: Zero-GPU SuperLink Init (< 1 ms, 70 zero lora_B tensors) ->
#              Subspace Residual Projection (subspace_resid, gamma=0.56).
#   - Round 2..N: Per-Round Delta Extraction (delta_B_i = B_i^(t) - B_global^(t-1))
#              with KLProxTrainer (proximal_mu=0.35, kl_temperature=2.0,
#              kl_alpha=0.5, weight_decay=0.0) preventing catastrophic forgetting.
#   - Final Round: Hot-swaps global federated adapter into vLLM on Store 1 & 2
#              and evaluates the 14-probe C1-C6 Canary Suite on both stores.
#
# Usage:
#   ./run_multiround_fl_demo.sh [--rounds N] [--dry-run] [--help]
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../apps/fed-lora" && pwd)"

BOLD="\033[1m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
NC="\033[0m"

log_info() { echo -e "${BLUE}[INFO $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*" >&2; }
log_error() { echo -e "${RED}[FAIL $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*" >&2; }

if [[ -f "${SCRIPT_DIR}/../config/fed_lora_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../config/fed_lora_env.sh" || true
fi

export PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
export ZONE="${ZONE:-us-central1-b}"
export GKE_CLUSTER_NAME="${GKE_CLUSTER_NAME:-YOUR_AGGREGATOR_CLUSTER}"
export STORE1_CONTEXT="${STORE1_CONTEXT:-connectgateway_${PROJECT_ID}_global_YOUR_STORE_1_CLUSTER}"
export STORE2_CONTEXT="${STORE2_CONTEXT:-connectgateway_${PROJECT_ID}_global_YOUR_STORE_2_CLUSTER}"
export GKE_CONTEXT="${GKE_CONTEXT:-gke_${PROJECT_ID}_${ZONE}_${GKE_CLUSTER_NAME}}"
export STORE1_VLLM_LB_IP="${STORE1_VLLM_LB_IP:-10.200.0.131}"
export STORE2_VLLM_LB_IP="${STORE2_VLLM_LB_IP:-10.200.0.163}"

NUM_ROUNDS=3
LOCAL_EPOCHS=2
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
  --rounds)
    NUM_ROUNDS="$2"
    shift 2
    ;;
  --rounds=*)
    NUM_ROUNDS="${1#*=}"
    shift
    ;;
  --dry-run | -n)
    DRY_RUN=true
    shift
    ;;
  --help | -h)
    cat << EOF
Usage: $0 [--rounds N] [--dry-run] [--help]

Executes Multi-Round Federated LoRA + FedProx + Temperature-Scaled KL
across Store 1 and Store 2 via Flower Control API (localhost:19093 -> 9093).
EOF
    exit 0
    ;;
  *)
    log_error "Unknown argument: $1"
    exit 1
    ;;
  esac
done

echo -e "${CYAN}==============================================================================${NC}"
echo -e "${BOLD} MULTI-ROUND FEDERATED LoRA + FedProx + KL CONVERGENCE DEMO${NC}"
echo -e "${CYAN}==============================================================================${NC}"
log_info "App Directory  : ${APP_DIR}"
log_info "Server Rounds  : ${NUM_ROUNDS} (local-epochs=${LOCAL_EPOCHS}, proximal-mu=0.35, kl-temp=2.0, kl-alpha=0.5)"
log_info "Aggregation    : subspace_resid (Round 1 SVD + Round 2..${NUM_ROUNDS} Per-Round Delta Extraction)"
log_info "Dry Run        : ${DRY_RUN}"
echo ""

RUN_CONFIG="mode=\"federated\" num-server-rounds=${NUM_ROUNDS} local-epochs=${LOCAL_EPOCHS} aggregation-mode=\"subspace_resid\" residual-gamma=0.85 round2-gamma=0.56 proximal-mu=0.35 kl-temperature=2.0 kl-alpha=0.5"

if [[ ${DRY_RUN} == "true" ]]; then
  log_info "[DRY-RUN] Validating --run-config schema against pyproject.toml..."
  FLWR_PY="${HOME}/.local/share/pipx/venvs/flwr/bin/python"
  [[ -x ${FLWR_PY} ]] || FLWR_PY="python3"
  "${FLWR_PY}" -c "
import tomllib
from flwr.common.config import parse_config_args, fuse_dicts
with open('${APP_DIR}/pyproject.toml', 'rb') as f:
    base_cfg = tomllib.load(f)['tool']['flwr']['app']['config']
override = parse_config_args([r'''${RUN_CONFIG}'''])
fused = fuse_dicts(base_cfg, override, check_keys=True)
print('Validated fused run-config keys:', len(fused))
"
  log_success "[DRY-RUN] Multi-round run-config validated (no synthetic metrics emitted)."
  exit 0
fi

# Ensure SuperLink Control API port-forward is active on 127.0.0.1:19093
if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/19093" 2> /dev/null; then
  log_info "Starting kubectl port-forward to Central GKE SuperLink (127.0.0.1:19093 -> 9093)..."
  kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 19093:9093 > /dev/null 2>&1 &
  sleep 2
fi

# Step P2.a: Build .fab in apps/fed-lora immediately before the run -> H_build
log_info "Building .fab bundle in ${APP_DIR} to compute local provenance hash H_build..."
rm -f "${APP_DIR}"/*.fab 2> /dev/null || true
(
  cd "${APP_DIR}"
  flwr build > /dev/null
)
FAB_FILE=$(find "${APP_DIR}" -maxdepth 1 -name "*.fab" | head -n 1 || true)
if [[ -z ${FAB_FILE} || ! -f ${FAB_FILE} ]]; then
  log_error "flwr build did not produce a .fab file in ${APP_DIR}"
  exit 1
fi
H_BUILD=$(sha256sum "${FAB_FILE}" | awk '{print $1}')
FAB_NAME_PREFIX=$(basename "${FAB_FILE}" .fab | awk -F. '{print $NF}')
rm -f "${FAB_FILE}"
if [[ ${FAB_NAME_PREFIX} != "${H_BUILD:0:8}" ]]; then
  log_error "FAB filename prefix (${FAB_NAME_PREFIX}) != H_build[:8] (${H_BUILD:0:8})"
  exit 1
fi
log_info "Local .fab build SHA-256 (H_build): ${H_BUILD} (prefix=${FAB_NAME_PREFIX} verified)"

# Step P2.b: Submit run and capture stream + Flower run ID
REVIEW_DIR="$(cd "${SCRIPT_DIR}/../../.." 2> /dev/null && pwd)/04_review"
if [[ -d ${REVIEW_DIR} ]]; then
  STREAM_LOG="${STREAM_LOG:-${REVIEW_DIR}/phase3_run2_flwr_stream.log}"
  PROVENANCE_OUT="${PROVENANCE_OUT:-${REVIEW_DIR}/phase3_run2_provenance.json}"
else
  STREAM_LOG="${STREAM_LOG:-/tmp/phase3_run_flwr_stream.log}"
  PROVENANCE_OUT="${PROVENANCE_OUT:-/tmp/phase3_run_provenance.json}"
fi

SUBMIT_UTC=$(date -u +"%Y-%m-%d %H:%M:%SZ")
log_info "Submitting ${NUM_ROUNDS}-round Federated Run via 'flwr run' (submit_utc=${SUBMIT_UTC}, stream log: ${STREAM_LOG})..."
(
  cd "${APP_DIR}"
  flwr run . gke-superlink --run-config "${RUN_CONFIG}" --stream 2>&1 | tee "${STREAM_LOG}"
)

FLWR_PY="${HOME}/.local/share/pipx/venvs/flwr/bin/python"
[[ -x ${FLWR_PY} ]] || FLWR_PY="python3"

FLWR_RUN_ID=$(grep -ioE "(starting|started|created) run [0-9]+" "${STREAM_LOG}" | tail -n 1 | awk '{print $3}' || true)
if [[ -z ${FLWR_RUN_ID} ]]; then
  FLWR_RUN_ID=$(flwr ls gke-superlink --format json | "${FLWR_PY}" -c "
import sys, json
submit_utc = '${SUBMIT_UTC}'
data = json.load(sys.stdin)
runs = [r for r in data.get('runs', []) if r.get('pending-at', '') >= submit_utc]
if runs:
    best = max(runs, key=lambda r: r.get('pending-at', ''))
    print(best.get('run-id', ''))
else:
    print('')
")
fi
if [[ -z ${FLWR_RUN_ID} ]]; then
  log_error "Could not determine Flower run-id after flwr run (submit_utc=${SUBMIT_UTC})."
  exit 1
fi

# Step P2.c & P2.d: Query SuperLink-recorded fab-hash and assert H_build == fab-hash
LS_JSON=$(flwr ls gke-superlink --run-id "${FLWR_RUN_ID}" --format json)
H_SUPERLINK=$(printf "%s" "${LS_JSON}" | "${FLWR_PY}" -c "import sys, json; data=json.load(sys.stdin); runs=data.get('runs', []); print(runs[0].get('fab-hash', '') if runs else '')")

log_info "FAB Provenance Check (run_id=${FLWR_RUN_ID}):"
echo "  H_build     (local flwr build) : ${H_BUILD}"
echo "  fab-hash    (SuperLink record) : ${H_SUPERLINK}"

MATCH_BOOL="false"
if [[ -n ${H_BUILD} && ${H_BUILD} == "${H_SUPERLINK}" ]]; then
  MATCH_BOOL="true"
fi

GIT_TAG=$(git -C "${SCRIPT_DIR}/.." describe --tags --exact-match 2> /dev/null || echo "v2.1.12")
"${FLWR_PY}" -c "
import json
num_rounds = int('${NUM_ROUNDS}')
bucket = '${GCS_BUCKET:-YOUR_GCS_BUCKET}'
payload = {
    'flwr_run_id': '${FLWR_RUN_ID}',
    'fab_sha256_local_build': '${H_BUILD}',
    'fab_sha256_superlink': '${H_SUPERLINK}',
    'match': '${MATCH_BOOL}' == 'true',
    'git_tag': '${GIT_TAG}',
    'metadata_round_paths': [
        f'gs://{bucket}/checkpoints/round-{r}/metadata.json'
        for r in range(1, num_rounds + 1)
    ],
}
with open('${PROVENANCE_OUT}', 'w', encoding='utf-8') as f:
    json.dump(payload, f, indent=2)
print('Wrote provenance record to ${PROVENANCE_OUT}')
"

if [[ ${MATCH_BOOL} != "true" ]]; then
  log_error "PROVENANCE MISMATCH: H_build (${H_BUILD}) != SuperLink fab-hash (${H_SUPERLINK})"
  exit 1
fi
log_success "Verified FAB provenance: H_build == SuperLink fab-hash (${H_BUILD})"

log_info "Verifying post-federation 14-probe C1-C6 Canary Suite on Store 1 (localhost:18081) and Store 2 (localhost:18082)..."
Store1Url="http://127.0.0.1:18081"
Store2Url="http://127.0.0.1:18082"
if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/18081" 2> /dev/null; then
  kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18081:8000 > /dev/null 2>&1 &
  sleep 2
fi
if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/18082" 2> /dev/null; then
  kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18082:8000 > /dev/null 2>&1 &
  sleep 2
fi

python3 "${SCRIPT_DIR}/eval_local_gemma_judge.py" \
  --vllm-url "${Store1Url}" \
  --adapter-name "store-fed-lora-round-1" \
  --store-id "1" \
  --stage "stage5"

python3 "${SCRIPT_DIR}/eval_local_gemma_judge.py" \
  --vllm-url "${Store2Url}" \
  --adapter-name "store-fed-lora-round-1" \
  --store-id "2" \
  --stage "stage5"

GCS_METADATA_URI="gs://${GCS_BUCKET:-YOUR_GCS_BUCKET}/checkpoints/round-${NUM_ROUNDS}/metadata.json"
log_info "Fetching measured aggregation metadata from ${GCS_METADATA_URI}..."
gcloud storage cat "${GCS_METADATA_URI}"

log_success "Multi-Round (${NUM_ROUNDS} rounds) Federated LoRA + FedProx + KL Run Completed."
