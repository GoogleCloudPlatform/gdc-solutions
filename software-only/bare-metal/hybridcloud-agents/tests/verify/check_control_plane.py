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
import json
import os
import subprocess
import sys
import urllib.error
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

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
