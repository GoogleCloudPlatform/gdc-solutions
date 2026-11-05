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

# Idempotently reconciles Apigee environment configuration (TargetServers,
# PropertySet `hybrid_agents_env`, and KVM `ai-model-aliases`) and all 10
# Apigee proxy bundles in `apigee/proxies/` using content-hash (SHA-256)
# comparison against the deployed revision's `<Description>` tag (Wave ID-SYNC:
# I3, I7.a, I7.b).

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ID="${PROJECT_ID:-}"
APIGEE_ENV="${APIGEE_ENV:-hybrid-agents-env}"
APIGEE_RUNTIME_SA="${APIGEE_RUNTIME_SA:-}"
if [[ -z "${APIGEE_RUNTIME_SA}" && -n "${PROJECT_ID}" ]]; then
  APIGEE_RUNTIME_SA="apigee-non-prod@${PROJECT_ID}.iam.gserviceaccount.com"
fi
GATEWAY_FQDN="${GATEWAY_FQDN:-}"
MODEL_ARMOR_LOCATION="${MODEL_ARMOR_LOCATION:-us-central1}"
AGENTS_CLUSTER_NAME="${AGENTS_CLUSTER_NAME:-}"
GATEWAY_CLUSTER_NAME="${GATEWAY_CLUSTER_NAME:-}"
MODEL_CLUSTER_NAME="${MODEL_CLUSTER_NAME:-}"
AGENTS_INGRESS_HOST="${AGENTS_INGRESS_HOST:-}"
MCP_TOOLBOX_HOST="${MCP_TOOLBOX_HOST:-mcp-toolbox.mcp-tools.svc.cluster.local}"
VLLM_INGRESS_HOST="${VLLM_INGRESS_HOST:-}"
PROXIES_DIR="${PROXIES_DIR:-${REPO_ROOT}/apigee/proxies}"
ENV_CONFIG_FILE="${ENV_CONFIG_FILE:-${REPO_ROOT}/apigee/environments/env-config.json}"

for VAR_NAME in \
  PROJECT_ID \
  APIGEE_ENV \
  APIGEE_RUNTIME_SA \
  GATEWAY_FQDN \
  MODEL_ARMOR_LOCATION \
  AGENTS_CLUSTER_NAME \
  GATEWAY_CLUSTER_NAME \
  MODEL_CLUSTER_NAME \
  AGENTS_INGRESS_HOST \
  MCP_TOOLBOX_HOST \
  VLLM_INGRESS_HOST; do
  VAR_VAL="${!VAR_NAME:-}"
  if [[ -z "${VAR_VAL}" || "${VAR_VAL}" == YOUR_* || "${VAR_VAL}" == *YOUR_* ]]; then
    echo "ERROR: Required variable ${VAR_NAME} is empty or still set to a YOUR_* placeholder ('${VAR_VAL}'). Configure all Cloud Build trigger substitutions before running sync-apigee-proxies.sh." >&2
    exit 1
  fi
done

PYTHON_BIN="$(command -v python3 || gcloud info --format='value(basic.python_location)' 2>/dev/null || true)"
if [[ -z "${PYTHON_BIN}" || ! -x "${PYTHON_BIN}" ]]; then
  echo "ERROR: Python 3 runtime not found." >&2
  exit 1
fi

ACCESS_TOKEN="$(gcloud auth print-access-token --quiet)"
export ACCESS_TOKEN

"${PYTHON_BIN}" - "${PROJECT_ID}" "${APIGEE_ENV}" "${APIGEE_RUNTIME_SA}" "${GATEWAY_FQDN}" "${MODEL_ARMOR_LOCATION}" "${AGENTS_CLUSTER_NAME}" "${GATEWAY_CLUSTER_NAME}" "${MODEL_CLUSTER_NAME}" "${AGENTS_INGRESS_HOST}" "${MCP_TOOLBOX_HOST}" "${VLLM_INGRESS_HOST}" "${PROXIES_DIR}" "${ENV_CONFIG_FILE}" << 'EOF'
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

project_id = sys.argv[1]
apigee_env = sys.argv[2]
runtime_sa = sys.argv[3]
gateway_fqdn = sys.argv[4]
model_armor_loc = sys.argv[5]
agents_cluster = sys.argv[6]
gateway_cluster = sys.argv[7]
model_cluster = sys.argv[8]
agents_ingress_host = sys.argv[9]
mcp_toolbox_host = sys.argv[10]
vllm_ingress_host = sys.argv[11]
proxies_dir = Path(sys.argv[12])
env_config_file = Path(sys.argv[13])
token = os.environ["ACCESS_TOKEN"]

APIGEE_BASE = f"https://apigee.googleapis.com/v1/organizations/{project_id}"


def api_req(
    method: str,
    url: str,
    body=None,
    content_type: str = "application/json",
    allow_404: bool = False,
    raw_response: bool = False,
):
  headers = {"Authorization": f"Bearer {token}"}
  data = None
  if body is not None:
    headers["Content-Type"] = content_type
    if isinstance(body, (bytes, bytearray)):
      data = bytes(body)
    elif isinstance(body, str):
      data = body.encode("utf-8")
    else:
      data = json.dumps(body).encode("utf-8")
  req = urllib.request.Request(url, data=data, headers=headers, method=method)
  try:
    with urllib.request.urlopen(req, timeout=120) as resp:
      raw = resp.read()
      if raw_response:
        return resp.status, raw.decode("utf-8", errors="replace")
      txt = raw.decode("utf-8")
      return resp.status, (json.loads(txt) if txt else {})
  except urllib.error.HTTPError as e:
    if allow_404 and e.code == 404:
      return 404, ("" if raw_response else {})
    err_body = e.read().decode("utf-8", errors="replace")
    raise RuntimeError(f"HTTP {e.code} on {method} {url}: {err_body}") from e


# 1. Load and render env-config.json
raw_env_cfg = env_config_file.read_text(encoding="utf-8")
replacements = {
    "YOUR_PROJECT_ID": project_id,
    "YOUR_GCP_REGION": model_armor_loc,
    "YOUR_GATEWAY_FQDN": gateway_fqdn,
    "YOUR_AGENTS_CLUSTER_NAME": agents_cluster,
    "YOUR_GATEWAY_CLUSTER_NAME": gateway_cluster,
    "YOUR_MODEL_CLUSTER_NAME": model_cluster,
    "YOUR_AGENTS_INGRESS_HOST": agents_ingress_host,
    "YOUR_MCP_TOOLBOX_HOST": mcp_toolbox_host,
    "YOUR_VLLM_INGRESS_HOST": vllm_ingress_host,
}
for k, v in replacements.items():
  if not str(v).strip() or "YOUR_" in str(v):
    raise RuntimeError(
        f"ERROR: Replacement for {k} is empty or still contains a YOUR_* placeholder ('{v}'); refusing to modify Apigee."
    )
  raw_env_cfg = raw_env_cfg.replace(k, v)
if "YOUR_" in raw_env_cfg:
  raise RuntimeError(
      "ERROR: Rendered env-config.json still contains unresolved YOUR_* placeholders; refusing to modify Apigee."
  )
env_cfg = json.loads(raw_env_cfg)

def canonical_ts(t):
  ssl = t.get("sSLInfo") or {}
  c_ssl = {
      "clientAuthEnabled": bool(ssl.get("clientAuthEnabled", False)),
      "enabled": bool(ssl.get("enabled", False)),
      "ignoreValidationErrors": bool(ssl.get("ignoreValidationErrors", False)),
  }
  for k in ("keyAlias", "keyStore", "trustStore"):
    if ssl.get(k):
      c_ssl[k] = str(ssl[k])
  return {
      "host": str(t.get("host", "")),
      "isEnabled": bool(t.get("isEnabled", True)),
      "name": str(t.get("name", "")),
      "port": int(t.get("port", 443)),
      "sSLInfo": c_ssl,
  }


# 2. Reconcile TargetServers
for ts in env_cfg.get("targetServers") or []:
  ts_name = ts["name"]
  ts_url = f"{APIGEE_BASE}/environments/{apigee_env}/targetservers/{urllib.parse.quote(ts_name, safe='')}"
  st, live_ts = api_req("GET", ts_url, allow_404=True)
  if st == 404:
    print(f"CREATE TargetServer {ts_name} ({ts['host']}:{ts['port']})")
    api_req(
        "POST",
        f"{APIGEE_BASE}/environments/{apigee_env}/targetservers",
        ts,
    )
  else:
    if canonical_ts(live_ts) != canonical_ts(ts):
      print(f"UPDATE TargetServer {ts_name} ({ts['host']}:{ts['port']})")
      api_req("PUT", ts_url, ts)
    else:
      print(f"UNCHANGED TargetServer {ts_name}")

# 3. Reconcile Environment PropertySets (hybrid_agents_env.properties)
for pset_name, pset_dict in sorted((env_cfg.get("propertySets") or {}).items()):
  desired_lines = [f"{k}={pset_dict[k]}" for k in sorted(pset_dict.keys())]
  desired_props = "\n".join(desired_lines) + "\n"
  pset_get_url = f"{APIGEE_BASE}/environments/{apigee_env}/resourcefiles/properties/{urllib.parse.quote(pset_name, safe='')}"
  st, live_props = api_req(
      "GET", pset_get_url, allow_404=True, raw_response=True
  )
  if st == 404:
    print(f"CREATE PropertySet {pset_name} in {apigee_env}")
    post_url = f"{APIGEE_BASE}/environments/{apigee_env}/resourcefiles?name={urllib.parse.quote(pset_name, safe='')}&type=properties"
    api_req(
        "POST",
        post_url,
        desired_props,
        content_type="application/octet-stream",
    )
  elif live_props.strip() != desired_props.strip():
    print(f"UPDATE PropertySet {pset_name} in {apigee_env}")
    api_req(
        "PUT",
        pset_get_url,
        desired_props,
        content_type="application/octet-stream",
    )
  else:
    print(f"UNCHANGED PropertySet {pset_name}")

# 4. Ensure KVM ai-model-aliases exists and has default entries if missing
kvm_base = f"{APIGEE_BASE}/environments/{apigee_env}/keyvaluemaps"
for kvm_name, kvm_spec in sorted((env_cfg.get("keyValueMaps") or {}).items()):
  entries = kvm_spec.get("entries") or {}
  if not entries:
    continue
  st, entries_resp = api_req(
      "GET", f"{kvm_base}/{kvm_name}/entries", allow_404=True
  )
  if st == 404:
    print(f"CREATE KVM {kvm_name} in {apigee_env}")
    api_req(
        "POST",
        kvm_base,
        {"name": kvm_name, "encrypted": bool(kvm_spec.get("encrypted", True))},
    )
    entries_resp = {"keyValueEntries": []}
  live_entries = {
      e["name"]: e["value"] for e in entries_resp.get("keyValueEntries", [])
  }
  for ek, ev in sorted(entries.items()):
    if ek not in live_entries:
      print(f"CREATE KVM entry {kvm_name}/{ek} -> {ev}")
      api_req(
          "POST",
          f"{kvm_base}/{kvm_name}/entries",
          {"name": ek, "value": str(ev)},
      )

# 5. Reconcile all proxy bundles in apigee/proxies/* via SHA-256 content hash
_, depl_resp = api_req(
    "GET", f"{APIGEE_BASE}/environments/{apigee_env}/deployments"
)
deployed_revs = {}
for d in depl_resp.get("deployments", []):
  px = d.get("apiProxy")
  rev = d.get("revision")
  if px and rev:
    deployed_revs[str(px)] = str(rev)

sa_proxies = set(env_cfg.get("runtimeServiceAccountProxies") or [])
imported_count = 0
deployed_count = 0
unchanged_count = 0
newly_deployed = []

for proxy_dir in sorted(proxies_dir.iterdir()):
  if not proxy_dir.is_dir():
    continue
  apiproxy_dir = proxy_dir / "apiproxy"
  if not apiproxy_dir.is_dir():
    continue
  proxy_name = proxy_dir.name

  # Compute deterministic SHA-256 across all files under apiproxy/
  h = hashlib.sha256()
  files_map = {}
  for fpath in sorted(apiproxy_dir.rglob("*")):
    if fpath.is_file():
      rel = fpath.relative_to(proxy_dir).as_posix()
      content = fpath.read_text(encoding="utf-8")
      # Strip any existing [bundle-sha256=...] marker before hashing
      clean_content = re.sub(r"\s*\[bundle-sha256=[0-9a-f]{64}\]", "", content)
      h.update(f"{rel}\0".encode("utf-8"))
      h.update(clean_content.encode("utf-8"))
      h.update(b"\0")
      files_map[rel] = clean_content
  bundle_sha256 = h.hexdigest()
  sha_tag = f"[bundle-sha256={bundle_sha256}]"

  # Check currently deployed revision's description for matching sha_tag
  cur_rev = deployed_revs.get(proxy_name)
  if cur_rev is not None:
    st_rev, rev_meta = api_req(
        "GET",
        f"{APIGEE_BASE}/apis/{urllib.parse.quote(proxy_name, safe='')}/revisions/{cur_rev}",
        allow_404=True,
    )
    if st_rev == 200 and sha_tag in str(rev_meta.get("description", "")):
      print(
          f"UNCHANGED proxy {proxy_name} (rev={cur_rev}, sha256={bundle_sha256[:12]}...)"
      )
      unchanged_count += 1
      continue

  # Build deterministic in-memory ZIP with sha_tag stamped in <Description>
  root_xml_rel = f"apiproxy/{proxy_name}.xml"
  if root_xml_rel not in files_map:
    raise RuntimeError(f"Missing {root_xml_rel} in {proxy_dir}")
  root_xml = files_map[root_xml_rel]
  if "<Description>" in root_xml:
    root_xml = re.sub(
        r"<Description>(.*?)</Description>",
        lambda m: f"<Description>{m.group(1).strip()} {sha_tag}</Description>",
        root_xml,
        count=1,
        flags=re.DOTALL,
    )
  else:
    root_xml = root_xml.replace(
        f"</DisplayName>",
        f"</DisplayName>\n  <Description>{sha_tag}</Description>",
        1,
    )
  files_map[root_xml_rel] = root_xml

  buf = io.BytesIO()
  with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
    for rel in sorted(files_map.keys()):
      zi = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0))
      zi.external_attr = 0o644 << 16
      zf.writestr(zi, files_map[rel].encode("utf-8"))

  import_url = f"{APIGEE_BASE}/apis?action=import&name={urllib.parse.quote(proxy_name, safe='')}"
  _, imp_resp = api_req(
      "POST",
      import_url,
      buf.getvalue(),
      content_type="application/octet-stream",
  )
  new_rev = str(imp_resp["revision"])
  imported_count += 1
  print(
      f"IMPORTED proxy {proxy_name} rev={new_rev} (sha256={bundle_sha256[:12]}...)"
  )

  dep_url = f"{APIGEE_BASE}/environments/{apigee_env}/apis/{urllib.parse.quote(proxy_name, safe='')}/revisions/{new_rev}/deployments?override=true"
  if proxy_name in sa_proxies:
    dep_url += f"&serviceAccount={urllib.parse.quote(runtime_sa, safe='@.-_')}"
  api_req("POST", dep_url, None)
  deployed_count += 1
  newly_deployed.append((proxy_name, new_rev))
  print(f"DEPLOYED proxy {proxy_name} rev={new_rev} to {apigee_env}")

# 6. Poll newly deployed proxy revisions until READY
for proxy_name, new_rev in newly_deployed:
  status_url = f"{APIGEE_BASE}/environments/{apigee_env}/apis/{urllib.parse.quote(proxy_name, safe='')}/revisions/{new_rev}/deployments"
  for _ in range(36):
    _, st_obj = api_req("GET", status_url)
    state = st_obj.get("state", "")
    if state == "READY":
      print(f"READY proxy {proxy_name} rev={new_rev}")
      break
    time.sleep(5)
  else:
    raise RuntimeError(
        f"Timed out waiting for proxy {proxy_name} rev={new_rev} to reach READY"
    )

print(
    json.dumps(
        {
            "deployed": deployed_count,
            "imported": imported_count,
            "unchanged": unchanged_count,
        },
        sort_keys=True,
        separators=(",", ":"),
    )
)
EOF
