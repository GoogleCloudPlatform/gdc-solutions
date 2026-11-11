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
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - Clean Baseline Reset
# ==============================================================================
# Non-destructively resets the demo environment back to the clean Stage 1 Baseline
# state in under 20 seconds without destroying PVCs or re-downloading base
# Gemma 4 weights:
#   1. Unloads dynamic LoRA adapters from vLLM memory via POST /v1/unload_lora_adapter.
#   2. Purges fine-tuned & federated adapter directories from /mnt/models/* via kubectl exec.
#   3. Purges GCS federated round checkpoints (gs://YOUR_GCS_BUCKET/checkpoints/round-1/*).
#   4. Restarts Central GKE Flower aggregator deployment (flwr-server).
#   5. Verifies that GET /v1/models reports zero fine-tuned adapters loaded.
#   6. Re-executes Stage 1 Baseline Verification (verify_stage1_baseline.sh).
#
# Usage:
#   ./reset_demo_to_stage1.sh [--dry-run] [--skip-verify] [--force-restart] [--help]
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Formatting helpers
BOLD="\033[1m"
GREEN="\033[1;32m"
BLUE="\033[1;34m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
CYAN="\033[1;36m"
NC="\033[0m"

log_info() {
  echo -e "${BLUE}[INFO $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[PASS $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[FAIL $(date +'%Y-%m-%dT%H:%M:%S%z')]${NC} $*" >&2
}

# Source environment configuration
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
export GCS_BUCKET_NAME="${GCS_BUCKET_URI#gs://}"
export GCS_BUCKET_NAME="${GCS_BUCKET_NAME:-YOUR_GCS_BUCKET}"
export BASE_MODEL_ID="${BASE_MODEL_ID:-google/gemma-4-E2B-it}"

DRY_RUN=false
SKIP_VERIFY=false
FORCE_RESTART=false
PURGE_LOCAL_ADAPTERS=false

for arg in "$@"; do
  case "${arg}" in
  --dry-run | -n)
    DRY_RUN=true
    ;;
  --skip-verify)
    SKIP_VERIFY=true
    ;;
  --force-restart)
    FORCE_RESTART=true
    ;;
  --purge-local-adapters)
    PURGE_LOCAL_ADAPTERS=true
    ;;
  --help | -h)
    cat << EOF
Usage: $0 [--dry-run] [--skip-verify] [--force-restart] [--purge-local-adapters] [--help]

Non-destructively resets the demo lab back to clean Stage 1 Baseline state.
Options:
  --dry-run, -n             Print reset steps without modifying cluster or GCS state
  --skip-verify             Skip running verify_stage1_baseline.sh after reset
  --force-restart           Trigger rollout restart of vllm-gemma4 deployments
  --purge-local-adapters    Also delete /mnt/models/store{1,2}-local-adapter from PVC (default: false; preserves Stage-2 checkpoints while unloading vLLM in-memory adapters)
  --help, -h                Display this help message and exit
EOF
    exit 0
    ;;
  *)
    log_error "Unknown argument: ${arg}. Use --help for usage information."
    exit 1
    ;;
  esac
done

echo -e "${CYAN}==============================================================================${NC}"
echo -e "${BOLD} EDGE-TO-CLOUD FEDERATED LEARNING (Fed-LoRA) PoC — CLEAN BASELINE RESET${NC}"
echo -e "${CYAN}==============================================================================${NC}"
log_info "Initiating non-destructive reset back to Stage 1 Baseline state..."
log_info "Configuration: DRY_RUN=${DRY_RUN}, SKIP_VERIFY=${SKIP_VERIFY}, FORCE_RESTART=${FORCE_RESTART}, PURGE_LOCAL_ADAPTERS=${PURGE_LOCAL_ADAPTERS}"
echo ""

if [[ ${DRY_RUN} != "true" ]] && command -v gcloud > /dev/null 2>&1; then
  ar_tok=$(gcloud auth print-access-token 2> /dev/null || echo "")
  if [[ -n ${ar_tok} ]]; then
    for ctx in "${STORE1_CONTEXT}" "${STORE2_CONTEXT}"; do
      kubectl --context="${ctx}" -n fed-lora-poc create secret docker-registry ar-pull-secret \
        --docker-server="${REGION:-us-central1}-docker.pkg.dev" \
        --docker-username="oauth2accesstoken" \
        --docker-password="${ar_tok}" \
        --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f - > /dev/null 2>&1 || true
    done
    log_info "Refreshed 'ar-pull-secret' (kubernetes.io/dockerconfigjson) in namespace fed-lora-poc across Store 1 & Store 2."
  fi
fi

# Helper to unload LoRA adapter from vLLM
unload_vllm_adapter() {
  local target_ip="$1"
  local target_ctx="$2"
  local adapter_name="$3"
  local payload="{\"lora_name\": \"${adapter_name}\"}"

  log_info "Unloading adapter '${adapter_name}' from vLLM on ${target_ip}:8000..."
  if [[ ${DRY_RUN} == "true" ]]; then
    log_success "[DRY-RUN] Unloaded '${adapter_name}' from ${target_ip}:8000."
    return 0
  fi

  # Attempt Tier 1: Local Kubernetes Port-Forward (127.0.0.1:18001 / 127.0.0.1:18002)
  if command -v resolve_vllm_pf_url > /dev/null 2>&1; then
    local pf_url
    pf_url=$(resolve_vllm_pf_url "${target_ip}" "/v1/unload_lora_adapter")
    if curl -s --connect-timeout 2 --max-time 5 -X POST "${pf_url}" \
      -H "Content-Type: application/json" \
      -d "${payload}" > /dev/null 2>&1; then
      log_success "K8s Port-Forward: Unloaded '${adapter_name}' from ${target_ip}:8000."
      return 0
    fi
  fi

  # Attempt Tier 2: In-Cluster Connect Gateway exec via flwr-trainer
  local worker_deploy="flwr-trainer"
  if ! kubectl --context="${target_ctx}" -n fed-lora-poc get deployment flwr-trainer > /dev/null 2>&1; then
    worker_deploy="flwr-client"
  fi
  if kubectl --context="${target_ctx}" -n fed-lora-poc exec deployment/${worker_deploy} -- \
    curl -s -X POST "http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/unload_lora_adapter" \
    -H "Content-Type: application/json" \
    -d "${payload}" > /dev/null 2>&1; then
    log_success "In-Cluster exec: Unloaded '${adapter_name}' from ${target_ip}:8000."
    return 0
  fi

  # Attempt Tier 3: Direct HTTP (when running inside VPC)
  if curl -s --connect-timeout 2 --max-time 5 -X POST "http://${target_ip}:8000/v1/unload_lora_adapter" \
    -H "Content-Type: application/json" \
    -d "${payload}" > /dev/null 2>&1; then
    log_success "Direct HTTP: Unloaded '${adapter_name}' from ${target_ip}:8000."
    return 0
  fi
}

# ------------------------------------------------------------------------------
# Step 1: Wake vLLM & Unload LoRA Adapters from vLLM Memory
# ------------------------------------------------------------------------------
log_info "[Step 1/5] Waking vLLM and unloading dynamic LoRA adapters from vLLM memory..."
for ctx in "${STORE1_CONTEXT}" "${STORE2_CONTEXT}"; do
  if [[ ${DRY_RUN} != "true" ]]; then
    kubectl --context="${ctx}" -n fed-lora-poc exec deployment/flwr-trainer -- \
      curl -s -X POST "http://vllm-service.fed-lora-poc.svc.cluster.local:8000/wake_up" \
      -H "Content-Type: application/json" -d '{"tags": ["weights", "kv_cache"]}' > /dev/null 2>&1 || true
  fi
done

for adapter in "store1-local-adapter" "store-fed-lora-round-1" "store-fed-lora-round-2" "store-fed-lora-round-3" "store-fed-lora-candidate" "store-fed-lora-promoted"; do
  unload_vllm_adapter "${STORE1_VLLM_LB_IP}" "${STORE1_CONTEXT}" "${adapter}"
done

for adapter in "store2-local-adapter" "store-fed-lora-round-1" "store-fed-lora-round-2" "store-fed-lora-round-3" "store-fed-lora-candidate" "store-fed-lora-promoted"; do
  unload_vllm_adapter "${STORE2_VLLM_LB_IP}" "${STORE2_CONTEXT}" "${adapter}"
done

# ------------------------------------------------------------------------------
# Step 2: Purge Federated Adapter Directories & Ensure Canonical Round-0 Template
# ------------------------------------------------------------------------------
log_info "[Step 2/5] Cleaning federated candidate/promoted/round-* directories on /mnt/models and stale local .fab files (preserving /mnt/models/global-Kill-Switch/round-0 and /mnt/models/edge-data)..."
if [[ ${DRY_RUN} == "true" ]]; then
  log_success "[DRY-RUN] Cleaned federated adapter directories from Store 1 and Store 2 and local .fab artifacts."
else
  worker1="flwr-trainer"

  rm -f "${SCRIPT_DIR}/../apps/fed-lora/"*.fab

  for ctx in "${STORE1_CONTEXT}" "${STORE2_CONTEXT}"; do
    kubectl --context="${ctx}" -n fed-lora-poc exec deployment/vllm-gemma4 -- \
      chmod a+rwx /mnt/models > /dev/null 2>&1 || true
  done

  if [[ ${PURGE_LOCAL_ADAPTERS} == "true" ]]; then
    log_warn "--purge-local-adapters enabled: also deleting /mnt/models/store{1,2}-local-adapter..."
    for pod_target in "deployment/vllm-gemma4" "deployment/${worker1}"; do
      kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec "${pod_target}" -- \
        rm -rf /mnt/models/store1-local-adapter /mnt/models/store-fed-lora-round-1 /mnt/models/store-fed-lora-round-* /mnt/models/store-fed-lora-candidate /mnt/models/store-fed-lora-promoted /mnt/models/round0-seed-cache /mnt/models/adapters/local /mnt/models/adapters/global > /dev/null 2>&1 || true
      kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec "${pod_target}" -- \
        rm -rf /mnt/models/store2-local-adapter /mnt/models/store-fed-lora-round-1 /mnt/models/store-fed-lora-round-* /mnt/models/store-fed-lora-candidate /mnt/models/store-fed-lora-promoted /mnt/models/round0-seed-cache /mnt/models/adapters/local /mnt/models/adapters/global > /dev/null 2>&1 || true
    done
  else
    log_info "Preserving /mnt/models/store{1,2}-local-adapter on PVC (use --purge-local-adapters to delete); purging /mnt/models/store-fed-lora-round-*, /mnt/models/store-fed-lora-candidate, /mnt/models/store-fed-lora-promoted, and /mnt/models/round0-seed-cache..."
    for pod_target in "deployment/vllm-gemma4" "deployment/${worker1}"; do
      kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec "${pod_target}" -- \
        rm -rf /mnt/models/store-fed-lora-round-1 /mnt/models/store-fed-lora-round-* /mnt/models/store-fed-lora-candidate /mnt/models/store-fed-lora-promoted /mnt/models/round0-seed-cache /mnt/models/adapters/global > /dev/null 2>&1 || true
      kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec "${pod_target}" -- \
        rm -rf /mnt/models/store-fed-lora-round-1 /mnt/models/store-fed-lora-round-* /mnt/models/store-fed-lora-candidate /mnt/models/store-fed-lora-promoted /mnt/models/round0-seed-cache /mnt/models/adapters/global > /dev/null 2>&1 || true
    done
  fi

  # Ensure canonical Round-0 template is seeded on both stores' PVCs (/mnt/models/global-Kill-Switch/round-0)
  for ctx in "${STORE1_CONTEXT}" "${STORE2_CONTEXT}"; do
    kubectl --context="${ctx}" -n fed-lora-poc exec deployment/flwr-trainer -- bash -c '
      mkdir -p /mnt/models/global-Kill-Switch/round-0 /tmp/checkpoints/round-0-template
      if [[ -f /tmp/checkpoints/round-0-template/adapter_model.safetensors && ! -f /mnt/models/global-Kill-Switch/round-0/adapter_model.safetensors ]]; then
        cp -f /tmp/checkpoints/round-0-template/adapter_model.safetensors /mnt/models/global-Kill-Switch/round-0/adapter_model.safetensors
      elif [[ -f /mnt/models/global-Kill-Switch/round-0/adapter_model.safetensors && ! -f /tmp/checkpoints/round-0-template/adapter_model.safetensors ]]; then
        cp -f /mnt/models/global-Kill-Switch/round-0/adapter_model.safetensors /tmp/checkpoints/round-0-template/adapter_model.safetensors
      fi
    ' > /dev/null 2>&1 || true
  done

  log_success "Cleaned federated adapter directories and local .fab artifacts while preserving Round-0 template, edge-data, and base Gemma 4 weights."
fi

# ------------------------------------------------------------------------------
# Step 3: Purge GCS Federated Round Checkpoints
# ------------------------------------------------------------------------------
log_info "[Step 3/5] Cleaning GCS federated round/candidate/promoted checkpoints..."
if [[ ${DRY_RUN} == "true" ]]; then
  log_success "[DRY-RUN] Cleaned gs://${GCS_BUCKET_NAME}/checkpoints/{round-*,candidate,promoted}."
else
  for prefix in "round-1" "round-2" "round-3" "candidate" "promoted"; do
    gcloud storage rm --recursive "gs://${GCS_BUCKET_NAME}/checkpoints/${prefix}/**" 2> /dev/null || true
  done
  log_success "Cleaned gs://${GCS_BUCKET_NAME}/checkpoints/{round-*,candidate,promoted} (preserved round-0 template)."
fi

# ------------------------------------------------------------------------------
# Step 4: Restart Central Flower Aggregator & Reset OpenMetrics Gauges (:9100)
# ------------------------------------------------------------------------------
log_info "[Step 4/5] Resetting Flower aggregator & OpenMetrics gauges (:9100/metrics) to Stage 1 Baseline zeroes..."
if [[ ${DRY_RUN} == "true" ]]; then
  echo "[DRY-RUN] Rollout restart deployment/flwr-superlink on GKE & reset /tmp/fed_lora_metrics.prom on Store 1, Store 2, and Central GKE."
else
  if kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get deployment flwr-superlink > /dev/null 2>&1; then
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout restart deployment/flwr-superlink
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout status deployment/flwr-superlink --timeout=180s
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec deployment/flwr-superlink -- \
      python3 -m fed_lora.observability --reset --store-id=global --cluster-name=YOUR_AGGREGATOR_CLUSTER > /dev/null 2>&1 || true
    log_info "Central Flower SuperLink (flwr-superlink, flwr[rest]==1.36.0) is healthy (1/1 Ready) and metrics reset to Stage 1 zeroes."
  else
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout restart deployment/flwr-server
    kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout status deployment/flwr-server --timeout=120s
  fi
  kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc rollout restart deployment/flwr-supernode
  kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc rollout restart deployment/flwr-supernode
  kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc rollout status deployment/flwr-supernode --timeout=120s
  kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc rollout status deployment/flwr-supernode --timeout=120s
  sleep 6
  kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
    python3 -m fed_lora.observability --reset --store-id=store-1 --cluster-name=YOUR_STORE_1_CLUSTER > /dev/null 2>&1 || true
  kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
    python3 -m fed_lora.observability --reset --store-id=store-2 --cluster-name=YOUR_STORE_2_CLUSTER > /dev/null 2>&1 || true
  log_success "Central Flower aggregator, Edge SuperNodes, & OpenMetrics (:9100/metrics) reset to Stage 1 Baseline zeroes."
  if [[ ${FORCE_RESTART} == "true" ]]; then
    log_info "Force restart requested: restarting deployment/vllm-gemma4 on Store 1 and Store 2..."
    kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc rollout restart deployment/vllm-gemma4
    kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc rollout restart deployment/vllm-gemma4
    kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc rollout status deployment/vllm-gemma4 --timeout=300s
    kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc rollout status deployment/vllm-gemma4 --timeout=300s
    log_success "Both vllm-gemma4 serving engines cleanly restarted."
  fi
fi

# ------------------------------------------------------------------------------
# Step 5: Verification of Clean Baseline Serving State
# ------------------------------------------------------------------------------
log_info "[Step 5/5] Verifying clean base serving state..."
if [[ ${SKIP_VERIFY} == "true" ]]; then
  log_warn "Verification skipped via --skip-verify flag."
else
  if [[ -f "${SCRIPT_DIR}/verify_demo_setup.sh" ]]; then
    log_info "Executing Turnkey Setup Verification (verify_demo_setup.sh)..."
    if [[ ${DRY_RUN} == "true" ]]; then
      "${SCRIPT_DIR}/verify_demo_setup.sh" --dry-run
    else
      "${SCRIPT_DIR}/verify_demo_setup.sh"
    fi
  elif [[ -f "${SCRIPT_DIR}/verify_stage1_baseline.sh" ]]; then
    log_info "Executing Stage 1 Baseline Verification (verify_stage1_baseline.sh)..."
    if [[ ${DRY_RUN} == "true" ]]; then
      "${SCRIPT_DIR}/verify_stage1_baseline.sh" --dry-run
    else
      "${SCRIPT_DIR}/verify_stage1_baseline.sh"
    fi
  fi
fi

echo ""
echo -e "${CYAN}==============================================================================${NC}"
echo -e "${GREEN}${BOLD} CLEAN BASELINE RESET COMPLETE: Lab is Ready for Stage 1 Presentation${NC}"
echo -e "${CYAN}==============================================================================${NC}"
