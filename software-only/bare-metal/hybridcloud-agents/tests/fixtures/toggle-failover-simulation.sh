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

# Test-only helper to toggle `allow_failover_simulation` in the Apigee
# `hybrid_agents_env` environment PropertySet (`true` or `false`).
# Production deployments default to `allow_failover_simulation=false` in
# `apigee/environments/env-config.json`, so caller-supplied
# `x-simulate-cloud-burst-status: 503` headers are ignored unless an operator
# explicitly enables this test overlay for a verification window.

set -o errexit
set -o nounset
set -o pipefail

if [[ $# -ne 1 || ("$1" != "true" && "$1" != "false") ]]; then
  echo "Usage: PROJECT_ID=<id> [APIGEE_ENV=hybrid-agents-env] $0 <true|false>" >&2
  exit 2
fi

DESIRED="$1"
PROJECT_ID="${PROJECT_ID:-}"
APIGEE_ENV="${APIGEE_ENV:-hybrid-agents-env}"
if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: Set PROJECT_ID before running $0." >&2
  exit 1
fi

TOKEN="$(gcloud auth print-access-token --quiet)"
URL="https://apigee.googleapis.com/v1/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/resourcefiles/properties/hybrid_agents_env"

CURRENT="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" "${URL}")"
UPDATED="$(CURRENT_PROPS="${CURRENT}" python3 - "${DESIRED}" << 'PY'
import os
import sys

desired = sys.argv[1]
lines = [l for l in os.environ["CURRENT_PROPS"].splitlines() if l.strip()]
out = []
found = False
for line in lines:
  if line.startswith("allow_failover_simulation="):
    out.append(f"allow_failover_simulation={desired}")
    found = True
  else:
    out.append(line)
if not found:
  out.append(f"allow_failover_simulation={desired}")
out.sort()
print("\n".join(out))
PY
)"

printf '%s\n' "${UPDATED}" | curl -fsSL -X PUT \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @- \
  "${URL}" > /dev/null

echo "Set hybrid_agents_env.allow_failover_simulation=${DESIRED} in ${PROJECT_ID}/${APIGEE_ENV}."
