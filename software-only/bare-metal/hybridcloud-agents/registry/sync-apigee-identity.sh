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

# Idempotently reconciles per-agent Apigee identity, API products/quotas,
# Secret Manager API key versions (only when the consumer key hash changes,
# never printing keys), and the environment KVM `agent-jwt-subjects` from
# `registry/agents/*/agent.yaml` (Wave ID-SYNC: I1, I2, I5).

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

PYTHON_BIN="$(gcloud info --format='value(basic.python_location)' 2>/dev/null || command -v python3 || true)"
CLOUDSDK_THIRD_PARTY="$(gcloud info --format='value(installation.sdk_root)' 2>/dev/null || echo /usr/lib/google-cloud-sdk)/lib/third_party"
export CLOUDSDK_THIRD_PARTY
if [[ -z "${PYTHON_BIN}" || ! -x "${PYTHON_BIN}" ]]; then
  echo "ERROR: Python 3 runtime not found." >&2
  exit 1
fi

ACCESS_TOKEN="$(gcloud auth print-access-token --quiet)"
export ACCESS_TOKEN

"${PYTHON_BIN}" - "${PROJECT_ID}" "${APIGEE_ENV}" "${AGENTS_DIR}" "${PRODUCTS_FILE}" "${ENV_CONFIG_FILE}" << 'EOF'
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request

def load_yaml(text: str):
  try:
    import yaml as pyyaml
    return pyload_yaml(text)
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
products_file = Path(sys.argv[4])
env_config_file = Path(sys.argv[5])
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
  op_configs.sort(key=lambda x: x["apiSource"])
  out = {
      "approvalType": p.get("approvalType", "auto"),
      "attributes": dict_to_attrs(attrs_to_dict(p.get("attributes"))),
      "description": p.get("description", ""),
      "displayName": p.get("displayName", p.get("name", "")),
      "environments": sorted(p.get("environments") or []),
      "name": p.get("name", ""),
      "operationGroup": {
          "operationConfigType": (p.get("operationGroup") or {}).get(
              "operationConfigType", "proxy"
          ),
          "operationConfigs": op_configs,
      },
      "proxies": sorted(p.get("proxies") or []),
  }
  if p.get("quota"):
    out["quota"] = str(p["quota"])
    out["quotaInterval"] = str(p.get("quotaInterval", ""))
    out["quotaTimeUnit"] = str(p.get("quotaTimeUnit", ""))
  return out


def add_secret_version(secret_name: str, secret_val: str) -> None:
  b64_payload = base64.b64encode(secret_val.encode("utf-8")).decode("ascii")
  url = f"{SM_BASE}/secrets/{secret_name}:addVersion"
  status, resp = api_req("POST", url, {"payload": {"data": b64_payload}})
  ver_name = resp.get("name", "unknown")
  print(f"SECRET_VERSION_ADDED secret={secret_name} version={ver_name}")


# Load base API products and env config
raw_products = json.loads(products_file.read_text(encoding="utf-8"))
base_products_list = (
    raw_products
    if isinstance(raw_products, list)
    else raw_products.get("apiProduct", [])
)
base_products = {p["name"]: p for p in base_products_list}
env_cfg = json.loads(env_config_file.read_text(encoding="utf-8"))

# Load agent manifests
agent_manifests = []
for manifest_path in sorted(agents_dir.glob("*/agent.yaml")):
  m = load_yaml(manifest_path.read_text(encoding="utf-8"))
  agent_manifests.append(m)

created_count = 0
updated_count = 0
noop_count = 0
deleted_count = 0

# 1. Reconcile API Products referenced in agent manifests
product_updates = set()
for m in agent_manifests:
  allowed_models_csv = ",".join(m.get("allowedModelAliases") or [])
  for prod_override in m.get("apiProducts") or []:
    pname = prod_override["name"]
    if pname not in base_products:
      raise RuntimeError(f"API product {pname} not found in {products_file}")
    desired_prod = json.loads(json.dumps(base_products[pname]))
    attrs = attrs_to_dict(desired_prod.get("attributes"))
    if allowed_models_csv and "allowed_models" in attrs:
      attrs["allowed_models"] = allowed_models_csv
    if "allowCloudBurst" in prod_override:
      attrs["allow_cloud_burst"] = str(prod_override["allowCloudBurst"]).lower()
    if "promptTokenRate" in prod_override:
      attrs["prompt_token_rate"] = str(prod_override["promptTokenRate"])
    if "llmTokenQuotaLimit" in prod_override:
      attrs["llm_token_quota_limit"] = str(prod_override["llmTokenQuotaLimit"])
    if "llmTokenQuotaInterval" in prod_override:
      attrs["llm_token_quota_interval"] = str(
          prod_override["llmTokenQuotaInterval"]
      )
    if "llmTokenQuotaTimeUnit" in prod_override:
      attrs["llm_token_quota_time_unit"] = str(
          prod_override["llmTokenQuotaTimeUnit"]
      )
    if "spikeArrestRate" in prod_override:
      attrs["spike_arrest_rate"] = str(prod_override["spikeArrestRate"])
    if "toolQuotaLimit" in prod_override:
      attrs["tool_quota_limit"] = str(prod_override["toolQuotaLimit"])
      desired_prod["quota"] = str(prod_override["toolQuotaLimit"])
    if "toolQuotaInterval" in prod_override:
      attrs["tool_quota_interval"] = str(prod_override["toolQuotaInterval"])
      desired_prod["quotaInterval"] = str(prod_override["toolQuotaInterval"])
    if "toolQuotaTimeUnit" in prod_override:
      attrs["tool_quota_time_unit"] = str(prod_override["toolQuotaTimeUnit"])
      desired_prod["quotaTimeUnit"] = str(prod_override["toolQuotaTimeUnit"])
    desired_prod["attributes"] = dict_to_attrs(attrs)

    st, live_prod = api_req(
        "GET", f"{APIGEE_BASE}/apiproducts/{pname}", allow_404=True
    )
    des_canon = canonical_product(desired_prod)
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

# 2. Ensure KVM agent-jwt-subjects exists and load existing entries
kvm_name = "agent-jwt-subjects"
kvm_base = f"{APIGEE_BASE}/environments/{apigee_env}/keyvaluemaps"
st, _ = api_req("GET", f"{kvm_base}/{kvm_name}/entries", allow_404=True)
if st == 404:
  print(f"CREATE KVM {kvm_name} in {apigee_env}")
  api_req("POST", kvm_base, {"name": kvm_name, "encrypted": True})

_, entries_resp = api_req("GET", f"{kvm_base}/{kvm_name}/entries")
live_kvm_entries = {
    e["name"]: e["value"] for e in entries_resp.get("keyValueEntries", [])
}

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

# 3. Reconcile Developer, Developer Apps, Secret Manager keys, and KVM entries per agent manifest
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
  desired_prods = sorted([p["name"] for p in m.get("apiProducts") or []])

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

  # Check if products on active_cred match desired_prods
  cur_cred_prods = sorted([
      ap["apiproduct"]
      for ap in (active_cred.get("apiProducts") or [])
      if ap.get("status") == "approved"
  ])
  if cur_cred_prods != desired_prods:
    print(f"UPDATE DeveloperApp {app_name} credential products -> {desired_prods}")
    key_url = f"{app_url}/keys/{urllib.parse.quote(consumer_key, safe='')}"
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

# 4. Delete pipeline-managed Developer Apps and KVM entries for removed manifests
for dev_email in sorted(developers_checked):
  _, apps_resp = api_req(
      "GET",
      f"{APIGEE_BASE}/developers/{urllib.parse.quote(dev_email, safe='@.')}/apps?expand=true",
  )
  for app_obj in apps_resp.get("app", []):
    aname = app_obj.get("name", "")
    if (dev_email, aname) in desired_app_names:
      continue
    a_attrs = attrs_to_dict(app_obj.get("attributes"))
    if a_attrs.get("managed_by") == MANAGED_BY_VALUE:
      print(f"DELETE removed pipeline-managed DeveloperApp {aname}")
      api_req(
          "DELETE",
          f"{APIGEE_BASE}/developers/{urllib.parse.quote(dev_email, safe='@.')}/apps/{urllib.parse.quote(aname, safe='')}",
      )
      if aname in live_kvm_entries:
        print(f"DELETE KVM entry {kvm_name}/{aname}")
        api_req(
            "DELETE",
            f"{kvm_base}/{kvm_name}/entries/{urllib.parse.quote(aname, safe='')}",
        )
      deleted_count += 1

print(
    json.dumps(
        {
            "created": created_count,
            "deleted": deleted_count,
            "unchanged": noop_count,
            "updated": updated_count,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
)
EOF
