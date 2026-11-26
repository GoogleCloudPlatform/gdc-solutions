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
# Git tag syntax, referential integrity between active registry/agents/*/agent.yaml
# (and staged registry/available/agents/*/agent.yaml) and registry/cards/*.json,
# uniqueness of agent names, Apigee DeveloperApp names, Secret Manager secret
# IDs, Kubernetes JWT subjects, egress proxy ports, A2A Agent Card and MCP
# Server interface URLs, active-vs-available separation, rendered agents
# FleetPackage parity with the active set, and zero KRM object overlap between
# the PLATFORM (agents-platform) and AGENTS (agents) FleetPackage renders
# before any Apigee, Secret Manager, or Agent Registry API mutation runs.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${AGENTS_DIR:-${SCRIPT_DIR}/agents}"
AVAILABLE_AGENTS_DIR="${AVAILABLE_AGENTS_DIR:-${SCRIPT_DIR}/available/agents}"
CARDS_DIR="${CARDS_DIR:-${SCRIPT_DIR}/cards}"
MCP_SERVERS_DIR="${MCP_SERVERS_DIR:-${SCRIPT_DIR}/mcp-servers}"
AVAILABLE_MCP_SERVERS_DIR="${AVAILABLE_MCP_SERVERS_DIR:-${SCRIPT_DIR}/available/mcp-servers}"
PROXIES_DIR="${PROXIES_DIR:-${SCRIPT_DIR}/../apigee/proxies}"
PRODUCTS_FILE="${PRODUCTS_FILE:-${SCRIPT_DIR}/../apigee/products/api-products.json}"
FLEET_ENV_DIR="${FLEET_ENV_DIR:-${SCRIPT_DIR}/../fleet-package/environments}"
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

PYTHON_BIN="$(gcloud info --format='value(basic.python_location)' 2> /dev/null || command -v python3 || true)"
CLOUDSDK_THIRD_PARTY="$(gcloud info --format='value(installation.sdk_root)' 2> /dev/null || echo /usr/lib/google-cloud-sdk)/lib/third_party"
export CLOUDSDK_THIRD_PARTY
if [[ -z "${PYTHON_BIN}" || ! -x "${PYTHON_BIN}" ]]; then
  echo "ERROR: Python 3 runtime not found." >&2
  exit 1
fi

"${PYTHON_BIN}" - \
  "${SCRIPT_DIR}" \
  "${AGENTS_DIR}" \
  "${AVAILABLE_AGENTS_DIR}" \
  "${CARDS_DIR}" \
  "${MCP_SERVERS_DIR}" \
  "${AVAILABLE_MCP_SERVERS_DIR}" \
  "${PROXIES_DIR}" \
  "${PRODUCTS_FILE}" \
  "${FLEET_ENV_DIR}" \
  "${TAG_NAME}" << 'EOF'
import ast
import json
import os
from pathlib import Path
import sys


def _import_yaml_loader():
  try:
    import yaml as pyyaml
    return pyyaml.safe_load, lambda t: list(pyyaml.safe_load_all(t))
  except Exception:
    for p in (
        os.environ.get("CLOUDSDK_THIRD_PARTY", ""),
        "/usr/lib/google-cloud-sdk/lib/third_party",
        "/google-cloud-sdk/lib/third_party",
    ):
      if p and os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)
    from ruamel import yaml as ryaml
    loader = ryaml.YAML(typ="safe")
    return loader.load, lambda t: list(loader.load_all(t))


load_yaml, load_yaml_all = _import_yaml_loader()


script_dir = Path(sys.argv[1])
agents_dir = Path(sys.argv[2])
avail_agents_dir = Path(sys.argv[3])
cards_dir = Path(sys.argv[4])
mcp_dir = Path(sys.argv[5])
avail_mcp_dir = Path(sys.argv[6])
proxies_dir = Path(sys.argv[7])
products_file = Path(sys.argv[8])
fleet_env_dir = Path(sys.argv[9])
tag_name = sys.argv[10]

errors: list[str] = []

active_agent_files = sorted(agents_dir.glob("*/agent.yaml"))
staged_agent_files = (
    sorted(avail_agents_dir.glob("*/agent.yaml"))
    if avail_agents_dir.is_dir()
    else []
)
card_files = sorted(cards_dir.glob("*.json"))
active_mcp_files = sorted(mcp_dir.glob("*.yaml")) if mcp_dir.is_dir() else []
staged_mcp_files = (
    sorted(avail_mcp_dir.glob("*.yaml")) if avail_mcp_dir.is_dir() else []
)

seen_agent_names: dict[str, str] = {}
seen_app_names: dict[str, str] = {}
seen_secrets: dict[str, str] = {}
seen_jwt_subjects: dict[str, str] = {}
seen_egress_ports: dict[int, str] = {}
referenced_cards: dict[str, str] = {}
seen_urls: dict[str, str] = {}
active_agent_specs: dict[str, dict] = {}


def _validate_agent_file(agent_path: Path, is_active: bool) -> None:
  rel_path = str(agent_path.relative_to(script_dir))
  try:
    obj = load_yaml(agent_path.read_text(encoding="utf-8"))
  except Exception as exc:
    errors.append(f"{rel_path}: invalid YAML: {exc}")
    return
  if not isinstance(obj, dict):
    errors.append(f"{rel_path}: top-level YAML document must be a mapping")
    return

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
    if is_active:
      active_agent_specs[name] = obj

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

  egress_proxy = obj.get("egressProxy")
  if egress_proxy is not None:
    if not isinstance(egress_proxy, dict):
      errors.append(f"{rel_path}: 'egressProxy' must be a mapping")
    else:
      egress_port = egress_proxy.get("port")
      egress_ep = str(egress_proxy.get("endpoint") or "").strip()
      if (
          not isinstance(egress_port, int)
          or isinstance(egress_port, bool)
          or not (1024 <= egress_port <= 65535)
      ):
        errors.append(
            f"{rel_path}: 'egressProxy.port' must be an integer between 1024 and 65535"
        )
      elif egress_port in seen_egress_ports:
        errors.append(
            f"{rel_path}: duplicate egressProxy.port '{egress_port}' (already assigned in {seen_egress_ports[egress_port]})"
        )
      else:
        seen_egress_ports[egress_port] = rel_path
      if not egress_ep:
        errors.append(f"{rel_path}: missing required 'egressProxy.endpoint'")
      elif isinstance(egress_port, int) and f":{egress_port}" not in egress_ep:
        errors.append(
            f"{rel_path}: egressProxy.endpoint '{egress_ep}' does not match egressProxy.port '{egress_port}'"
        )


for p in active_agent_files:
  _validate_agent_file(p, is_active=True)
for p in staged_agent_files:
  _validate_agent_file(p, is_active=False)

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
        f"{rel_card}: orphan Agent Card is not referenced by any active or available agent.yaml"
    )

  ifaces = card_obj.get("supportedInterfaces")
  if not isinstance(ifaces, list) or not ifaces:
    errors.append(f"{rel_card}: 'supportedInterfaces' must be a non-empty list")
  else:
    for idx, iface in enumerate(ifaces):
      if not isinstance(iface, dict):
        errors.append(
            f"{rel_card}: supportedInterfaces[{idx}] must be an object"
        )
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
mcp_proxy_tools: dict[str, tuple[str, set[str]]] = {}


def _validate_mcp_file(mcp_path: Path) -> None:
  rel_mcp = str(mcp_path.relative_to(script_dir))
  try:
    mcp_obj = load_yaml(mcp_path.read_text(encoding="utf-8"))
  except Exception as exc:
    errors.append(f"{rel_mcp}: invalid YAML: {exc}")
    return
  if not isinstance(mcp_obj, dict):
    errors.append(f"{rel_mcp}: top-level YAML document must be a mapping")
    return

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

  apigee_proxy = str(mcp_obj.get("apigeeProxy") or "").strip()
  if apigee_proxy and proxies_dir.is_dir():
    if not (proxies_dir / apigee_proxy / "apiproxy").is_dir():
      errors.append(
          f"{rel_mcp}: apigeeProxy '{apigee_proxy}' not found under {proxies_dir}"
      )
  if apigee_proxy:
    declared_tools = {
        str(t.get("name") or "").strip()
        for t in (mcp_obj.get("tools") or [])
        if isinstance(t, dict) and str(t.get("name") or "").strip()
    }
    mcp_proxy_tools[apigee_proxy] = (rel_mcp, declared_tools)


for p in active_mcp_files:
  _validate_mcp_file(p)
for p in staged_mcp_files:
  _validate_mcp_file(p)

# Verify parity between MCP server YAML tools and Apigee APIProduct payloadOperationGroup tools/call/*
if products_file.is_file() and mcp_proxy_tools:
  try:
    products_data = json.loads(products_file.read_text(encoding="utf-8"))
  except Exception as exc:
    errors.append(f"apigee/products/api-products.json: invalid JSON: {exc}")
    products_data = []
  product_tools_by_proxy: dict[str, set[str]] = {}
  for prod in products_data if isinstance(products_data, list) else []:
    if not isinstance(prod, dict):
      continue
    pog = prod.get("payloadOperationGroup")
    if not isinstance(pog, dict):
      continue
    for cfg in pog.get("operationConfigs") or []:
      if not isinstance(cfg, dict):
        continue
      src = str(cfg.get("apiSource") or "").strip()
      if not src:
        continue
      for op in cfg.get("operations") or []:
        if not isinstance(op, dict):
          continue
        op_name = str(op.get("operation") or "").strip()
        if op_name.startswith("tools/call/"):
          if src not in product_tools_by_proxy:
            product_tools_by_proxy[src] = set()
          product_tools_by_proxy[src].add(op_name[len("tools/call/") :])
  for proxy_name, (rel_mcp, spec_tools) in sorted(mcp_proxy_tools.items()):
    prod_tools = product_tools_by_proxy.get(proxy_name, set())
    missing_in_spec = sorted(prod_tools - spec_tools)
    missing_in_products = sorted(spec_tools - prod_tools)
    if missing_in_spec:
      errors.append(
          f"{rel_mcp}: tools enabled in api-products.json for {proxy_name} but missing from MCP manifest: {missing_in_spec}"
      )
    if missing_in_products:
      errors.append(
          f"{rel_mcp}: tools declared for {proxy_name} but not permitted in any api-products.json payloadOperationGroup: {missing_in_products}"
      )

fleet_summary = ""
if fleet_env_dir.is_dir():
  expected_variants = ("agents-platform", "gateway-tools-platform", "agents")
  variant_objects: dict[str, set[tuple[str, str, str, str]]] = {}
  rendered_agent_deployments: dict[str, dict] = {}

  for variant in expected_variants:
    manifest_path = fleet_env_dir / variant / "manifests.yaml"
    if not manifest_path.is_file():
      errors.append(
          f"fleet-package/environments/{variant}/manifests.yaml: missing rendered variant bundle"
      )
      continue
    try:
      docs = load_yaml_all(manifest_path.read_text(encoding="utf-8"))
    except Exception as exc:
      errors.append(
          f"fleet-package/environments/{variant}/manifests.yaml: invalid YAML: {exc}"
      )
      continue
    objects: set[tuple[str, str, str, str]] = set()
    for doc in docs:
      if not isinstance(doc, dict):
        continue
      api_version = str(doc.get("apiVersion") or "").strip()
      group = api_version.split("/", 1)[0] if "/" in api_version else ""
      kind = str(doc.get("kind") or "").strip()
      meta = doc.get("metadata") or {}
      name = str(meta.get("name") or "").strip()
      ns = str(meta.get("namespace") or "").strip()
      key = (group, kind, ns, name)
      if key in objects:
        errors.append(
            f"fleet-package/environments/{variant}/manifests.yaml: duplicate object {group or 'core'}/{kind} {ns}/{name}"
        )
      objects.add(key)
      if variant == "agents":
        if kind == "Namespace":
          errors.append(
              f"fleet-package/environments/agents/manifests.yaml: AGENTS package must not declare Namespace/{name} (owned by PLATFORM)"
          )
        labels = meta.get("labels") or {}
        if kind == "Deployment" and labels.get("registry.gke.io/functional-type") == "AGENT":
          rendered_agent_deployments[name] = doc
    variant_objects[variant] = objects

  # Check rendered agents bundle matches active registry/agents/*
  expected_active_names = set(active_agent_specs.keys())
  rendered_names = set(rendered_agent_deployments.keys())
  if rendered_names != expected_active_names:
    errors.append(
        "fleet-package/environments/agents/manifests.yaml active agent Deployments "
        f"{sorted(rendered_names)} do not match active registry/agents/* "
        f"{sorted(expected_active_names)} (re-run fleet-package/render.sh agents)"
    )
  for aname, dep_doc in rendered_agent_deployments.items():
    spec_ep = str(
        (active_agent_specs.get(aname, {}).get("egressProxy") or {}).get(
            "endpoint", ""
        )
    )
    if spec_ep:
      containers = (
          dep_doc.get("spec", {})
          .get("template", {})
          .get("spec", {})
          .get("containers", [])
      )
      env_map = {
          e["name"]: str(e.get("value", ""))
          for e in (containers[0].get("env", []) if containers else [])
      }
      if env_map.get("EGRESS_PROXY_BASE") != spec_ep:
        errors.append(
            f"Deployment/{aname} EGRESS_PROXY_BASE ('{env_map.get('EGRESS_PROXY_BASE')}') "
            f"does not match registry/agents/{aname}/agent.yaml egressProxy.endpoint ('{spec_ep}')"
        )

  overlap = sorted(
      variant_objects.get("agents-platform", set())
      & variant_objects.get("agents", set())
  )
  for group, kind, ns, name in overlap:
    errors.append(
        f"Cross-package overlap between agents-platform and agents: {group or 'core'}/{kind} {ns or '<cluster>'}/{name}"
    )

  if all(v in variant_objects for v in expected_variants):
    fleet_summary = (
        f", fleet variants (agents-platform={len(variant_objects['agents-platform'])}, "
        f"gateway-tools-platform={len(variant_objects['gateway-tools-platform'])}, "
        f"agents={len(variant_objects['agents'])}, overlap={len(overlap)})"
    )

# Static FastAPI route check: union returns involving Response subclasses require response_model=None
agents_src_dir = (script_dir / ".." / "agents").resolve()
if agents_src_dir.is_dir():
  for app_py in sorted(agents_src_dir.glob("*/app.py")):
    rel_app = f"agents/{app_py.parent.name}/app.py"
    try:
      tree = ast.parse(app_py.read_text(encoding="utf-8"), filename=str(app_py))
    except SyntaxError as exc:
      errors.append(f"{rel_app}: Python syntax error: {exc}")
      continue
    for node in ast.walk(tree):
      if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        continue
      if node.returns is None:
        continue
      ret_node = node.returns
      is_union = (
          isinstance(ret_node, ast.BinOp) and isinstance(ret_node.op, ast.BitOr)
      ) or (
          isinstance(ret_node, ast.Subscript)
          and isinstance(ret_node.value, ast.Name)
          and ret_node.value.id == "Union"
      )
      ret_names = [
          n.id for n in ast.walk(ret_node) if isinstance(n, ast.Name)
      ]
      if not (is_union and any("Response" in name for name in ret_names)):
        continue
      for dec in node.decorator_list:
        if (
            isinstance(dec, ast.Call)
            and isinstance(dec.func, ast.Attribute)
            and isinstance(dec.func.value, ast.Name)
            and dec.func.value.id == "app"
            and dec.func.attr in ("get", "post", "put", "delete", "patch", "api_route")
        ):
          has_rm_none = any(
              kw.arg == "response_model"
              and isinstance(kw.value, ast.Constant)
              and kw.value.value is None
              for kw in dec.keywords
          )
          if not has_rm_none:
            errors.append(
                f"{rel_app}:{dec.lineno}: FastAPI route '{node.name}' returns Response union {ret_names} without response_model=None"
            )

if errors:
  print("Preflight manifest validation FAILED:", file=sys.stderr)
  for err in errors:
    print(f"  - {err}", file=sys.stderr)
  sys.exit(1)

print(
    f"Preflight manifest validation PASSED: {len(active_agent_files)} active agent(s) "
    f"({len(staged_agent_files)} staged), {len(card_files)} card(s), "
    f"{len(active_mcp_files)} active MCP server(s) ({len(staged_mcp_files)} staged)"
    f"{fleet_summary}"
    + (f", tag={tag_name}" if tag_name else "")
    + "."
)
EOF
