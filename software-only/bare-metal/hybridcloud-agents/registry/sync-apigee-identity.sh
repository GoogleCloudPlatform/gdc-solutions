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

# Idempotently reconciles per-agent Apigee identity, API products/quotas (scoped
# to active MCP servers in registry/mcp-servers/*.yaml), Secret Manager API key
# versions (only when the consumer key hash changes, never printing keys;
# destroys all enabled/disabled key versions when a pipeline-managed agent
# manifest is removed), unreferenced pipeline-managed API products, and the
# environment KVM `agent-jwt-subjects` from active `registry/agents/*/agent.yaml`
# (Wave ID-SYNC + Wave SECRET-CLEANUP + D29 progressive onboarding/rollback).

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ID="${PROJECT_ID:-}"
APIGEE_ENV="${APIGEE_ENV:-hybrid-agents-env}"
AGENTS_CLUSTER_OIDC_JWKS="${AGENTS_CLUSTER_OIDC_JWKS:-}"
AGENTS_CLUSTER_OIDC_JWKS_B64="${AGENTS_CLUSTER_OIDC_JWKS_B64:-}"
AGENTS_DIR="${AGENTS_DIR:-${SCRIPT_DIR}/agents}"
MCP_SERVERS_DIR="${MCP_SERVERS_DIR:-${SCRIPT_DIR}/mcp-servers}"
AVAILABLE_MCP_SERVERS_DIR="${AVAILABLE_MCP_SERVERS_DIR:-${SCRIPT_DIR}/available/mcp-servers}"
PRODUCTS_FILE="${PRODUCTS_FILE:-${REPO_ROOT}/apigee/products/api-products.json}"
ENV_CONFIG_FILE="${ENV_CONFIG_FILE:-${REPO_ROOT}/apigee/environments/env-config.json}"

for VAR_NAME in PROJECT_ID APIGEE_ENV; do
  VAR_VAL="${!VAR_NAME:-}"
  if [[ -z "${VAR_VAL}" || "${VAR_VAL}" == YOUR_* || "${VAR_VAL}" == *YOUR_* ]]; then
    echo "ERROR: Required variable ${VAR_NAME} is empty or still set to a YOUR_* placeholder ('${VAR_VAL}'). Configure Cloud Build trigger substitutions before running sync-apigee-identity.sh." >&2
    exit 1
  fi
done

if [[ -z "${AGENTS_CLUSTER_OIDC_JWKS_B64}" && -z "${AGENTS_CLUSTER_OIDC_JWKS}" ]]; then
  echo "ERROR: Required OIDC JWKS input is empty. Set _AGENTS_CLUSTER_OIDC_JWKS_B64 (or _AGENTS_CLUSTER_OIDC_JWKS) to the Agents cluster OIDC JWKS before running sync-apigee-identity.sh." >&2
  exit 1
fi
if [[ "${AGENTS_CLUSTER_OIDC_JWKS_B64}" == YOUR_* || "${AGENTS_CLUSTER_OIDC_JWKS_B64}" == *YOUR_* || "${AGENTS_CLUSTER_OIDC_JWKS}" == YOUR_* || "${AGENTS_CLUSTER_OIDC_JWKS}" == *YOUR_* ]]; then
  echo "ERROR: OIDC JWKS input contains a YOUR_* placeholder. Set _AGENTS_CLUSTER_OIDC_JWKS_B64 (or _AGENTS_CLUSTER_OIDC_JWKS) to the real Agents cluster OIDC JWKS." >&2
  exit 1
fi

PYTHON_BIN="$(gcloud info --format='value(basic.python_location)' 2> /dev/null || command -v python3 || true)"
CLOUDSDK_THIRD_PARTY="$(gcloud info --format='value(installation.sdk_root)' 2> /dev/null || echo /usr/lib/google-cloud-sdk)/lib/third_party"
export CLOUDSDK_THIRD_PARTY
if [[ -z "${PYTHON_BIN}" || ! -x "${PYTHON_BIN}" ]]; then
  echo "ERROR: Python 3 runtime not found." >&2
  exit 1
fi

ACCESS_TOKEN="$(gcloud auth print-access-token --quiet)"
export ACCESS_TOKEN

"${PYTHON_BIN}" - \
  "${PROJECT_ID}" \
  "${APIGEE_ENV}" \
  "${AGENTS_DIR}" \
  "${MCP_SERVERS_DIR}" \
  "${AVAILABLE_MCP_SERVERS_DIR}" \
  "${PRODUCTS_FILE}" \
  "${ENV_CONFIG_FILE}" << 'EOF'
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


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


project_id = sys.argv[1]
apigee_env = sys.argv[2]
agents_dir = Path(sys.argv[3])
mcp_dir = Path(sys.argv[4])
avail_mcp_dir = Path(sys.argv[5])
products_file = Path(sys.argv[6])
env_config_file = Path(sys.argv[7])
token = os.environ["ACCESS_TOKEN"]

MANAGED_BY_VALUE = "hybridcloud-agents-id-sync"
APIGEE_BASE = f"https://apigee.googleapis.com/v1/organizations/{project_id}"
SM_BASE = f"https://secretmanager.googleapis.com/v1/projects/{project_id}"


def api_req(method: str, url: str, body=None, allow_404: bool = False):
  headers = {"Authorization": f"Bearer {token}"}
  data = None
  if body is not None:
    headers["Content-Type"] = "application/json"
    data = json.dumps(body).encode("utf-8")
  req = urllib.request.Request(url, data=data, headers=headers, method=method)
  try:
    with urllib.request.urlopen(req, timeout=60) as resp:
      raw = resp.read().decode("utf-8")
      return resp.status, (json.loads(raw) if raw else {})
  except urllib.error.HTTPError as e:
    if allow_404 and e.code == 404:
      return 404, {}
    err_body = e.read().decode("utf-8", errors="replace")
    raise RuntimeError(f"HTTP {e.code} on {method} {url}: {err_body}") from e


def list_apigee_paginated(
    base_url: str,
    list_key: str,
    id_field: str,
    expand: bool = True,
    page_size: int = 1000,
    allow_404: bool = False,
):
  """Paginate Apigee v1 startKey/count list endpoints without dropping items."""
  results = []
  seen_ids = set()
  start_key = None
  while True:
    params = {"count": str(page_size)}
    if expand:
      params["expand"] = "true"
    if start_key is not None:
      params["startKey"] = start_key
    url = f"{base_url}?{urllib.parse.urlencode(params)}"
    st, resp = api_req("GET", url, allow_404=allow_404)
    if st == 404:
      return 404, []
    items = resp.get(list_key) or []
    if not items:
      break
    last_id = None
    for item in items:
      item_id = (
          str(item.get(id_field) or "") if isinstance(item, dict) else str(item)
      )
      last_id = item_id
      if item_id and item_id not in seen_ids:
        seen_ids.add(item_id)
        results.append(item)
    if len(items) < page_size or not last_id or last_id == start_key:
      break
    start_key = last_id
  return 200, results


def list_kvm_entries(entries_url: str, allow_404: bool = False):
  """Paginate Apigee X/hybrid KVM entries via page_size/page_token."""
  entries = {}
  page_token = None
  while True:
    params = {"page_size": "100"}
    if page_token:
      params["page_token"] = page_token
    url = f"{entries_url}?{urllib.parse.urlencode(params)}"
    st, resp = api_req("GET", url, allow_404=allow_404)
    if st == 404:
      return 404, {}
    for e in resp.get("keyValueEntries") or []:
      if "name" in e:
        entries[str(e["name"])] = str(e.get("value", ""))
    next_tok = resp.get("nextPageToken") or resp.get("next_page_token")
    if not next_tok or next_tok == page_token:
      break
    page_token = next_tok
  return 200, entries


def attrs_to_dict(attrs_list):
  out = {}
  for item in attrs_list or []:
    k = item.get("name")
    v = item.get("value")
    if k is not None and v is not None:
      out[str(k)] = str(v)
  return out


def dict_to_attrs(d):
  return [{"name": k, "value": str(d[k])} for k in sorted(d.keys())]


def canonical_product(p):
  op_configs = []
  for oc in (p.get("operationGroup") or {}).get("operationConfigs") or []:
    ops = []
    for op in oc.get("operations") or []:
      ops.append({
          "methods": sorted(op.get("methods") or []),
          "resource": op.get("resource", ""),
      })
    ops.sort(key=lambda x: (x["resource"], ",".join(x["methods"])))
    cfg = {
        "apiSource": oc.get("apiSource", ""),
        "attributes": dict_to_attrs(attrs_to_dict(oc.get("attributes"))),
        "operations": ops,
    }
    if oc.get("quota") and oc["quota"].get("limit"):
      cfg["quota"] = {
          "interval": str(oc["quota"].get("interval", "")),
          "limit": str(oc["quota"].get("limit", "")),
          "timeUnit": str(oc["quota"].get("timeUnit", "")),
      }
    op_configs.append(cfg)
  op_configs.sort(
      key=lambda x: (x["apiSource"], json.dumps(x["operations"], sort_keys=True))
  )

  llm_configs = []
  for lc in (p.get("llmOperationGroup") or {}).get("operationConfigs") or []:
    lops = []
    for lop in lc.get("llmOperations") or []:
      lops.append({
          "methods": sorted(lop.get("methods") or []),
          "model": lop.get("model", ""),
          "resource": lop.get("resource", ""),
      })
    lops.sort(key=lambda x: (x["resource"], x["model"], ",".join(x["methods"])))
    lcfg = {
        "apiSource": lc.get("apiSource", ""),
        "attributes": dict_to_attrs(attrs_to_dict(lc.get("attributes"))),
        "llmOperations": lops,
    }
    if lc.get("llmTokenQuota") and lc["llmTokenQuota"].get("limit"):
      lcfg["llmTokenQuota"] = {
          "interval": str(lc["llmTokenQuota"].get("interval", "")),
          "limit": str(lc["llmTokenQuota"].get("limit", "")),
          "timeUnit": str(lc["llmTokenQuota"].get("timeUnit", "")),
      }
    llm_configs.append(lcfg)
  llm_configs.sort(
      key=lambda x: (
          x["apiSource"],
          json.dumps(x["llmOperations"], sort_keys=True),
      )
  )

  payload_configs = []
  for pc in (p.get("payloadOperationGroup") or {}).get("operationConfigs") or []:
    pops = []
    for pop in pc.get("operations") or []:
      pops.append({"operation": pop.get("operation", "")})
    pops.sort(key=lambda x: x["operation"])
    pcfg = {
        "apiSource": pc.get("apiSource", ""),
        "operations": pops,
    }
    if pc.get("quota") and pc["quota"].get("limit"):
      pcfg["quota"] = {
          "interval": str(pc["quota"].get("interval", "")),
          "limit": str(pc["quota"].get("limit", "")),
          "timeUnit": str(pc["quota"].get("timeUnit", "")),
      }
    payload_configs.append(pcfg)
  payload_configs.sort(
      key=lambda x: (x["apiSource"], json.dumps(x["operations"], sort_keys=True))
  )

  out = {
      "approvalType": p.get("approvalType", "auto"),
      "attributes": dict_to_attrs(attrs_to_dict(p.get("attributes"))),
      "description": p.get("description", ""),
      "displayName": p.get("displayName", p.get("name", "")),
      "environments": sorted(p.get("environments") or []),
      "name": p.get("name", ""),
      "proxies": sorted(p.get("proxies") or []),
  }
  if op_configs:
    out["operationGroup"] = {
        "operationConfigType": (p.get("operationGroup") or {}).get(
            "operationConfigType", "proxy"
        ),
        "operationConfigs": op_configs,
    }
  if llm_configs:
    out["llmOperationGroup"] = {"operationConfigs": llm_configs}
  if payload_configs:
    out["payloadOperationGroup"] = {"operationConfigs": payload_configs}
  if p.get("quota"):
    out["quota"] = str(p["quota"])
    out["quotaInterval"] = str(p.get("quotaInterval", ""))
    out["quotaTimeUnit"] = str(p.get("quotaTimeUnit", ""))
  return out


def add_secret_version(secret_name: str, secret_val: str) -> None:
  b64_payload = base64.b64encode(secret_val.encode("utf-8")).decode("ascii")
  url = f"{SM_BASE}/secrets/{secret_name}:addVersion"
  _, resp = api_req("POST", url, {"payload": {"data": b64_payload}})
  ver_name = resp.get("name", "unknown")
  print(f"SECRET_VERSION_ADDED secret={secret_name} version={ver_name}")


def destroy_secret_versions(secret_name: str, app_name: str):
  destroyed = 0
  errors = 0
  try:
    versions = []
    page_token = None
    while True:
      params = {"pageSize": "200"}
      if page_token:
        params["pageToken"] = page_token
      st, resp = api_req(
          "GET",
          f"{SM_BASE}/secrets/{urllib.parse.quote(secret_name, safe='')}/versions?{urllib.parse.urlencode(params)}",
          allow_404=True,
      )
      if st == 404:
        print(
            f"INFO: Secret for removed pipeline-managed DeveloperApp {app_name} already absent (404); 0 versions to destroy."
        )
        return 0, 0
      versions.extend(resp.get("versions", []))
      next_tok = resp.get("nextPageToken")
      if not next_tok or next_tok == page_token:
        break
      page_token = next_tok
    for v in versions:
      state = v.get("state", "")
      if state not in ("ENABLED", "DISABLED"):
        continue
      ver_id = v.get("name", "").rsplit("/", 1)[-1]
      if not ver_id:
        continue
      res = subprocess.run(
          [
              "gcloud",
              "secrets",
              "versions",
              "destroy",
              ver_id,
              f"--secret={secret_name}",
              f"--project={project_id}",
              "--quiet",
          ],
          capture_output=True,
          text=True,
          check=False,
      )
      if res.returncode == 0:
        print(
            f"DESTROY secret version projects/{project_id}/secrets/{secret_name}/versions/{ver_id} (app={app_name}, prior_state={state})"
        )
        destroyed += 1
      else:
        print(
            f"WARN: Failed to destroy secret version {secret_name}/versions/{ver_id} for removed app {app_name}: {res.stderr.strip()}"
        )
        errors += 1
  except Exception as exc:
    print(
        f"WARN: Failed to list/destroy secret versions for removed pipeline-managed app {app_name}: {exc}"
    )
    errors += 1
  return destroyed, errors


def _collect_mcp_proxies(directory: Path) -> set[str]:
  proxies: set[str] = set()
  if not directory.is_dir():
    return proxies
  for mcp_path in sorted(directory.glob("*.yaml")):
    obj = load_yaml(mcp_path.read_text(encoding="utf-8"))
    if not isinstance(obj, dict):
      continue
    name = str(obj.get("name") or mcp_path.stem).strip()
    proxy = str(obj.get("apigeeProxy") or f"{name}-v1").strip()
    if proxy:
      proxies.add(proxy)
  return proxies


active_mcp_proxies = _collect_mcp_proxies(mcp_dir)
staged_mcp_proxies = _collect_mcp_proxies(avail_mcp_dir)
gated_mcp_proxies = active_mcp_proxies | staged_mcp_proxies

# Load base API products and env config
raw_products = json.loads(products_file.read_text(encoding="utf-8"))
base_products_list = (
    raw_products
    if isinstance(raw_products, list)
    else raw_products.get("apiProduct", [])
)
base_products = {p["name"]: p for p in base_products_list}
env_cfg = json.loads(env_config_file.read_text(encoding="utf-8"))

# Load active agent manifests
agent_manifests = []
if agents_dir.is_dir():
  for manifest_path in sorted(agents_dir.glob("*/agent.yaml")):
    m = load_yaml(manifest_path.read_text(encoding="utf-8"))
    agent_manifests.append(m)

created_count = 0
updated_count = 0
noop_count = 0
deleted_count = 0
products_deleted_count = 0
secret_versions_destroyed = 0
secret_version_destroy_errors = 0

# 1. Compute desired API Products once across all active agent manifests (fail fast on conflicting shared-product overrides)
product_updates = set()
desired_products: dict[str, tuple[dict, str]] = {}
agent_effective_products: dict[str, list[str]] = {}

for m in agent_manifests:
  agent_name = m["name"]
  allowed_models_csv = ",".join(m.get("allowedModelAliases") or [])
  eff_prods: list[str] = []
  for prod_override in m.get("apiProducts") or []:
    pname = prod_override["name"]
    if pname not in base_products:
      raise RuntimeError(f"API product {pname} not found in {products_file}")
    desired_prod = json.loads(json.dumps(base_products[pname]))

    # Gate MCP payloadOperationGroup entries by active registry/mcp-servers/*.yaml
    pog = desired_prod.get("payloadOperationGroup")
    if isinstance(pog, dict) and pog.get("operationConfigs"):
      orig_configs = pog["operationConfigs"]
      has_gated_mcp = any(
          oc.get("apiSource") in gated_mcp_proxies for oc in orig_configs
      )
      if has_gated_mcp:
        filtered = [
            oc
            for oc in orig_configs
            if oc.get("apiSource") not in gated_mcp_proxies
            or oc.get("apiSource") in active_mcp_proxies
        ]
        has_active_gated = any(
            oc.get("apiSource") in active_mcp_proxies for oc in filtered
        )
        if not has_active_gated:
          print(
              f"SKIP APIProduct {pname} for agent {agent_name} (no active MCP server in registry/mcp-servers/)"
          )
          continue
        desired_prod["payloadOperationGroup"]["operationConfigs"] = filtered

    eff_prods.append(pname)

    attrs = attrs_to_dict(desired_prod.get("attributes"))
    attrs["managed_by"] = MANAGED_BY_VALUE
    if allowed_models_csv and "allowed_models" in attrs:
      attrs["allowed_models"] = allowed_models_csv
    if "allowCloudBurst" in prod_override:
      attrs["allow_cloud_burst"] = str(prod_override["allowCloudBurst"]).lower()
    if "promptTokenRate" in prod_override:
      attrs["prompt_token_rate"] = str(prod_override["promptTokenRate"])
    if "llmTokenQuotaLimit" in prod_override:
      attrs["llm_token_quota"] = str(prod_override["llmTokenQuotaLimit"])
      attrs["llm_token_quota_limit"] = str(prod_override["llmTokenQuotaLimit"])
      for lc in (desired_prod.get("llmOperationGroup") or {}).get("operationConfigs") or []:
        if "llmTokenQuota" in lc:
          lc["llmTokenQuota"]["limit"] = str(prod_override["llmTokenQuotaLimit"])
    if "llmTokenQuotaInterval" in prod_override:
      attrs["llm_token_quota_interval"] = str(
          prod_override["llmTokenQuotaInterval"]
      )
      for lc in (desired_prod.get("llmOperationGroup") or {}).get("operationConfigs") or []:
        if "llmTokenQuota" in lc:
          lc["llmTokenQuota"]["interval"] = str(prod_override["llmTokenQuotaInterval"])
    if "llmTokenQuotaTimeUnit" in prod_override:
      attrs["llm_token_quota_time_unit"] = str(
          prod_override["llmTokenQuotaTimeUnit"]
      )
      for lc in (desired_prod.get("llmOperationGroup") or {}).get("operationConfigs") or []:
        if "llmTokenQuota" in lc:
          lc["llmTokenQuota"]["timeUnit"] = str(prod_override["llmTokenQuotaTimeUnit"])
    if "spikeArrestRate" in prod_override:
      attrs["spike_arrest_rate"] = str(prod_override["spikeArrestRate"])
    payload_op_configs = (desired_prod.get("payloadOperationGroup") or {}).get(
        "operationConfigs"
    ) or []
    if "toolQuotaLimit" in prod_override:
      attrs["tool_quota_limit"] = str(prod_override["toolQuotaLimit"])
      if payload_op_configs:
        for pc in payload_op_configs:
          if "quota" not in pc or not isinstance(pc["quota"], dict):
            pc["quota"] = {}
          pc["quota"]["limit"] = str(prod_override["toolQuotaLimit"])
      else:
        desired_prod["quota"] = str(prod_override["toolQuotaLimit"])
    if "toolQuotaInterval" in prod_override:
      attrs["tool_quota_interval"] = str(prod_override["toolQuotaInterval"])
      if payload_op_configs:
        for pc in payload_op_configs:
          if "quota" not in pc or not isinstance(pc["quota"], dict):
            pc["quota"] = {}
          pc["quota"]["interval"] = str(prod_override["toolQuotaInterval"])
      else:
        desired_prod["quotaInterval"] = str(prod_override["toolQuotaInterval"])
    if "toolQuotaTimeUnit" in prod_override:
      attrs["tool_quota_time_unit"] = str(prod_override["toolQuotaTimeUnit"])
      if payload_op_configs:
        for pc in payload_op_configs:
          if "quota" not in pc or not isinstance(pc["quota"], dict):
            pc["quota"] = {}
          pc["quota"]["timeUnit"] = str(prod_override["toolQuotaTimeUnit"])
      else:
        desired_prod["quotaTimeUnit"] = str(prod_override["toolQuotaTimeUnit"])
    desired_prod["attributes"] = dict_to_attrs(attrs)

    des_canon = canonical_product(desired_prod)
    if pname in desired_products:
      prev_canon, prev_agent = desired_products[pname]
      if prev_canon != des_canon:
        raise RuntimeError(
            f"Conflicting APIProduct '{pname}' overrides between agents "
            f"'{prev_agent}' and '{agent_name}'; use distinct products or identical overrides."
        )
    else:
      desired_products[pname] = (des_canon, agent_name)
  agent_effective_products[agent_name] = sorted(eff_prods)

desired_product_names = set(desired_products.keys())
for pname in sorted(desired_products.keys()):
  des_canon, _ = desired_products[pname]
  st, live_prod = api_req(
      "GET", f"{APIGEE_BASE}/apiproducts/{pname}", allow_404=True
  )
  if st == 404:
    print(f"CREATE APIProduct {pname}")
    api_req("POST", f"{APIGEE_BASE}/apiproducts", des_canon)
    product_updates.add(pname)
  else:
    live_canon = canonical_product(live_prod)
    if live_canon != des_canon:
      print(f"UPDATE APIProduct {pname}")
      api_req("PUT", f"{APIGEE_BASE}/apiproducts/{pname}", des_canon)
      product_updates.add(pname)
    else:
      print(f"UNCHANGED APIProduct {pname}")

# 2. Ensure KVM agent-jwt-subjects exists and load existing entries (paginated)
kvm_name = "agent-jwt-subjects"
kvm_base = f"{APIGEE_BASE}/environments/{apigee_env}/keyvaluemaps"
st, live_kvm_entries = list_kvm_entries(
    f"{kvm_base}/{kvm_name}/entries", allow_404=True
)
if st == 404:
  print(f"CREATE KVM {kvm_name} in {apigee_env}")
  api_req("POST", kvm_base, {"name": kvm_name, "encrypted": True})
  live_kvm_entries = {}

# Ensure static KVM entries from env-config.json (plus optional AGENTS_CLUSTER_OIDC_JWKS)
static_kvm = (
    (env_cfg.get("keyValueMaps") or {})
    .get(kvm_name, {})
    .get("staticEntries", {})
)
desired_static_kvm = dict(static_kvm)
if os.environ.get("AGENTS_CLUSTER_OIDC_JWKS_B64"):
  desired_static_kvm["agents_cluster_oidc_jwks"] = base64.b64decode(
      os.environ["AGENTS_CLUSTER_OIDC_JWKS_B64"]
  ).decode("utf-8")
elif os.environ.get("AGENTS_CLUSTER_OIDC_JWKS"):
  desired_static_kvm["agents_cluster_oidc_jwks"] = os.environ[
      "AGENTS_CLUSTER_OIDC_JWKS"
  ]
jwks_raw = desired_static_kvm.get("agents_cluster_oidc_jwks", "").strip()
if not jwks_raw or "YOUR_" in jwks_raw:
  raise RuntimeError(
      "ERROR: agents_cluster_oidc_jwks is empty or contains a YOUR_* placeholder; refusing to write KVM."
  )
try:
  jwks_obj = json.loads(jwks_raw)
  if not isinstance(jwks_obj, dict) or not jwks_obj.get("keys"):
    raise ValueError("missing non-empty 'keys' array")
except Exception as exc:
  raise RuntimeError(f"ERROR: agents_cluster_oidc_jwks is not valid JWKS JSON: {exc}") from exc
for k, v in sorted(desired_static_kvm.items()):
  if k not in live_kvm_entries:
    print(f"CREATE static KVM entry {k}")
    api_req(
        "POST",
        f"{kvm_base}/{kvm_name}/entries",
        {"name": k, "value": v},
    )
    live_kvm_entries[k] = v
  elif live_kvm_entries[k] != v:
    print(f"UPDATE static KVM entry {k}")
    api_req(
        "PUT",
        f"{kvm_base}/{kvm_name}/entries/{urllib.parse.quote(k, safe='')}",
        {"name": k, "value": v},
    )
    live_kvm_entries[k] = v

# 3. Reconcile Developer, Developer Apps, Secret Manager keys, and KVM entries per active agent manifest
desired_app_names = set()
developers_checked = set()

for m in agent_manifests:
  agent_name = m["name"]
  app_cfg = m["apigeeApp"]
  app_name = app_cfg["name"]
  dev_email = app_cfg["developerEmail"]
  desired_app_names.add((dev_email, app_name))
  expected_sub = m["kubernetesIdentity"]["expectedJwtSubject"]
  secret_name = m["secretManagerSecret"]
  desired_prods = agent_effective_products.get(agent_name, [])

  # Ensure developer exists
  if dev_email not in developers_checked:
    st_dev, _ = api_req(
        "GET",
        f"{APIGEE_BASE}/developers/{urllib.parse.quote(dev_email, safe='@.')}",
        allow_404=True,
    )
    if st_dev == 404:
      print(f"CREATE Developer {dev_email}")
      api_req(
          "POST",
          f"{APIGEE_BASE}/developers",
          {
              "email": dev_email,
              "firstName": "HybridAgents",
              "lastName": "Platform",
              "userName": dev_email.split("@")[0],
              "attributes": [{"name": "managed_by", "value": MANAGED_BY_VALUE}],
          },
      )
    developers_checked.add(dev_email)

  app_created = False
  app_updated = any(p in product_updates for p in desired_prods)

  app_url = f"{APIGEE_BASE}/developers/{urllib.parse.quote(dev_email, safe='@.')}/apps/{urllib.parse.quote(app_name, safe='')}"
  st_app, live_app = api_req("GET", app_url, allow_404=True)

  desired_key_version = str(app_cfg.get("keyVersion", "v1"))
  base_desired_attrs = {
      "business_unit": str(app_cfg.get("businessUnit", "hybrid-agents")),
      "cost_center": str(app_cfg.get("costCenter", "CC-HYBRID-001")),
      "expected_jwt_sub": expected_sub,
      "keySecret": secret_name,
      "managed_agent": agent_name,
      "managed_by": MANAGED_BY_VALUE,
  }
  if desired_key_version != "v1":
    base_desired_attrs["key_version"] = desired_key_version

  if st_app == 404:
    print(f"CREATE DeveloperApp {app_name} for agent {agent_name}")
    _, live_app = api_req(
        "POST",
        f"{APIGEE_BASE}/developers/{urllib.parse.quote(dev_email, safe='@.')}/apps",
        {
            "name": app_name,
            "apiProducts": desired_prods,
            "attributes": dict_to_attrs(base_desired_attrs),
        },
    )
    app_created = True
  else:
    live_attrs_pre = attrs_to_dict(live_app.get("attributes"))
    if live_attrs_pre.get("key_version", "v1") != desired_key_version:
      print(
          f"ROTATE DeveloperApp {app_name} key"
          f" (key_version={live_attrs_pre.get('key_version', 'v1')} -> {desired_key_version})"
      )
      new_key = f"hca-{secrets.token_hex(16)}"
      new_sec = secrets.token_hex(24)
      api_req(
          "POST",
          f"{app_url}/keys/create",
          {"consumerKey": new_key, "consumerSecret": new_sec},
      )
      api_req(
          "POST",
          f"{app_url}/keys/{urllib.parse.quote(new_key, safe='')}",
          {"apiProducts": desired_prods},
      )
      prev_creds = sorted(
          [
              c
              for c in (live_app.get("credentials") or [])
              if c.get("status") == "approved"
          ],
          key=lambda c: int(c.get("issuedAt", 0)),
          reverse=True,
      )
      # Make-before-break: retain the immediately prior key (N-1) alongside new_key (N)
      # during the ESO + Kubelet propagation window; prune any older keys (N-2+).
      for old_c in prev_creds[1:]:
        old_k = old_c.get("consumerKey")
        if old_k and old_k != new_key:
          api_req(
              "DELETE",
              f"{app_url}/keys/{urllib.parse.quote(old_k, safe='')}",
          )
      _, live_app = api_req("GET", app_url)
      app_updated = True

  # Select active approved credential (newest issuedAt first)
  creds = [
      c
      for c in (live_app.get("credentials") or [])
      if c.get("status") == "approved"
  ]
  if not creds:
    raise RuntimeError(f"DeveloperApp {app_name} has no approved credentials")
  creds.sort(key=lambda c: int(c.get("issuedAt", 0)), reverse=True)
  active_cred = creds[0]
  consumer_key = active_cred["consumerKey"]
  key_sha256 = hashlib.sha256(consumer_key.encode("utf-8")).hexdigest()
  expected_key_marker = f"{key_sha256}:{secret_name}"

  # Reconcile products on active_cred and detach removed products from all approved credentials
  for idx, cred in enumerate(creds):
    ck = cred["consumerKey"]
    cur_cred_prods = sorted([
        ap["apiproduct"]
        for ap in (cred.get("apiProducts") or [])
        if ap.get("status") == "approved"
    ])
    if cur_cred_prods != desired_prods:
      key_url = f"{app_url}/keys/{urllib.parse.quote(ck, safe='')}"
      if idx == 0:
        print(f"UPDATE DeveloperApp {app_name} credential products -> {desired_prods}")
        if desired_prods:
          api_req("POST", key_url, {"apiProducts": desired_prods})
      for old_p in cur_cred_prods:
        if old_p not in desired_prods:
          api_req(
              "DELETE",
              f"{key_url}/apiproducts/{urllib.parse.quote(old_p, safe='')}",
          )
      app_updated = True

  # Check if Secret Manager secret version needs to be written (only when key changed)
  live_attrs = attrs_to_dict(live_app.get("attributes"))
  if live_attrs.get("secret_key_sha256") != expected_key_marker:
    add_secret_version(secret_name, consumer_key)
    if not app_created:
      app_updated = True

  # Check if DeveloperApp attributes need updating
  desired_attrs = dict(base_desired_attrs)
  desired_attrs["secret_key_sha256"] = expected_key_marker
  if live_attrs != desired_attrs:
    print(f"UPDATE DeveloperApp {app_name} attributes (key_sha256={key_sha256[:12]}...)")
    api_req(
        "PUT",
        app_url,
        {
            "name": app_name,
            "attributes": dict_to_attrs(desired_attrs),
        },
    )
    if not app_created:
      app_updated = True

  # Reconcile KVM entry in agent-jwt-subjects: app_name -> expected_sub
  if app_name not in live_kvm_entries:
    print(f"CREATE KVM entry {kvm_name}/{app_name} -> {expected_sub}")
    api_req(
        "POST",
        f"{kvm_base}/{kvm_name}/entries",
        {"name": app_name, "value": expected_sub},
    )
    live_kvm_entries[app_name] = expected_sub
    if not app_created:
      app_updated = True
  elif live_kvm_entries[app_name] != expected_sub:
    print(f"UPDATE KVM entry {kvm_name}/{app_name} -> {expected_sub}")
    api_req(
        "PUT",
        f"{kvm_base}/{kvm_name}/entries/{urllib.parse.quote(app_name, safe='')}",
        {"name": app_name, "value": expected_sub},
    )
    live_kvm_entries[app_name] = expected_sub
    if not app_created:
      app_updated = True
  else:
    print(f"UNCHANGED KVM entry {kvm_name}/{app_name}")

  if app_created:
    created_count += 1
  elif app_updated:
    updated_count += 1
  else:
    print(f"UNCHANGED Agent identity {agent_name} (app={app_name})")
    noop_count += 1

# 4. Delete pipeline-managed Developer Apps, KVM entries, and Secret Manager key versions for removed manifests.
# Scan all developers in the org (filtering strictly on app attribute managed_by==MANAGED_BY_VALUE)
# so pruning still runs when 0 agents remain active, even under pre-existing developers.
all_developers = set(developers_checked)
_, developer_items = list_apigee_paginated(
    f"{APIGEE_BASE}/developers", "developer", "email", expand=True
)
for dev_obj in developer_items:
  d_email = str(dev_obj.get("email") or "").strip()
  if d_email:
    all_developers.add(d_email)

active_secret_names = {m["secretManagerSecret"] for m in agent_manifests}
for dev_email in sorted(all_developers):
  st_apps, app_items = list_apigee_paginated(
      f"{APIGEE_BASE}/developers/{urllib.parse.quote(dev_email, safe='@.')}/apps",
      "app",
      "appId",
      expand=False,
      allow_404=True,
  )
  if st_apps == 404:
    continue
  for app_ref in app_items:
    aname = (
        str(app_ref.get("appId") or app_ref.get("name") or "").strip()
        if isinstance(app_ref, dict)
        else str(app_ref).strip()
    )
    if not aname or (dev_email, aname) in desired_app_names:
      continue
    st_detail, app_obj = api_req(
        "GET",
        f"{APIGEE_BASE}/developers/{urllib.parse.quote(dev_email, safe='@.')}/apps/{urllib.parse.quote(aname, safe='')}",
        allow_404=True,
    )
    if st_detail == 404 or not isinstance(app_obj, dict):
      continue
    a_attrs = attrs_to_dict(app_obj.get("attributes"))
    if a_attrs.get("managed_by") != MANAGED_BY_VALUE:
      # Never touch or print secret names for apps that are not pipeline-managed
      continue
    # Step 4a: Read keySecret attribute from pipeline-managed DeveloperApp before deleting it
    secret_to_destroy = a_attrs.get("keySecret", "").strip()
    if not secret_to_destroy and ":" in a_attrs.get("secret_key_sha256", ""):
      secret_to_destroy = a_attrs["secret_key_sha256"].split(":", 1)[1].strip()
    # Step 4b: Delete DeveloperApp (revokes Apigee consumer keys; exits non-zero if this fails)
    print(f"DELETE removed pipeline-managed DeveloperApp {aname}")
    api_req(
        "DELETE",
        f"{APIGEE_BASE}/developers/{urllib.parse.quote(dev_email, safe='@.')}/apps/{urllib.parse.quote(aname, safe='')}",
    )
    deleted_count += 1
    # Step 4c: Delete KVM entry in agent-jwt-subjects
    if aname in live_kvm_entries:
      print(f"DELETE KVM entry {kvm_name}/{aname}")
      try:
        api_req(
            "DELETE",
            f"{kvm_base}/{kvm_name}/entries/{urllib.parse.quote(aname, safe='')}",
        )
      except Exception as exc:
        print(f"WARN: Failed to delete KVM entry {kvm_name}/{aname}: {exc}")
    # Step 4d: Destroy all ENABLED/DISABLED versions of the agent's Secret Manager key secret
    if secret_to_destroy and secret_to_destroy not in active_secret_names:
      d_cnt, err_cnt = destroy_secret_versions(secret_to_destroy, aname)
      secret_versions_destroyed += d_cnt
      secret_version_destroy_errors += err_cnt
    elif not secret_to_destroy:
      print(
          f"WARN: Removed pipeline-managed DeveloperApp {aname} had no keySecret attribute; skipping secret version destruction."
      )

# 5. Delete unreferenced pipeline-managed API Products (for removed agents or removed MCP servers)
_, live_prod_items = list_apigee_paginated(
    f"{APIGEE_BASE}/apiproducts", "apiProduct", "name", expand=True
)
for prod_obj in live_prod_items:
  pname = str(prod_obj.get("name") or "").strip()
  if not pname or pname in desired_product_names:
    continue
  p_attrs = attrs_to_dict(prod_obj.get("attributes"))
  if p_attrs.get("managed_by") != MANAGED_BY_VALUE:
    continue
  print(f"DELETE unreferenced pipeline-managed APIProduct {pname}")
  try:
    api_req(
        "DELETE",
        f"{APIGEE_BASE}/apiproducts/{urllib.parse.quote(pname, safe='')}",
    )
    products_deleted_count += 1
  except RuntimeError as exc:
    print(
        f"WARN: Could not delete pipeline-managed APIProduct {pname} (may still be referenced by a non-managed app): {exc}"
    )

summary_obj = {
    "created": created_count,
    "deleted": deleted_count,
    "products_deleted": products_deleted_count,
    "secret_versions_destroyed": secret_versions_destroyed,
    "unchanged": noop_count,
    "updated": updated_count,
}
if secret_version_destroy_errors > 0:
  summary_obj["secret_version_destroy_errors"] = secret_version_destroy_errors
print(
    json.dumps(
        summary_obj,
        sort_keys=True,
        separators=(",", ":"),
    )
)
if secret_version_destroy_errors > 0:
  print(
      f"ERROR: Failed to destroy {secret_version_destroy_errors} Secret Manager version(s) for removed agent(s).",
      file=sys.stderr,
  )
  sys.exit(1)
EOF
