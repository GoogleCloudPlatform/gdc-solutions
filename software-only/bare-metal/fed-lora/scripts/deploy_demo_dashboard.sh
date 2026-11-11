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
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - Cloud Monitoring Dashboard Deployer
# ==============================================================================
# Idempotently creates or updates the 4-Quadrant Google Cloud Monitoring Live
# Demo Dashboard (`GDC Software-Only Federated LoRA (FedLoRA) Live Demo Dashboard (v2.1.13)`)
# in `YOUR_PROJECT_ID` from `config/monitoring/fed-lora-demo-dashboard.json`.
#
# Usage:
#   ./scripts/deploy_demo_dashboard.sh [--project PROJECT_ID] [--dry-run]
# ==============================================================================

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_JSON="${SCRIPT_DIR}/../config/monitoring/fed-lora-demo-dashboard.json"
PROJECT_ID="${GCP_PROJECT_ID:-YOUR_PROJECT_ID}"
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
  --project=*)
    PROJECT_ID="${arg#*=}"
    ;;
  --dry-run | -n)
    DRY_RUN=true
    ;;
  --help | -h)
    echo "Usage: $0 [--project=PROJECT_ID] [--dry-run]"
    exit 0
    ;;
  esac
done

if [[ ! -f ${DASHBOARD_JSON} ]]; then
  echo "[FAIL] Dashboard specification not found: ${DASHBOARD_JSON}" >&2
  exit 1
fi

DISPLAY_NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["displayName"])' "${DASHBOARD_JSON}")
echo "[INFO] Validated JSON schema for: '${DISPLAY_NAME}' (${DASHBOARD_JSON})"

if [[ ${DRY_RUN} == "true" ]]; then
  echo "[DRY-RUN] Would create/update Cloud Monitoring Dashboard '${DISPLAY_NAME}' in project '${PROJECT_ID}'."
  exit 0
fi

EXISTING_ID=$(gcloud monitoring dashboards list \
  --project="${PROJECT_ID}" \
  --filter="displayName=\"${DISPLAY_NAME}\"" \
  --format="value(name)" 2> /dev/null | head -n 1 || true)

if [[ -n ${EXISTING_ID} ]]; then
  ETAG=$(gcloud monitoring dashboards describe "${EXISTING_ID}" \
    --project="${PROJECT_ID}" \
    --format="value(etag)" 2> /dev/null || true)
  TMP_JSON="$(mktemp /tmp/fed-lora-dashboard-XXXXXX.json)"
  python3 - "${DASHBOARD_JSON}" "${ETAG}" "${TMP_JSON}" << 'PYEOF'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
if sys.argv[2]:
    data["etag"] = sys.argv[2]
with open(sys.argv[3], "w", encoding="utf-8") as out:
    json.dump(data, out, indent=2)
PYEOF
  gcloud monitoring dashboards update "${EXISTING_ID}" \
    --project="${PROJECT_ID}" \
    --config-from-file="${TMP_JSON}" > /dev/null
  rm -f "${TMP_JSON}"
  echo "[PASS] Updated existing Cloud Monitoring Dashboard: ${EXISTING_ID}"
else
  CREATED_ID=$(gcloud monitoring dashboards create \
    --project="${PROJECT_ID}" \
    --config-from-file="${DASHBOARD_JSON}" \
    --format="value(name)")
  EXISTING_ID="${CREATED_ID}"
  echo "[PASS] Created new Cloud Monitoring Dashboard: ${EXISTING_ID}"
fi

DASHBOARD_SHORT_ID="${EXISTING_ID##*/}"
echo "[PASS] Console URL: https://console.cloud.google.com/monitoring/dashboards/custom/${DASHBOARD_SHORT_ID}?project=${PROJECT_ID}"
