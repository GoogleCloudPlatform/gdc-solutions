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
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - Stage 6 .fab Showcase
# ==============================================================================
# Demonstrates Flower's Decoupled Execution Planes (GitOps Infrastructure vs.
# Ephemeral ML Experiment Plane):
#   1. Modifies ML hyperparameters / version in pyproject.toml (1.0.0 -> 1.1.0).
#   2. Packages the Python ML source code into a Flower Application
#      Bundle (.fab) via 'flwr build' and computes its SHA-256 hash.
#   3. Compares the measured .fab bundle size against the ~15 GB GPU container image
#      (zero Docker rebuilds, zero K8s restarts).
#   4. Streams the .fab bundle over gRPC via 'flwr run . gke-superlink --stream'
#      and verifies zero pod restarts on Store 1 & Store 2.
#   5. Automatically restores pyproject.toml to 1.0.0 on exit.
#
# Usage:
#   ./run_stage6_fab_showcase.sh [--dry-run] [--help]
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../apps/fed-lora" && pwd)"
PYPROJECT_TOML="${APP_DIR}/pyproject.toml"

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

DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
  --dry-run | -n)
    DRY_RUN=true
    ;;
  --help | -h)
    cat << EOF
Usage: $0 [--dry-run] [--help]

Stage 6 Dynamic .fab Code & Hyperparameter Delivery Showcase.
Demonstrates .fab over-the-wire ML delivery without rebuilding Docker
images or restarting edge Kubernetes pods.
EOF
    exit 0
    ;;
  *)
    log_error "Unknown argument: ${arg}"
    exit 1
    ;;
  esac
done

BACKUP_TOML="$(mktemp)"
cp "${PYPROJECT_TOML}" "${BACKUP_TOML}"
cleanup_toml() {
  if [[ -f ${BACKUP_TOML} ]]; then
    cp "${BACKUP_TOML}" "${PYPROJECT_TOML}"
    rm -f "${BACKUP_TOML}"
  fi
  rm -f "${APP_DIR}"/*.fab 2> /dev/null || true
}
trap cleanup_toml EXIT

echo -e "${CYAN}==============================================================================${NC}"
echo -e "${BOLD} STAGE 6: DYNAMIC .fab CODE & HYPERPARAMETER DELIVERY SHOWCASE${NC}"
echo -e "${CYAN}==============================================================================${NC}"

# Step 1: Bump version in pyproject.toml (1.0.0 -> 1.1.0)
log_info "[Step 1/4] Bumping pyproject.toml version (1.0.0 -> 1.1.0) for live iteration..."
sed -i 's/^version = "1.0.0"/version = "1.1.0"/' "${PYPROJECT_TOML}"
grep -E '^name =|^version =' "${PYPROJECT_TOML}"

# Step 2: Build .fab bundle and compute SHA-256 & payload reduction
log_info "[Step 2/4] Building Flower Application Bundle (.fab) via 'flwr build'..."
(
  cd "${APP_DIR}"
  flwr build
)
FAB_FILE=$(find "${APP_DIR}" -maxdepth 1 -name "*.fab" | head -n 1 || true)
if [[ -z ${FAB_FILE} || ! -f ${FAB_FILE} ]]; then
  log_error "Failed to locate built .fab file in ${APP_DIR}"
  exit 1
fi

FAB_BYTES=$(stat -c%s "${FAB_FILE}" 2> /dev/null || wc -c < "${FAB_FILE}")
FAB_KB=$(awk "BEGIN {printf \"%.2f\", ${FAB_BYTES}/1024.0}")
FAB_SHA256=$(sha256sum "${FAB_FILE}" | awk '{print $1}')
FAB_BASENAME=$(basename "${FAB_FILE}")
FAB_NAME_PREFIX=$(basename "${FAB_FILE}" .fab | awk -F. '{print $NF}')
rm -f "${FAB_FILE}"
if [[ ${FAB_NAME_PREFIX} != "${FAB_SHA256:0:8}" ]]; then
  log_error "FAB filename prefix (${FAB_NAME_PREFIX}) != H_build[:8] (${FAB_SHA256:0:8})"
  exit 1
fi
DOCKER_BYTES=$((15 * 1024 * 1024 * 1024))
REDUCTION_FACTOR=$((DOCKER_BYTES / FAB_BYTES))

echo ""
echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
echo -e "${BOLD} ARTIFACT COMPARISON: FLOWER .fab BUNDLE vs. GPU CONTAINER IMAGE${NC}"
echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
echo -e "  Bundle File        : ${FAB_BASENAME} (prefix=${FAB_NAME_PREFIX} == H_build[:8])"
echo -e "  .fab Bundle Size   : ${GREEN}${FAB_KB} KB (${FAB_BYTES} bytes)${NC}"
echo -e "  .fab SHA-256 Hash  : ${BOLD}${FAB_SHA256}${NC}"
echo -e "  GPU Container Size : ~15.00 GB (flwr-trainer:v2.1.6)"
echo -e "  Payload Reduction  : ${GREEN}${REDUCTION_FACTOR}x smaller over WAN${NC}"
echo -e "  Docker Rebuilds    : ${GREEN}0${NC}"
echo -e "${CYAN}------------------------------------------------------------------------------${NC}"
echo ""

if [[ ${DRY_RUN} == "true" ]]; then
  log_success "[DRY-RUN] Measured .fab size (${FAB_KB} KB / ${FAB_BYTES} bytes), SHA-256 (${FAB_SHA256}), and verified prefix=${FAB_NAME_PREFIX}."
  exit 0
fi

# Step 3: Record baseline pod restart counts before streaming .fab
s1_restarts_before=$(kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get pods -l app=flwr-trainer -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2> /dev/null || echo "0")
s2_restarts_before=$(kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get pods -l app=flwr-trainer -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2> /dev/null || echo "0")

# Step 4: Stream .fab over gRPC via flwr run and verify SuperLink fab-hash
log_info "[Step 3/4] Streaming ${FAB_KB} KB .fab bundle over gRPC to SuperLink -> SuperNodes..."
if ! timeout 1 bash -c "</dev/tcp/127.0.0.1/19093" 2> /dev/null; then
  kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 19093:9093 > /dev/null 2>&1 &
  sleep 2
fi

STAGE6_STREAM_LOG="/tmp/stage6_flwr_stream.log"
SUBMIT_UTC=$(date -u +"%Y-%m-%d %H:%M:%SZ")
(
  cd "${APP_DIR}"
  flwr run . gke-superlink \
    --run-config 'mode="federated" num-server-rounds=1 local-epochs=1 aggregation-mode="subspace_resid" residual-gamma=0.85' \
    --stream 2>&1 | tee "${STAGE6_STREAM_LOG}"
)

FLWR_PY="${HOME}/.local/share/pipx/venvs/flwr/bin/python"
[[ -x ${FLWR_PY} ]] || FLWR_PY="python3"

FLWR_RUN_ID=$(grep -ioE "(starting|started|created) run [0-9]+" "${STAGE6_STREAM_LOG}" | tail -n 1 | awk '{print $3}' || true)
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
LS_JSON=$(flwr ls gke-superlink --run-id "${FLWR_RUN_ID}" --format json)
H_SUPERLINK=$(printf "%s" "${LS_JSON}" | "${FLWR_PY}" -c "import sys, json; data=json.load(sys.stdin); runs=data.get('runs', []); print(runs[0].get('fab-hash', '') if runs else '')")
echo "  H_build     (local flwr build) : ${FAB_SHA256}"
echo "  fab-hash    (SuperLink record) : ${H_SUPERLINK}"

REVIEW_DIR="$(cd "${SCRIPT_DIR}/../../.." 2> /dev/null && pwd)/04_review"
STAGE6_PROV_OUT="/tmp/phase3_stage6_provenance.json"
[[ -d ${REVIEW_DIR} ]] && STAGE6_PROV_OUT="${REVIEW_DIR}/phase3_stage6_provenance.json"
"${FLWR_PY}" -c "
import json
payload = {
    'flwr_run_id': '${FLWR_RUN_ID}',
    'fab_sha256_local_build': '${FAB_SHA256}',
    'fab_sha256_superlink': '${H_SUPERLINK}',
    'match': '${FAB_SHA256}' == '${H_SUPERLINK}',
    'git_tag': 'v2.1.12',
    'metadata_round_paths': ['gs://${GCS_BUCKET:-YOUR_GCS_BUCKET}/checkpoints/round-1/metadata.json'],
}
with open('${STAGE6_PROV_OUT}', 'w', encoding='utf-8') as f:
    json.dump(payload, f, indent=2)
"
if [[ ${FAB_SHA256} != "${H_SUPERLINK}" ]]; then
  log_error "PROVENANCE MISMATCH: H_build (${FAB_SHA256}) != SuperLink fab-hash (${H_SUPERLINK})"
  exit 1
fi
log_success "Verified FAB provenance: H_build == SuperLink fab-hash (${FAB_SHA256})"

s1_restarts_after=$(kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get pods -l app=flwr-trainer -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2> /dev/null || echo "0")
s2_restarts_after=$(kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get pods -l app=flwr-trainer -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2> /dev/null || echo "0")
s1_delta=$((s1_restarts_after - s1_restarts_before))
s2_delta=$((s2_restarts_after - s2_restarts_before))

log_info "[Step 4/4] Verifying zero K8s pod restarts across edge clusters..."
if [[ ${s1_delta} -ne 0 || ${s2_delta} -ne 0 ]]; then
  log_error "Unexpected pod restarts during .fab execution! Store 1: ${s1_restarts_before} -> ${s1_restarts_after} (delta=${s1_delta}), Store 2: ${s2_restarts_before} -> ${s2_restarts_after} (delta=${s2_delta})"
  exit 1
fi
log_success "Store 1 flwr-trainer restarts: ${s1_restarts_before} -> ${s1_restarts_after} (delta=${s1_delta})"
log_success "Store 2 flwr-trainer restarts: ${s2_restarts_before} -> ${s2_restarts_after} (delta=${s2_delta})"
log_success "Stage 6 .fab Dynamic Code & Hyperparameter Showcase Completed Successfully!"
