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

"""Read-only control-plane and Cloud Trace verifier for Hybrid Cloud AI Agents.

Uses Python 3 standard library only plus the authenticated `gcloud` CLI.
Never reads Secret Manager payloads (queries version metadata/state only).
"""

import argparse
import hashlib
import http.client
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MANAGED_BY_VALUE = "hybridcloud-agents-id-sync"
AGENT_KEY_SECRETS = (
    "apigee-ops-orchestrator-api-key",
    "apigee-sovereign-agent-api-key",
)


def get_access_token() -> str:
    env_tok = os.environ.get("CLOUDSDK_AUTH_ACCESS_TOKEN", "").strip()
    if env_tok:
        return env_tok
    for cmd in (
        ["gcloud", "auth", "application-default", "print-access-token", "--quiet"],
        ["gcloud", "auth", "print-access-token", "--quiet"],
    ):
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    raise RuntimeError(
        "Unable to obtain an OAuth access token via CLOUDSDK_AUTH_ACCESS_TOKEN or gcloud."
    )


def api_get(url: str, token: str, allow_404: bool = False):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        if allow_404 and err.code == 404:
            return 404, {}
        detail = err.read().decode("utf-8", errors="replace")[:400]
        raise RuntimeError(f"HTTP {err.code} on GET {url}: {detail}") from err


def gcloud_json(args: list[str]):
    out = subprocess.check_output(
        ["gcloud"] + args + ["--format=json", "--quiet"], text=True
    )
    return json.loads(out or "[]")


def collect_control_plane(
    project: str, region: str, apigee_org: str, apigee_env: str
) -> dict:
    token = get_access_token()

    # 1. Agent Registry services
    ar_svcs = gcloud_json(
        [
            "agent-registry",
            "services",
            "list",
            f"--location={region}",
            f"--project={project}",
        ]
    )
    ar_agents: list[str] = []
    ar_mcps: list[str] = []
    for svc in ar_svcs:
        sid = svc.get("name", "").rsplit("/", 1)[-1]
        if svc.get("agentSpec"):
            ar_agents.append(sid)
        elif svc.get("mcpServerSpec"):
            ar_mcps.append(sid)
        else:
            ar_mcps.append(f"{sid}(other)")

    # 2. Apigee pipeline-managed DeveloperApps
    _, devs_resp = api_get(
        f"https://apigee.googleapis.com/v1/organizations/{apigee_org}/developers",
        token,
    )
    devs = [
        d.get("email") for d in (devs_resp.get("developer") or []) if d.get("email")
    ]
    managed_apps: dict[str, dict] = {}
    for email in sorted(devs):
        _, apps_resp = api_get(
            f"https://apigee.googleapis.com/v1/organizations/{apigee_org}/developers/{email}/apps?expand=true",
            token,
            allow_404=True,
        )
        for app in apps_resp.get("app") or []:
            attrs = {a["name"]: a["value"] for a in (app.get("attributes") or [])}
            if attrs.get("managed_by") == MANAGED_BY_VALUE or app.get("name") in (
                "ops-orchestrator-app",
                "sovereign-agents-app",
            ):
                prods = sorted(
                    {
                        ap.get("apiproduct")
                        for cred in (app.get("credentials") or [])
                        if cred.get("status") == "approved"
                        for ap in (cred.get("apiProducts") or [])
                        if ap.get("status") == "approved"
                    }
                )
                managed_apps[app["name"]] = {
                    "managed_by": attrs.get("managed_by"),
                    "approved_products": prods,
                }

    # 3. Apigee pipeline-managed APIProducts
    _, prods_resp = api_get(
        f"https://apigee.googleapis.com/v1/organizations/{apigee_org}/apiproducts?expand=true",
        token,
    )
    managed_prods = sorted(
        p.get("name", "")
        for p in (prods_resp.get("apiProduct") or [])
        if any(
            a.get("name") == "managed_by" and a.get("value") == MANAGED_BY_VALUE
            for a in (p.get("attributes") or [])
        )
    )

    # 4. Apigee KVM agent-jwt-subjects (key names only; values redacted)
    st_kvm, kvm_resp = api_get(
        f"https://apigee.googleapis.com/v1/organizations/{apigee_org}/environments/{apigee_env}/keyvaluemaps/agent-jwt-subjects/entries",
        token,
        allow_404=True,
    )
    kvm_keys = (
        sorted(e["name"] for e in (kvm_resp.get("keyValueEntries") or []))
        if st_kvm == 200
        else []
    )

    # 5. Apigee deployed proxies in apigee_env
    _, dep_resp = api_get(
        f"https://apigee.googleapis.com/v1/organizations/{apigee_org}/environments/{apigee_env}/deployments",
        token,
    )
    deployed_proxies = sorted(
        {
            d.get("apiProxy")
            for d in (dep_resp.get("deployments") or [])
            if d.get("apiProxy")
        }
    )
    mcp_proxies_deployed = [p for p in deployed_proxies if p.startswith("mcp-")]

    # 6. Secret Manager version states (metadata only; no payload access)
    sm_state: dict[str, dict] = {}
    for secret_id in AGENT_KEY_SECRETS:
        st_sec, sec_resp = api_get(
            f"https://secretmanager.googleapis.com/v1/projects/{project}/secrets/{secret_id}/versions?pageSize=200",
            token,
            allow_404=True,
        )
        if st_sec == 404:
            sm_state[secret_id] = {
                "exists": False,
                "enabled": [],
                "disabled": [],
                "destroyed_count": 0,
            }
        else:
            vers = sec_resp.get("versions") or []
            sm_state[secret_id] = {
                "exists": True,
                "enabled": [
                    v["name"].rsplit("/", 1)[-1]
                    for v in vers
                    if v.get("state") == "ENABLED"
                ],
                "disabled": [
                    v["name"].rsplit("/", 1)[-1]
                    for v in vers
                    if v.get("state") == "DISABLED"
                ],
                "destroyed_count": sum(
                    1 for v in vers if v.get("state") == "DESTROYED"
                ),
            }

    return {
        "agent_registry": {"agents": sorted(ar_agents), "mcp_servers": sorted(ar_mcps)},
        "apigee_apps": managed_apps,
        "apigee_managed_products": managed_prods,
        "apigee_kvm_entry_keys": kvm_keys,
        "apigee_deployed_proxies": deployed_proxies,
        "apigee_mcp_proxies_deployed": mcp_proxies_deployed,
        "secret_manager_keys": sm_state,
    }


def evaluate_expectation(state: dict, expect: str) -> list[str]:
    errors: list[str] = []
    agents = state["agent_registry"]["agents"]
    mcps = state["agent_registry"]["mcp_servers"]
    apps = state["apigee_apps"]
    kvm_keys = set(state["apigee_kvm_entry_keys"])
    mcp_proxies = set(state["apigee_mcp_proxies_deployed"])
    sm = state["secret_manager_keys"]

    if expect == "current":
        return []

    if expect == "empty":
        if agents:
            errors.append(f"Expected 0 Agent Registry agents, found {agents}")
        if mcps:
            errors.append(f"Expected 0 Agent Registry MCP servers, found {mcps}")
        if apps:
            errors.append(f"Expected 0 managed Apigee apps, found {sorted(apps)}")
        if "mcp-toolbox-v1" in mcp_proxies:
            errors.append("Expected mcp-toolbox-v1 to be undeployed")
        for app_name in ("ops-orchestrator-app", "sovereign-agents-app"):
            if app_name in kvm_keys:
                errors.append(f"Expected KVM entry {app_name} to be deleted")
        for sec_id in AGENT_KEY_SECRETS:
            if sm[sec_id]["enabled"] or sm[sec_id]["disabled"]:
                errors.append(
                    f"Expected 0 enabled/disabled versions on {sec_id}, found enabled={sm[sec_id]['enabled']} disabled={sm[sec_id]['disabled']}"
                )
        return errors

    if expect == "step1":
        if agents != ["adk-ops-orchestrator"]:
            errors.append(f"Expected agents=['adk-ops-orchestrator'], found {agents}")
        if mcps:
            errors.append(f"Expected mcp_servers=[], found {mcps}")
        if "mcp-toolbox-v1" in mcp_proxies:
            errors.append("Expected mcp-toolbox-v1 to be undeployed in Step 1")
        if sm["apigee-sovereign-agent-api-key"]["enabled"]:
            errors.append(
                "Expected 0 enabled versions on apigee-sovereign-agent-api-key in Step 1"
            )

    if expect in ("step1", "step1-min"):
        if "adk-ops-orchestrator" not in agents:
            errors.append(
                f"Expected adk-ops-orchestrator in Agent Registry, found {agents}"
            )
        ops_app = apps.get("ops-orchestrator-app")
        if not ops_app or "cloud-eligible-agents" not in ops_app["approved_products"]:
            errors.append(
                f"Expected ops-orchestrator-app with cloud-eligible-agents, found {ops_app}"
            )
        if not sm["apigee-ops-orchestrator-api-key"]["enabled"]:
            errors.append(
                "Expected >=1 ENABLED version on apigee-ops-orchestrator-api-key"
            )
        return errors

    if expect == "step2":
        if agents != ["adk-ops-orchestrator"]:
            errors.append(f"Expected agents=['adk-ops-orchestrator'], found {agents}")
        if mcps != ["mcp-toolbox"]:
            errors.append(f"Expected mcp_servers=['mcp-toolbox'], found {mcps}")

    if expect in ("step2", "step2-min"):
        if "adk-ops-orchestrator" not in agents:
            errors.append(
                f"Expected adk-ops-orchestrator in Agent Registry, found {agents}"
            )
        if "mcp-toolbox" not in mcps:
            errors.append(f"Expected mcp-toolbox in Agent Registry, found {mcps}")
        if "mcp-toolbox-v1" not in mcp_proxies:
            errors.append(
                f"Expected mcp-toolbox-v1 deployed, found {sorted(mcp_proxies)}"
            )
        ops_app = apps.get("ops-orchestrator-app")
        if (
            not ops_app
            or "cloud-eligible-agents-mcp" not in ops_app["approved_products"]
        ):
            errors.append(
                f"Expected ops-orchestrator-app with cloud-eligible-agents-mcp, found {ops_app}"
            )
        return errors

    if expect == "step3":
        for req_agent in ("adk-ops-orchestrator", "adk-sovereign-agent"):
            if req_agent not in agents:
                errors.append(f"Missing agent {req_agent} in Agent Registry ({agents})")
        if "mcp-toolbox" not in mcps:
            errors.append(f"Missing mcp-toolbox in Agent Registry ({mcps})")
        if "mcp-toolbox-v1" not in mcp_proxies:
            errors.append(
                f"Expected mcp-toolbox-v1 deployed, found {sorted(mcp_proxies)}"
            )
        ops_app = apps.get("ops-orchestrator-app")
        sov_app = apps.get("sovereign-agents-app")
        for prod in (
            "a2a-sovereign-callers",
            "cloud-eligible-agents",
            "cloud-eligible-agents-mcp",
        ):
            if not ops_app or prod not in ops_app["approved_products"]:
                errors.append(
                    f"ops-orchestrator-app missing approved product {prod} ({ops_app})"
                )
        for prod in ("sovereign-agents", "sovereign-agents-mcp"):
            if not sov_app or prod not in sov_app["approved_products"]:
                errors.append(
                    f"sovereign-agents-app missing approved product {prod} ({sov_app})"
                )
        for sec_id in AGENT_KEY_SECRETS:
            if not sm[sec_id]["enabled"]:
                errors.append(f"Expected >=1 ENABLED version on {sec_id}")
        return errors

    raise ValueError(f"Unknown expectation mode: {expect}")


def cmd_inspect(args: argparse.Namespace) -> int:
    state = collect_control_plane(
        project=args.project,
        region=args.region,
        apigee_org=args.apigee_org or args.project,
        apigee_env=args.apigee_env,
    )
    errors = evaluate_expectation(state, args.expect)
    output = {
        "expect": args.expect,
        "passed": len(errors) == 0,
        "errors": errors,
        "state": state,
    }
    print(json.dumps(output, indent=2))
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump(output, handle, indent=2)
    return 0 if not errors else 1


def cmd_trace(args: argparse.Namespace) -> int:
    token = get_access_token()
    status, data = api_get(
        f"https://cloudtrace.googleapis.com/v1/projects/{args.project}/traces/{args.trace_id}",
        token,
        allow_404=True,
    )
    if status == 404:
        print(
            json.dumps(
                {
                    "traceId": args.trace_id,
                    "spanCount": 0,
                    "clusters": [],
                    "spansByCluster": {},
                    "passed": False,
                    "errors": ["Trace not found in Cloud Trace API (HTTP 404)."],
                },
                indent=2,
            )
        )
        return 1

    spans = data.get("spans") or []
    by_cluster: dict[str, int] = {}
    for span in spans:
        cluster = (span.get("labels") or {}).get("k8s.cluster.name") or "unlabeled"
        by_cluster[cluster] = by_cluster.get(cluster, 0) + 1

    clusters = sorted(by_cluster)
    expected = [
        c.strip() for c in (args.expected_clusters or "").split(",") if c.strip()
    ]
    errors: list[str] = []
    if len(spans) < args.min_spans:
        errors.append(f"Expected at least {args.min_spans} spans, found {len(spans)}.")
    for exp_cluster in expected:
        if exp_cluster not in by_cluster:
            errors.append(
                f"Expected cluster '{exp_cluster}' in trace spans, saw {clusters}."
            )

    summary = {
        "traceId": data.get("traceId", args.trace_id),
        "spanCount": len(spans),
        "clusters": clusters,
        "spansByCluster": by_cluster,
        "passed": len(errors) == 0,
        "errors": errors,
    }
    print(json.dumps(summary, indent=2))
    return 0 if not errors else 1


class _HostnameHTTPSConnection(http.client.HTTPSConnection):
    """HTTPSConnection verifying TLS against gateway_fqdn while connecting to host:port."""

    def __init__(
        self,
        connect_host: str,
        connect_port: int,
        server_hostname: str,
        context: ssl.SSLContext,
        timeout: float = 10.0,
    ) -> None:
        super().__init__(connect_host, connect_port, timeout=timeout, context=context)
        self._server_hostname = server_hostname

    def connect(self) -> None:
        sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock = self._context.wrap_socket(
            sock, server_hostname=self._server_hostname
        )


def _probe_gateway_with_key(
    gateway_fqdn: str,
    connect_host: str,
    connect_port: int,
    ca_file: str,
    path: str,
    api_key: str,
) -> dict:
    ctx = ssl.create_default_context(cafile=ca_file)
    conn = _HostnameHTTPSConnection(
        connect_host=connect_host,
        connect_port=connect_port,
        server_hostname=gateway_fqdn,
        context=ctx,
        timeout=15.0,
    )
    try:
        conn.request(
            "GET",
            path,
            headers={
                "Accept": "application/json",
                "Host": gateway_fqdn,
                "x-api-key": api_key,
            },
        )
        resp = conn.getresponse()
        raw = resp.read().decode("utf-8", errors="replace")
        fault_code = ""
        try:
            body_obj = json.loads(raw)
            if isinstance(body_obj, dict):
                fault_code = (
                    (body_obj.get("fault") or {}).get("detail", {}).get("errorcode", "")
                )
        except ValueError:
            pass
        return {
            "status": resp.status,
            "fault_code": fault_code,
            "error": "",
        }
    except Exception as exc:
        return {
            "status": 0,
            "fault_code": "",
            "error": f"{type(exc).__name__}: {exc}",
        }
    finally:
        conn.close()


def _find_developer_app(
    apigee_org: str, app_name: str, developer_email: str, token: str
) -> tuple[str, dict]:
    base = f"https://apigee.googleapis.com/v1/organizations/{apigee_org}"
    if developer_email:
        st, app_obj = api_get(
            f"{base}/developers/{urllib.parse.quote(developer_email, safe='@.')}/apps/{urllib.parse.quote(app_name, safe='')}",
            token,
            allow_404=True,
        )
        if st == 200 and isinstance(app_obj, dict):
            return developer_email, app_obj
        raise RuntimeError(
            f"DeveloperApp '{app_name}' not found under developer '{developer_email}'."
        )

    _, devs_resp = api_get(f"{base}/developers", token)
    for dev in devs_resp.get("developer") or []:
        email = str(dev.get("email") or "").strip()
        if not email:
            continue
        st, app_obj = api_get(
            f"{base}/developers/{urllib.parse.quote(email, safe='@.')}/apps/{urllib.parse.quote(app_name, safe='')}",
            token,
            allow_404=True,
        )
        if st == 200 and isinstance(app_obj, dict):
            return email, app_obj
    raise RuntimeError(
        f"DeveloperApp '{app_name}' not found in Apigee org '{apigee_org}'."
    )


def _cred_meta(cred: dict, fallback_rotated_at: int, now_epoch: int) -> dict:
    ck = str(cred.get("consumerKey") or "")
    attrs = {
        str(a.get("name")): str(a.get("value"))
        for a in (cred.get("attributes") or [])
        if a.get("name") is not None
    }
    issued_epoch = int(cred.get("issuedAt") or 0) // 1000
    rotated_at = 0
    if attrs.get("rotated_out_at"):
        try:
            rotated_at = int(attrs["rotated_out_at"])
        except ValueError:
            rotated_at = 0
    if rotated_at <= 0:
        rotated_at = fallback_rotated_at
    elapsed = max(0, now_epoch - rotated_at) if rotated_at > 0 else -1
    return {
        "key_sha256": hashlib.sha256(ck.encode("utf-8")).hexdigest()[:12],
        "status": str(cred.get("status") or ""),
        "issued_at_epoch": issued_epoch,
        "rotated_out_at": rotated_at,
        "elapsed_seconds": elapsed,
    }


def cmd_rotate_probe(args: argparse.Namespace) -> int:
    token = get_access_token()
    apigee_org = args.apigee_org or args.project
    now_epoch = int(time.time())
    dev_email, app_obj = _find_developer_app(
        apigee_org=apigee_org,
        app_name=args.app_name,
        developer_email=args.developer_email,
        token=token,
    )
    app_attrs = {
        str(a.get("name")): str(a.get("value"))
        for a in (app_obj.get("attributes") or [])
        if a.get("name") is not None
    }
    key_version = app_attrs.get("key_version", "v1")
    app_rotated_at = 0
    if app_attrs.get("key_rotated_at"):
        try:
            app_rotated_at = int(app_attrs["key_rotated_at"])
        except ValueError:
            app_rotated_at = 0

    all_creds = sorted(
        app_obj.get("credentials") or [],
        key=lambda c: int(c.get("issuedAt") or 0),
        reverse=True,
    )
    approved = [
        c for c in all_creds if str(c.get("status") or "").lower() == "approved"
    ]
    revoked = [c for c in all_creds if str(c.get("status") or "").lower() == "revoked"]

    active_cred = approved[0] if approved else None
    prev_approved = approved[1] if len(approved) > 1 else None
    prev_revoked = revoked[0] if revoked else None

    active_issued_epoch = (
        int(active_cred.get("issuedAt") or 0) // 1000 if active_cred else 0
    )
    fallback_rot = app_rotated_at or active_issued_epoch

    if args.phase == "auto":
        if prev_approved is not None:
            effective_phase = "grace"
        elif prev_revoked is not None:
            effective_phase = "revoked"
        else:
            effective_phase = "single"
    else:
        effective_phase = args.phase

    connect_host = args.connect_host or args.gateway_fqdn
    active_probe = None
    prev_approved_probe = None
    prev_revoked_probe = None

    if args.ca_file:
        if active_cred is not None:
            active_probe = _probe_gateway_with_key(
                gateway_fqdn=args.gateway_fqdn,
                connect_host=connect_host,
                connect_port=args.connect_port,
                ca_file=args.ca_file,
                path=args.path,
                api_key=str(active_cred["consumerKey"]),
            )
        if prev_approved is not None:
            prev_approved_probe = _probe_gateway_with_key(
                gateway_fqdn=args.gateway_fqdn,
                connect_host=connect_host,
                connect_port=args.connect_port,
                ca_file=args.ca_file,
                path=args.path,
                api_key=str(prev_approved["consumerKey"]),
            )
        if prev_revoked is not None:
            prev_revoked_probe = _probe_gateway_with_key(
                gateway_fqdn=args.gateway_fqdn,
                connect_host=connect_host,
                connect_port=args.connect_port,
                ca_file=args.ca_file,
                path=args.path,
                api_key=str(prev_revoked["consumerKey"]),
            )

    errors: list[str] = []
    if active_cred is None:
        errors.append(f"DeveloperApp '{args.app_name}' has no approved active key.")
    elif args.ca_file and (active_probe or {}).get("status") != 200:
        errors.append(
            f"Active key probe returned HTTP {(active_probe or {}).get('status')} "
            f"(error={(active_probe or {}).get('error')})"
        )

    if effective_phase == "grace":
        if len(approved) != 2 or prev_approved is None:
            errors.append(
                f"Expected 2 approved keys during grace period (N and N-1), found {len(approved)}."
            )
        else:
            prev_meta = _cred_meta(prev_approved, fallback_rot, now_epoch)
            if prev_meta["rotated_out_at"] <= 0:
                errors.append(
                    "Previous key N-1 has no rotated_out_at / key_rotated_at timestamp."
                )
            if (
                args.grace_seconds > 0
                and prev_meta["elapsed_seconds"] >= args.grace_seconds
            ):
                errors.append(
                    f"Previous key N-1 elapsed={prev_meta['elapsed_seconds']}s >= grace={args.grace_seconds}s "
                    "(grace window already expired; re-run sync-apigee-identity.sh to revoke)."
                )
            if args.ca_file and (prev_approved_probe or {}).get("status") != 200:
                errors.append(
                    f"Previous key N-1 during grace expected HTTP 200, got HTTP {(prev_approved_probe or {}).get('status')} "
                    f"(fault={(prev_approved_probe or {}).get('fault_code')} error={(prev_approved_probe or {}).get('error')})"
                )
    elif effective_phase == "revoked":
        if len(approved) != 1:
            errors.append(
                f"Expected exactly 1 approved key after revocation, found {len(approved)}."
            )
        if prev_revoked is None:
            errors.append(
                "Expected >=1 revoked previous key (N-1) on DeveloperApp, found 0."
            )
        elif args.ca_file and (prev_revoked_probe or {}).get("status") != 401:
            errors.append(
                f"Revoked previous key N-1 expected HTTP 401, got HTTP {(prev_revoked_probe or {}).get('status')} "
                f"(fault={(prev_revoked_probe or {}).get('fault_code')} error={(prev_revoked_probe or {}).get('error')})"
            )
    elif effective_phase == "deleted":
        if len(approved) != 1 or len(revoked) != 0:
            errors.append(
                f"Expected 1 approved and 0 revoked keys after Stage-2 deletion, "
                f"found approved={len(approved)} revoked={len(revoked)}."
            )
    else:
        errors.append(
            f"DeveloperApp '{args.app_name}' has {len(approved)} approved and {len(revoked)} revoked key(s); "
            "no in-grace or revoked previous key found (bump apigeeApp.keyVersion and run the pipeline first, "
            "or pass --phase=deleted after Stage-2 cleanup)."
        )

    out = {
        "app_name": args.app_name,
        "developer_email": dev_email,
        "key_version": key_version,
        "key_rotated_at": app_rotated_at,
        "requested_phase": args.phase,
        "effective_phase": effective_phase,
        "approved_count": len(approved),
        "revoked_count": len(revoked),
        "active_key": (
            _cred_meta(active_cred, 0, now_epoch) if active_cred is not None else None
        ),
        "previous_approved_key": (
            _cred_meta(prev_approved, fallback_rot, now_epoch)
            if prev_approved is not None
            else None
        ),
        "previous_revoked_key": (
            _cred_meta(prev_revoked, fallback_rot, now_epoch)
            if prev_revoked is not None
            else None
        ),
        "active_probe": active_probe,
        "previous_approved_probe": prev_approved_probe,
        "previous_revoked_probe": prev_revoked_probe,
        "passed": len(errors) == 0,
        "errors": errors,
    }
    print(json.dumps(out, indent=2))
    return 0 if not errors else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Read-only control-plane and Cloud Trace verifier for Hybrid Cloud AI Agents."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_inspect = sub.add_parser(
        "inspect", help="Inspect Agent Registry, Apigee, and Secret Manager metadata."
    )
    p_inspect.add_argument("--project", required=True)
    p_inspect.add_argument("--region", default="us-central1")
    p_inspect.add_argument("--apigee-org", default="")
    p_inspect.add_argument("--apigee-env", default="hybrid-agents-env")
    p_inspect.add_argument(
        "--expect",
        default="current",
        choices=(
            "current",
            "empty",
            "step1",
            "step1-min",
            "step2",
            "step2-min",
            "step3",
        ),
    )
    p_inspect.add_argument("--json-out", default="")
    p_inspect.set_defaults(func=cmd_inspect)

    p_trace = sub.add_parser(
        "trace", help="Verify multi-cluster Cloud Trace spans for a given trace ID."
    )
    p_trace.add_argument("--project", required=True)
    p_trace.add_argument("--trace-id", required=True)
    p_trace.add_argument("--min-spans", type=int, default=20)
    p_trace.add_argument("--expected-clusters", default="")
    p_trace.set_defaults(func=cmd_trace)

    p_rotate = sub.add_parser(
        "rotate-probe",
        help="Verify Apigee DeveloperApp N/N-1 key rotation grace and 401 revocation.",
    )
    p_rotate.add_argument("--project", required=True)
    p_rotate.add_argument("--apigee-org", default="")
    p_rotate.add_argument("--app-name", required=True)
    p_rotate.add_argument("--developer-email", default="")
    p_rotate.add_argument("--gateway-fqdn", default="api.hybrid-agents.internal")
    p_rotate.add_argument("--connect-host", default="")
    p_rotate.add_argument("--connect-port", type=int, default=443)
    p_rotate.add_argument("--ca-file", default="")
    p_rotate.add_argument("--path", default="/gateway-catalog/status")
    p_rotate.add_argument(
        "--phase",
        default="auto",
        choices=("auto", "grace", "revoked", "deleted"),
    )
    p_rotate.add_argument("--grace-seconds", type=int, default=-1)
    p_rotate.set_defaults(func=cmd_rotate_probe)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
