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

# Preflight static validator (Step #0 in cloudbuild-register.yaml) that checks
# Git tag syntax, referential integrity between registry/agents/*/agent.yaml and
# registry/cards/*.json, and uniqueness of agent names, Apigee DeveloperApp
# names, Secret Manager secret IDs, Kubernetes JWT subjects, A2A Agent Card
# interface URLs, and MCP Server interface URLs before any Apigee, Secret
# Manager, or Agent Registry API mutation runs.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${AGENTS_DIR:-${SCRIPT_DIR}/agents}"
CARDS_DIR="${CARDS_DIR:-${SCRIPT_DIR}/cards}"
MCP_SERVERS_DIR="${MCP_SERVERS_DIR:-${SCRIPT_DIR}/mcp-servers}"
TAG_NAME="${TAG_NAME:-}"

if [[ -n "${TAG_NAME}" ]]; then
  if [[ ! "${TAG_NAME}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid TAG_NAME '${TAG_NAME}'. Expected semantic version tag matching ^v[0-9]+\\.[0-9]+\\.[0-9]+$." >&2
    exit 1
  fi
fi

if [[ ! -d "${AGENTS_DIR}" ]]; then
  echo "ERROR: Agents directory not found: ${AGENTS_DIR}" >&2
  exit 1
fi
if [[ ! -d "${CARDS_DIR}" ]]; then
  echo "ERROR: Cards directory not found: ${CARDS_DIR}" >&2
  exit 1
fi

PYTHON_BIN="$(gcloud info --format='value(basic.python_location)' 2>/dev/null || command -v python3 || true)"
CLOUDSDK_THIRD_PARTY="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null || echo /usr/lib/google-cloud-sdk)/lib/third_party"
export CLOUDSDK_THIRD_PARTY
if [[ -z "${PYTHON_BIN}" || ! -x "${PYTHON_BIN}" ]]; then
  echo "ERROR: Python 3 runtime not found." >&2
  exit 1
fi

"${PYTHON_BIN}" - "${SCRIPT_DIR}" "${AGENTS_DIR}" "${CARDS_DIR}" "${MCP_SERVERS_DIR}" "${TAG_NAME}" << 'EOF'
import json
import os
from pathlib import Path
import sys


def load_yaml(text: str):
  try:
    import yaml as pyyaml
    return pyyaml.safe_load(text)
  except Exception:
    for p in (
        os.environ.get("CLOUDSDK_THIRD_PARTY", ""),
        "/usr/lib/google-cloud-sdk/lib/third_party",
        "/google-cloud-sdk/lib/third_party",
    ):
      if p and os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)
    from ruamel import yaml as ryaml
    return ryaml.YAML(typ="safe").load(text)


script_dir = Path(sys.argv[1])
agents_dir = Path(sys.argv[2])
cards_dir = Path(sys.argv[3])
mcp_dir = Path(sys.argv[4])
tag_name = sys.argv[5]

errors: list[str] = []

agent_files = sorted(agents_dir.glob("*/agent.yaml"))
card_files = sorted(cards_dir.glob("*.json"))
mcp_files = sorted(mcp_dir.glob("*.yaml")) if mcp_dir.is_dir() else []

if not agent_files:
  errors.append(f"No agent manifests found under {agents_dir}/*/agent.yaml")
if not card_files:
  errors.append(f"No Agent Card JSON files found under {cards_dir}/*.json")

seen_agent_names: dict[str, str] = {}
seen_app_names: dict[str, str] = {}
seen_secrets: dict[str, str] = {}
seen_jwt_subjects: dict[str, str] = {}
referenced_cards: dict[str, str] = {}
seen_urls: dict[str, str] = {}

for agent_path in agent_files:
  rel_path = str(agent_path.relative_to(script_dir))
  try:
    obj = load_yaml(agent_path.read_text(encoding="utf-8"))
  except Exception as exc:
    errors.append(f"{rel_path}: invalid YAML: {exc}")
    continue
  if not isinstance(obj, dict):
    errors.append(f"{rel_path}: top-level YAML document must be a mapping")
    continue

  name = str(obj.get("name") or "").strip()
  if not name:
    errors.append(f"{rel_path}: missing required 'name'")
  elif name != agent_path.parent.name:
    errors.append(
        f"{rel_path}: 'name' ('{name}') does not match directory '{agent_path.parent.name}'"
    )
  elif name in seen_agent_names:
    errors.append(
        f"{rel_path}: duplicate agent name '{name}' (already defined in {seen_agent_names[name]})"
    )
  else:
    seen_agent_names[name] = rel_path

  card_ref = str(obj.get("agentCard") or "").strip()
  if not card_ref:
    errors.append(f"{rel_path}: missing required 'agentCard'")
  else:
    card_target = (script_dir / card_ref).resolve()
    if not card_target.is_file():
      errors.append(
          f"{rel_path}: referenced agentCard '{card_ref}' does not exist"
      )
    elif card_ref in referenced_cards:
      errors.append(
          f"{rel_path}: agentCard '{card_ref}' already referenced by {referenced_cards[card_ref]}"
      )
    else:
      referenced_cards[card_ref] = rel_path

  apigee_app = obj.get("apigeeApp")
  app_name = (
      str(apigee_app.get("name") or "").strip()
      if isinstance(apigee_app, dict)
      else ""
  )
  if not app_name:
    errors.append(f"{rel_path}: missing required 'apigeeApp.name'")
  elif app_name in seen_app_names:
    errors.append(
        f"{rel_path}: duplicate apigeeApp.name '{app_name}' (already defined in {seen_app_names[app_name]})"
    )
  else:
    seen_app_names[app_name] = rel_path

  secret_id = str(obj.get("secretManagerSecret") or "").strip()
  if not secret_id:
    errors.append(f"{rel_path}: missing required 'secretManagerSecret'")
  elif secret_id in seen_secrets:
    errors.append(
        f"{rel_path}: duplicate secretManagerSecret '{secret_id}' (already defined in {seen_secrets[secret_id]})"
    )
  else:
    seen_secrets[secret_id] = rel_path

  k8s_id = obj.get("kubernetesIdentity")
  jwt_sub = (
      str(k8s_id.get("expectedJwtSubject") or "").strip()
      if isinstance(k8s_id, dict)
      else ""
  )
  if not jwt_sub:
    errors.append(
        f"{rel_path}: missing required 'kubernetesIdentity.expectedJwtSubject'"
    )
  elif jwt_sub in seen_jwt_subjects:
    errors.append(
        f"{rel_path}: duplicate kubernetesIdentity.expectedJwtSubject '{jwt_sub}' (already defined in {seen_jwt_subjects[jwt_sub]})"
    )
  else:
    seen_jwt_subjects[jwt_sub] = rel_path

for card_path in card_files:
  rel_card = f"cards/{card_path.name}"
  try:
    card_obj = json.loads(card_path.read_text(encoding="utf-8"))
  except Exception as exc:
    errors.append(f"{rel_card}: invalid JSON: {exc}")
    continue
  if not isinstance(card_obj, dict):
    errors.append(f"{rel_card}: top-level JSON value must be an object")
    continue

  card_name = str(card_obj.get("name") or "").strip()
  if not card_name:
    errors.append(f"{rel_card}: missing required 'name'")
  elif card_name != card_path.stem:
    errors.append(
        f"{rel_card}: card 'name' ('{card_name}') does not match filename stem '{card_path.stem}'"
    )

  if rel_card not in referenced_cards:
    errors.append(
        f"{rel_card}: orphan Agent Card is not referenced by any registry/agents/*/agent.yaml"
    )

  ifaces = card_obj.get("supportedInterfaces")
  if not isinstance(ifaces, list) or not ifaces:
    errors.append(f"{rel_card}: 'supportedInterfaces' must be a non-empty list")
  else:
    for idx, iface in enumerate(ifaces):
      if not isinstance(iface, dict):
        errors.append(f"{rel_card}: supportedInterfaces[{idx}] must be an object")
        continue
      url = str(iface.get("url") or "").strip()
      if not url:
        errors.append(
            f"{rel_card}: supportedInterfaces[{idx}].url must be non-empty"
        )
      elif url in seen_urls:
        errors.append(
            f"{rel_card}: duplicate interface url '{url}' (already used in {seen_urls[url]})"
        )
      else:
        seen_urls[url] = rel_card

seen_mcp_names: dict[str, str] = {}
for mcp_path in mcp_files:
  rel_mcp = f"mcp-servers/{mcp_path.name}"
  try:
    mcp_obj = load_yaml(mcp_path.read_text(encoding="utf-8"))
  except Exception as exc:
    errors.append(f"{rel_mcp}: invalid YAML: {exc}")
    continue
  if not isinstance(mcp_obj, dict):
    errors.append(f"{rel_mcp}: top-level YAML document must be a mapping")
    continue

  mcp_name = str(mcp_obj.get("name") or "").strip()
  if not mcp_name:
    errors.append(f"{rel_mcp}: missing required 'name'")
  elif mcp_name != mcp_path.stem:
    errors.append(
        f"{rel_mcp}: 'name' ('{mcp_name}') does not match filename stem '{mcp_path.stem}'"
    )
  elif mcp_name in seen_mcp_names:
    errors.append(
        f"{rel_mcp}: duplicate MCP server name '{mcp_name}' (already defined in {seen_mcp_names[mcp_name]})"
    )
  else:
    seen_mcp_names[mcp_name] = rel_mcp

  iface = mcp_obj.get("interface")
  url = str(iface.get("url") or "").strip() if isinstance(iface, dict) else ""
  if not url:
    errors.append(f"{rel_mcp}: missing required 'interface.url'")
  elif url in seen_urls:
    errors.append(
        f"{rel_mcp}: duplicate interface.url '{url}' (already used in {seen_urls[url]})"
    )
  else:
    seen_urls[url] = rel_mcp

if errors:
  print("Preflight manifest validation FAILED:", file=sys.stderr)
  for err in errors:
    print(f"  - {err}", file=sys.stderr)
  sys.exit(1)

print(
    f"Preflight manifest validation PASSED: {len(agent_files)} agent(s), "
    f"{len(card_files)} card(s), {len(mcp_files)} MCP server(s)"
    + (f", tag={tag_name}" if tag_name else "")
    + "."
)
EOF
