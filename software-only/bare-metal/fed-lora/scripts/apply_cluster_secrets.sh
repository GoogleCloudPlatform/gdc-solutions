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
# Unified GDC Software-Only Cluster Secrets Provisioner (apply_cluster_secrets.sh)
# ==============================================================================
# Reads secret keys/tokens from the local `.env` file (via fed_lora_env.sh) and
# Fleet Workload Identity (STS token exchange) to create/update Kubernetes
# Secrets across GDC Software-Only edge clusters (YOUR_STORE_1_CLUSTER, YOUR_STORE_2_CLUSTER):
#   1. fed-lora-poc/hf-token-secret (from HF_TOKEN in .env)
#   2. fed-lora-poc/ar-pull-secret  (from AR_READER_KEY_FILE or Fleet Workload Identity;
#                                    kept fresh in-cluster every 30m by CronJob/ar-pull-refresher)
#   3. Cleans up unused config-management-system/git-creds because
#      RootSyncs authenticate via OCI (auth: k8sserviceaccount).
#
# Prerequisites: kubectl, curl, jq
# ==============================================================================
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/../config/fed_lora_env.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/../config/fed_lora_env.sh"
fi

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
STORE1_MEMBERSHIP="${STORE1_CLUSTER_NAME:-YOUR_STORE_1_CLUSTER}"
STORE2_MEMBERSHIP="${STORE2_CLUSTER_NAME:-YOUR_STORE_2_CLUSTER}"
DOCKER_SERVER="${REGION:-us-central1}-docker.pkg.dev"
DRY_RUN=false
ALLOW_SHORT_LIVED_TOKEN=false

for arg in "$@"; do
  case "${arg}" in
  --dry-run)
    DRY_RUN=true
    ;;
  --allow-short-lived-token)
    ALLOW_SHORT_LIVED_TOKEN=true
    ;;
  --help | -h)
    echo "Usage: $0 [--dry-run] [--allow-short-lived-token]"
    echo "  Provisions fed-lora-poc/hf-token-secret and fed-lora-poc/ar-pull-secret across Store 1 and Store 2."
    echo "  Requires: kubectl, curl, jq"
    exit 0
    ;;
  esac
done

mint_fleet_wi_ar_token() {
  local ctx="$1"
  local membership="$2"
  local ksa_jwt sts_resp sts_token

  ksa_jwt=$(kubectl --context="${ctx}" -n fed-lora-poc create token ar-pull-refresher \
    --audience="${PROJECT_ID}.svc.id.goog" 2> /dev/null ||
    kubectl --context="${ctx}" -n fed-lora-poc create token default \
      --audience="${PROJECT_ID}.svc.id.goog" 2> /dev/null || echo "")
  if [[ -z ${ksa_jwt} ]]; then
    return 1
  fi

  sts_resp=$(curl -sS -X POST "https://sts.googleapis.com/v1/token" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg aud "identitynamespace:${PROJECT_ID}.svc.id.goog:https://gkehub.googleapis.com/projects/${PROJECT_ID}/locations/global/memberships/${membership}" \
      --arg tok "${ksa_jwt}" \
      '{
        audience: $aud,
        grantType: "urn:ietf:params:oauth:grant-type:token-exchange",
        requestedTokenType: "urn:ietf:params:oauth:token-type:access_token",
        scope: "https://www.googleapis.com/auth/cloud-platform",
        subjectTokenType: "urn:ietf:params:oauth:token-type:jwt",
        subjectToken: $tok
      }')" 2> /dev/null || echo "")

  sts_token=$(echo "${sts_resp}" | jq -r '.access_token // empty' 2> /dev/null || echo "")
  if [[ -z ${sts_token} ]]; then
    return 1
  fi

  echo "${sts_token}"
  return 0
}

provision_cluster_secrets() {
  local ctx="$1"
  local label="$2"
  local membership="$3"

  echo "[INFO] (${label}) Provisioning cluster secrets on context '${ctx}'..."

  if [[ ${DRY_RUN} == "true" ]]; then
    echo "  [DRY-RUN] Would create/update fed-lora-poc/hf-token-secret"
    echo "  [DRY-RUN] Would create/update fed-lora-poc/ar-pull-secret (${DOCKER_SERVER})"
    echo "  [DRY-RUN] Would delete unused config-management-system/git-creds"
    return 0
  fi

  kubectl --context="${ctx}" get namespace fed-lora-poc > /dev/null 2>&1 ||
    kubectl --context="${ctx}" create namespace fed-lora-poc > /dev/null
  kubectl --context="${ctx}" annotate namespace fed-lora-poc kubectl.kubernetes.io/last-applied-configuration- > /dev/null 2>&1 || true

  # 1. Hugging Face Model Gate Token (fed-lora-poc/hf-token-secret)
  if [[ -n ${HF_TOKEN:-} ]]; then
    kubectl --context="${ctx}" -n fed-lora-poc create secret generic hf-token-secret \
      --from-literal=HF_TOKEN="${HF_TOKEN}" \
      --from-literal=token="${HF_TOKEN}" \
      --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
    echo "  [OK] (${label}) Applied fed-lora-poc/hf-token-secret from .env HF_TOKEN."
  else
    echo "  [WARN] (${label}) HF_TOKEN is not set in .env; preserving existing hf-token-secret."
  fi

  # 2. Artifact Registry Pull Secret (fed-lora-poc/ar-pull-secret)
  local wi_token=""
  if [[ -n ${AR_READER_KEY_FILE:-} && -f ${AR_READER_KEY_FILE} ]]; then
    kubectl --context="${ctx}" -n fed-lora-poc create secret docker-registry ar-pull-secret \
      --docker-server="${DOCKER_SERVER}" \
      --docker-username="_json_key" \
      --docker-password="$(cat "${AR_READER_KEY_FILE}")" \
      --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
    echo "  [OK] (${label}) Applied fed-lora-poc/ar-pull-secret using service account key (${AR_READER_KEY_FILE})."
  elif wi_token="$(mint_fleet_wi_ar_token "${ctx}" "${membership}" 2> /dev/null)" && [[ -n ${wi_token} ]]; then
    kubectl --context="${ctx}" -n fed-lora-poc create secret docker-registry ar-pull-secret \
      --docker-server="${DOCKER_SERVER}" \
      --docker-username="oauth2accesstoken" \
      --docker-password="${wi_token}" \
      --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
    echo "  [OK] (${label}) Applied fed-lora-poc/ar-pull-secret via direct Fleet Workload Identity STS token (auto-refreshed every 30m by CronJob/ar-pull-refresher)."
  elif [[ ${ALLOW_SHORT_LIVED_TOKEN} == "true" ]]; then
    local ar_token expiry_utc
    ar_token="${AR_PULL_TOKEN:-$(gcloud auth print-access-token 2> /dev/null || echo "")}"
    if [[ -z ${ar_token} ]]; then
      echo "  [ERROR] (${label}) Failed to obtain OAuth token for ar-pull-secret." >&2
      return 1
    fi
    expiry_utc=$(date -u -d '+60 minutes' '+%Y-%m-%dT%H:%M:%SZ' 2> /dev/null || echo "in 60 minutes")
    echo "  [WARNING] (${label}) Using short-lived OAuth token (--allow-short-lived-token); expires at ${expiry_utc}!" >&2
    kubectl --context="${ctx}" -n fed-lora-poc create secret docker-registry ar-pull-secret \
      --docker-server="${DOCKER_SERVER}" \
      --docker-username="oauth2accesstoken" \
      --docker-password="${ar_token}" \
      --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -
  else
    echo "  [ERROR] (${label}) Neither AR_READER_KEY_FILE nor Fleet Workload Identity token exchange succeeded. Refusing silent fallback to personal OAuth token (pass --allow-short-lived-token to override)." >&2
    return 1
  fi

  # 3. Remove unused git-creds from config-management-system (RootSync uses OCI auth: k8sserviceaccount)
  kubectl --context="${ctx}" -n config-management-system delete secret git-creds --ignore-not-found=true > /dev/null
  echo "  [OK] (${label}) Verified cleanup of unused config-management-system/git-creds (RootSync uses OCI)."
}

provision_cluster_secrets "${STORE1_CONTEXT}" "Store 1 (${STORE1_MEMBERSHIP})" "${STORE1_MEMBERSHIP}"
provision_cluster_secrets "${STORE2_CONTEXT}" "Store 2 (${STORE2_MEMBERSHIP})" "${STORE2_MEMBERSHIP}"

echo "[SUCCESS] GDC Software-Only cluster secrets provisioned across Store 1 and Store 2."
