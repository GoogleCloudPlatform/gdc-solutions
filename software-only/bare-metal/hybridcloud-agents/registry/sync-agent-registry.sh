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

# Reconciles A2A Agent Cards idempotently into Google Cloud Agent Registry
# writable Service resources using documented GA gcloud commands:
#   - https://docs.cloud.google.com/agent-registry/manual-registration
#   - https://docs.cloud.google.com/agent-registry/json-schemas
#   - https://docs.cloud.google.com/agent-registry/roles-permissions
#
# Behavior:
#   1. Substitutes YOUR_GATEWAY_FQDN in cards/*.json with GATEWAY_FQDN.
#   2. Lists existing Services via `gcloud agent-registry services list`.
#   3. Creates missing Services (`gcloud agent-registry services create`),
#      canonical-JSON-compares existing Services before updating so unchanged
#      re-runs execute zero write RPCs (`gcloud agent-registry services update`),
#      and deletes Services stamped with [managed-by=hybridcloud-agents-registry]
#      when their card file is removed (`gcloud agent-registry services delete`).

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID to the target Google Cloud project ID.}"
REGISTRY_LOCATION="${REGISTRY_LOCATION:-us-central1}"
GATEWAY_FQDN="${GATEWAY_FQDN:?Set GATEWAY_FQDN to the Apigee hybrid ingress FQDN.}"
CARDS_DIR="${CARDS_DIR:-${SCRIPT_DIR}/cards}"
MANAGED_MARKER="[managed-by=hybridcloud-agents-registry]"

if [[ ${GATEWAY_FQDN} == "YOUR_GATEWAY_FQDN" ]]; then
  echo "ERROR: Replace YOUR_GATEWAY_FQDN with your gateway FQDN via _GATEWAY_FQDN." >&2
  exit 1
fi

if [[ ! -d ${CARDS_DIR} ]]; then
  echo "ERROR: Cards directory not found: ${CARDS_DIR}" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

PYTHON_BIN="$(command -v python3 || gcloud info --format='value(basic.python_location)' 2> /dev/null || true)"
if [[ -z ${PYTHON_BIN} || ! -x ${PYTHON_BIN} ]]; then
  echo "ERROR: Python 3 runtime not found." >&2
  exit 1
fi

EXISTING_FILE="${WORK_DIR}/existing.json"
PLAN_FILE="${WORK_DIR}/plan.tsv"

gcloud agent-registry services list \
  --project="${PROJECT_ID}" \
  --location="${REGISTRY_LOCATION}" \
  --format=json \
  --quiet > "${EXISTING_FILE}"

"${PYTHON_BIN}" - "${CARDS_DIR}" "${EXISTING_FILE}" "${GATEWAY_FQDN}" "${MANAGED_MARKER}" "${WORK_DIR}" > "${PLAN_FILE}" << 'EOF'
import json
from pathlib import Path
import sys

cards_dir = Path(sys.argv[1])
existing_items = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8") or "[]")
gateway_fqdn = sys.argv[3]
managed_marker = sys.argv[4]
work_dir = Path(sys.argv[5])

existing_by_id = {}
for item in existing_items:
  name = str(item.get("name", ""))
  if "/" in name:
    svc_id = name.split("/")[-1]
    existing_by_id[svc_id] = item

desired_ids = set()
for card_path in sorted(cards_dir.glob("*.json")):
  svc_id = card_path.stem
  desired_ids.add(svc_id)
  raw_text = card_path.read_text(encoding="utf-8").replace(
      "YOUR_GATEWAY_FQDN", gateway_fqdn
  )
  card_obj = json.loads(raw_text)
  rendered_path = work_dir / f"rendered-{svc_id}.json"
  rendered_compact = json.dumps(card_obj, sort_keys=True, separators=(",", ":"))
  rendered_path.write_text(rendered_compact, encoding="utf-8")

  display_name = str(card_obj.get("name", svc_id))[:63]
  base_desc = str(card_obj.get("description", "")).strip()
  if managed_marker in base_desc:
    managed_desc = base_desc[:2048]
  else:
    managed_desc = f"{base_desc} {managed_marker}".strip()[:2048]

  meta_path = work_dir / f"meta-{svc_id}.json"
  meta_path.write_text(
      json.dumps({"description": managed_desc, "display_name": display_name}),
      encoding="utf-8",
  )

  current = existing_by_id.get(svc_id)
  if current is None:
    print(f"CREATE\t{svc_id}")
    continue

  cur_display = str(current.get("displayName", ""))
  cur_desc = str(current.get("description", ""))
  cur_spec = current.get("agentSpec") or {}
  cur_type = str(cur_spec.get("type", ""))
  cur_content_raw = cur_spec.get("content")
  if isinstance(cur_content_raw, str):
    try:
      cur_content_obj = json.loads(cur_content_raw)
    except ValueError:
      cur_content_obj = cur_content_raw
  else:
    cur_content_obj = cur_content_raw
  cur_compact = json.dumps(
      cur_content_obj, sort_keys=True, separators=(",", ":")
  )

  if (
      cur_display == display_name
      and cur_desc == managed_desc
      and cur_type == "A2A_AGENT_CARD"
      and cur_compact == rendered_compact
  ):
    print(f"NOOP\t{svc_id}")
  else:
    print(f"UPDATE\t{svc_id}")

for svc_id in sorted(existing_by_id):
  if svc_id in desired_ids:
    continue
  cur_desc = str(existing_by_id[svc_id].get("description", ""))
  if managed_marker in cur_desc:
    print(f"DELETE\t{svc_id}")
EOF

created_count=0
updated_count=0
noop_count=0
deleted_count=0

while IFS=$'\t' read -r action svc_id; do
  [[ -z ${action} ]] && continue
  case "${action}" in
  CREATE)
    display_name="$("${PYTHON_BIN}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["display_name"])' "${WORK_DIR}/meta-${svc_id}.json")"
    managed_desc="$("${PYTHON_BIN}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["description"])' "${WORK_DIR}/meta-${svc_id}.json")"
    card_payload="$(cat "${WORK_DIR}/rendered-${svc_id}.json")"
    echo "CREATE ${svc_id} in ${PROJECT_ID}/${REGISTRY_LOCATION}"
    gcloud agent-registry services create "${svc_id}" \
      --project="${PROJECT_ID}" \
      --location="${REGISTRY_LOCATION}" \
      --display-name="${display_name}" \
      --description="${managed_desc}" \
      --agent-spec-type="a2a-agent-card" \
      --agent-spec-content="${card_payload}" \
      --quiet
    created_count=$((created_count + 1))
    ;;
  UPDATE)
    display_name="$("${PYTHON_BIN}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["display_name"])' "${WORK_DIR}/meta-${svc_id}.json")"
    managed_desc="$("${PYTHON_BIN}" -c 'import json,sys; print(json.load(open(sys.argv[1]))["description"])' "${WORK_DIR}/meta-${svc_id}.json")"
    card_payload="$(cat "${WORK_DIR}/rendered-${svc_id}.json")"
    echo "UPDATE ${svc_id} in ${PROJECT_ID}/${REGISTRY_LOCATION}"
    gcloud agent-registry services update "${svc_id}" \
      --project="${PROJECT_ID}" \
      --location="${REGISTRY_LOCATION}" \
      --display-name="${display_name}" \
      --description="${managed_desc}" \
      --agent-spec-content="${card_payload}" \
      --quiet
    updated_count=$((updated_count + 1))
    ;;
  NOOP)
    echo "UNCHANGED ${svc_id}: desired spec matches live Service (idempotent no-op)"
    noop_count=$((noop_count + 1))
    ;;
  DELETE)
    echo "DELETE ${svc_id} (card removed; Service carries ${MANAGED_MARKER})"
    gcloud agent-registry services delete "${svc_id}" \
      --project="${PROJECT_ID}" \
      --location="${REGISTRY_LOCATION}" \
      --quiet
    deleted_count=$((deleted_count + 1))
    ;;
  *)
    echo "ERROR: Unknown plan action '${action}'" >&2
    exit 1
    ;;
  esac
done < "${PLAN_FILE}"

printf '{"created":%d,"deleted":%d,"unchanged":%d,"updated":%d}\n' \
  "${created_count}" "${deleted_count}" "${noop_count}" "${updated_count}"
