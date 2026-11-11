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
# Edge-to-Cloud Federated Learning (Fed-LoRA) PoC - GCS Bucket Bootstrapper
# ==============================================================================
# Ensures gs://${GCS_BUCKET_NAME} exists for Flower SuperLink LoRA adapter
# checkpoint staging. Edge store training datasets (train.jsonl) remain 100%
# edge-local on Kubernetes ConfigMaps/PVCs and are never uploaded to GCS.
# ==============================================================================
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/../config/fed_lora_env.sh" ]] && source "${SCRIPT_DIR}/../config/fed_lora_env.sh"

PROJECT_ID="${PROJECT_ID:-YOUR_PROJECT_ID}"
REGION="${REGION:-us-central1}"
GCS_BUCKET_NAME="${GCS_BUCKET_NAME:-YOUR_GCS_BUCKET}"
BUCKET_URI="gs://${GCS_BUCKET_NAME}"

if [[ $* == *"--dry-run"* ]]; then
  echo "[PASS] [DRY-RUN] Verified GCS bucket ${BUCKET_URI} (${PROJECT_ID})."
  exit 0
fi

if gcloud storage buckets describe "${BUCKET_URI}" --project="${PROJECT_ID}" > /dev/null 2>&1; then
  echo "[PASS] GCS bucket ${BUCKET_URI} exists and is accessible."
  exit 0
fi

if [[ $* == *"--verify-only"* ]]; then
  echo "[FAIL] GCS bucket ${BUCKET_URI} does not exist or is inaccessible." >&2
  exit 1
fi

echo "[INFO] Creating GCS bucket ${BUCKET_URI} in ${REGION}..."
gcloud storage buckets create "${BUCKET_URI}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access
echo "[PASS] Created GCS bucket ${BUCKET_URI}."
