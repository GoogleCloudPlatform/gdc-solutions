<!--
Copyright 2026 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

cspell:words agentregistry apigee bursty cloudtrace connectgateway cooldown
cspell:words externalsecrets failover gcloud hybridcloud jsonrpc kubectl
cspell:words netpol pgvector podmonitoring psql rootsync sar subcall
cspell:words subjectaccessreviews unauth undeployed vllm xport
-->

# Optional Repeat-Validation Suite (`tests/verify/`)

> 📌 **NOTE:** Optional helper for repeat validation; it does not replace the
> steps in the Solution User Guide (SUG).

This folder packages lightweight, standard-library scripts that mirror the
verification checks in the Hybrid Cloud AI Agents Solution User Guide (Steps
1–4) and provide a 4-check `smoke` subcommand for quick regressions. All checks
are read-only on cluster configuration (they generate test traffic and inspect
APIs only; they never run `kubectl apply`, never modify `FleetPackage`
resources, and never read Kubernetes `Secret` payloads or agent API keys).

These scripts complement — and do **not** duplicate — the ephemeral
`FleetPackage` negative-probe jobs in [`../a2a/`](../a2a/) (rogue-caller Job,
direct pod-to-pod bypass probe, and mTLS ingress bypass probe) or the optional
cluster manifests in [`../model-tier/`](../model-tier/) and
[`../data-tier/`](../data-tier/).

## Contents

- `verify.sh` — Main entrypoint with subcommands `smoke`, `step1`, `step2`,
  `step3`, `step4`, and `status`. Prints a `PASS`/`FAIL`/`SKIP` summary table
  and exits non-zero on any `FAIL`. Includes an automatic 65-second cooldown
  between bursty Gemini batches to respect Apigee's `PromptTokenLimit-Burst`
  (`2400pm`) policy.
- `agent_call.py` — Python 3 standard-library helper executed inside an agent
  pod (`kubectl exec -i deploy/<agent> -- python3 -`) using the exact SUG
  `agent_call` semantics:
  - `agent` mode sends requests locally to `http://127.0.0.1:8080` (`/invoke`,
    `/invoke-stream`).
  - `gateway` mode calls Apigee through the pod's own `EGRESS_PROXY_BASE`
    listener on `agent-egress-envoy`, attaching the pod's projected Kubernetes
    ServiceAccount token (`X-Agent-KSA-Token`) while Envoy injects and
    overwrites `x-api-key`.
  - No API key or projected token is read from Kubernetes Secrets or persisted
    to disk.
- `check_control_plane.py` — Python 3 standard-library helper that verifies
  Agent Registry services, Apigee managed `DeveloperApp`s, `APIProduct`s,
  `agent-jwt-subjects` KVM entry keys, deployed MCP proxies, Secret Manager
  version states (metadata only), and Cloud Trace spans.

## Prerequisites

1. **Workstation CLI tools:** `bash`, `kubectl`, `gcloud`, `python3` (standard
   library only — no third-party pip packages required), and optionally `curl`
   for workstation-to-VIP TLS checks.
2. **Environment variables (exact SRI `.env` names):** Source the `.env` file
   created in the Solution Reference Implementation (SRI):

   ```bash
   set -a; source "${HOME}/gdcso-solutions/hybridcloud-agents/.env"; set +a
   ```

<!-- mdformat off -->

| Variable                  | Required | Default / Example                                        | Purpose                                                                                      |
| :------------------------ | :------- | :------------------------------------------------------- | :------------------------------------------------------------------------------------------- |
| `PROJECT_ID`              | Yes      | `YOUR_PROJECT_ID`                                        | Fleet host and Google Cloud project ID                                                       |
| `AGENTS_CLUSTER`          | Yes      | `YOUR_AGENTS_CLUSTER_NAME`                               | Fleet membership name of the Agents cluster                                                  |
| `GATEWAY_CLUSTER`         | Yes      | `YOUR_GATEWAY_CLUSTER_NAME`                              | Fleet membership name of the Gateway and Tools cluster                                       |
| `REGION`                  | No       | `us-central1`                                            | Config Delivery, Cloud Build, and Agent Registry location                                    |
| `APIGEE_ORG`              | No       | `${PROJECT_ID}`                                          | Apigee organization ID                                                                       |
| `APIGEE_ENV`              | No       | `hybrid-agents-env`                                      | Apigee environment name                                                                      |
| `GATEWAY_FQDN`            | No       | `api.hybrid-agents.internal`                             | Apigee ingress FQDN (used by optional workstation unauthenticated `curl` check)              |
| `CTX_AGENTS`              | No       | `connectgateway_${PROJECT_ID}_global_${AGENTS_CLUSTER}`  | `kubectl` context for the Agents cluster                                                     |
| `CTX_GATEWAY`             | No       | `connectgateway_${PROJECT_ID}_global_${GATEWAY_CLUSTER}` | `kubectl` context for the Gateway and Tools cluster                                          |
| `SOLUTION_HOME`           | No       | `${HOME}/gdcso-solutions/hybridcloud-agents`             | Directory holding `hybrid-agents-root-ca.crt` for optional unauthenticated `curl` checks     |
| `PGVECTOR_HOST`           | No       | Unset (`SKIP` when unset)                                | PostgreSQL IP for the optional direct `:5432` pod-egress block check                         |
| `DIRECT_DB_TARGETS`       | No       | `${PGVECTOR_HOST}`                                       | Comma-separated IPs for the optional direct `:5432` pod-egress block check                   |
| `CTX_DATA`                | No       | Unset (`SKIP` when unset)                                | Optional data-tier test cluster context for `pg_stat_ssl` TLS 1.3 verification               |
| `GEMINI_COOLDOWN_SECONDS` | No       | `65`                                                     | Cooldown between bursty Gemini batches to respect Apigee `PromptTokenLimit-Burst` (`2400pm`) |
| `TRACE_FLUSH_SECONDS`     | No       | `15`                                                     | OTel collector flush wait before querying Cloud Trace in `step3`                             |
| `TRACE_MIN_SPANS`         | No       | `20`                                                     | Minimum span count required by `S3-CLOUD-TRACE`                                              |
| `TRACE_EXPECTED_CLUSTERS` | No       | `${AGENTS_CLUSTER}`                                      | Comma-separated `k8s.cluster.name` values required in Cloud Trace spans                      |
| `KUBECTL_CACHE_DIR`       | No       | Unset (kubectl default)                                  | Optional custom `kubectl --cache-dir` path                                                   |

<!-- mdformat on -->

3. **IAM & RBAC:** Reuses the exact SRI/SUG operator permissions (`pods/exec`,
   `get` on pods/configmaps/externalsecrets/podmonitoring, `create` on
   `subjectaccessreviews`, `roles/cloudtrace.user`, Apigee/Agent Registry/Secret
   Manager metadata read). The operator never reads agent API key secrets.

## Usage

```bash
# Load SRI environment variables
set -a; source "${HOME}/gdcso-solutions/hybridcloud-agents/.env"; set +a

# Quick 4-check smoke suite (requires Step 3 full stack)
bash tests/verify/verify.sh smoke

# Step 1 (v1.1.0: adk-ops-orchestrator only)
bash tests/verify/verify.sh step1

# Step 2 (v1.2.0: adk-ops-orchestrator + mcp-toolbox)
bash tests/verify/verify.sh step2

# Step 3 (v1.3.0: full regression + cross-port + forged-key + Cloud Trace)
bash tests/verify/verify.sh step3

# Step 3 including the opt-in 6-call A2A quota burst (exhausts quota for 2 min)
bash tests/verify/verify.sh step3 --include-a2a-quota

# Step 4 (v1.4.0: forward rollback to empty active set)
bash tests/verify/verify.sh step4

# Read-only inspection of current control-plane and workload state (no traffic)
bash tests/verify/verify.sh status
# Equivalent dry-run of step4 checks without asserting empty active set:
bash tests/verify/verify.sh step4 --expect-current

# Re-run Step 1 or Step 2 functional checks against an already-deployed Step 3 stack
bash tests/verify/verify.sh step1 --allow-higher-stage
bash tests/verify/verify.sh step2 --allow-higher-stage
```

> ⚠️ **WARNING:** Apigee enforces a per-caller A2A quota of **4 A2A sub-calls
> per 2 minutes** on `a2a-sovereign-callers`. Wait 2 minutes between
> back-to-back `step3` or `smoke` runs to avoid intentional `HTTP 429`
> rejections.

## Check-to-SUG-Step Mapping

<!-- mdformat off -->

| Subcommand | Check ID           | SUG Reference      | What Is Verified                                                                                                      |
| :--------- | :----------------- | :----------------- | :-------------------------------------------------------------------------------------------------------------------- |
| `smoke`    | `SMOKE-SM1`        | Step 3 #1          | `adk-sovereign-agent /invoke` (`sovereign`) returns `200`, `local-vllm`, cites `SYN-POL-001`                          |
| `smoke`    | `SMOKE-A2A1A`      | Step 3 #3          | `adk-ops-orchestrator /invoke` (`sovereign`) delegates over A2A (`200`), cites `SYN-POL-001`                          |
| `smoke`    | `SMOKE-MCP`        | Step 2 #2          | `/mcp-toolbox` `tools/list` (`200`) + SQL `search_sovereign_policies_by_category` (`200`, `SYN-POL-001`)              |
| `smoke`    | `SMOKE-MA`         | Step 1 #3          | Model Armor blocks prompt injection (`HTTP 400`, `FilterMatched`)                                                     |
| `step1`    | `S1-WORKLOADS`     | Step 1 Deploy & #7 | 6 pods running (`0` restarts), `ops-egress-apigee-api-key` `SecretSynced`, both `PodMonitoring` objects present       |
| `step1`    | `S1-SAR`           | Step 1 Deploy      | `SubjectAccessReview` confirms `root-reconciler-hybridcloud-agents` cannot `get secrets` (`false`)                    |
| `step1`    | `S1-CP`            | Step 1 #1          | Agent Registry lists `adk-ops-orchestrator` (`0` MCP servers), `ops-orchestrator-app` active, `mcp-toolbox-v1` down   |
| `step1`    | `S1-UNAUTH`        | Step 1 #1          | Optional workstation `curl` confirms unauthenticated `/agents/ops-orchestrator/.well-known/agent-card.json` is `401`  |
| `step1`    | `S1-GEMINI`        | Step 1 #2, #6      | `adk-ops-orchestrator /invoke` (`cloud-eligible`) routes to `vertex-gemini-*` with `X-TokenQuota-*` and `trace_id`    |
| `step1`    | `S1-GEMMA`         | Step 1 #2          | `adk-ops-orchestrator /invoke` (`sovereign`) routes directly to `local-vllm` (`a2a_subcall={}`)                       |
| `step1`    | `S1-SSE`           | Step 1 #5          | `adk-ops-orchestrator /invoke-stream` (`sovereign`) streams `>1` SSE events ending with `done: true`                  |
| `step1`    | `S1-MCP-INACTIVE`  | Step 1 Deploy      | `/mcp-toolbox` returns `404`/`401` before Step 2 activates `mcp-toolbox.yaml`                                         |
| `step1`    | `S1-MA-BENIGN`     | Step 1 #3, #6      | Benign cloud-eligible prompt returns `200`, `cloud-burst-gemini`, `X-TokenQuota-*` (after 65s burst cooldown)         |
| `step1`    | `S1-MA-INJECT`     | Step 1 #3          | Adversarial prompt injection blocked pre-inference (`HTTP 400`, `FilterMatched`)                                      |
| `step1`    | `S1-FAILOVER`      | Step 1 #4          | Simulated cloud `503` (`x-simulate-cloud-burst-status=503`) fails over to `local-vllm-failover` (`200`)               |
| `step2`    | `S2-CP`            | Step 2 Deploy      | `mcp-toolbox-v1` deployed, `cloud-eligible-agents-mcp` attached to `ops-orchestrator-app`, `mcp-toolbox` registered   |
| `step2`    | `S2-PODS`          | Step 2 Deploy      | `agent-workloads` pods healthy (`0` restarts) and `mcp-toolbox` `2/2` in `mcp-tools`                                  |
| `step2`    | `S2-MCP-E2E`       | Step 2 #1          | `adk-ops-orchestrator /invoke` with `enable_toolbox_mcp: true` invokes `toolbox_*` and cites `SYN-POL-001`            |
| `step2`    | `S2-MCP-LIST`      | Step 2 #2          | `/mcp-toolbox` `tools/list` returns both SQL and `pgvector` tools                                                     |
| `step2`    | `S2-MCP-SQL`       | Step 2 #2          | `/mcp-toolbox` `search_sovereign_policies_by_category` (`residency`) returns `SYN-POL-001`                            |
| `step2`    | `S2-MCP-VEC`       | Step 2 #2          | `/mcp-toolbox` `semantic_search_sovereign_policies` (8-float vector + `top_k: 2`) returns `SYN-POL-001`               |
| `step2`    | `S2-MCP-NEG-BQ`    | Step 2 #2          | Inactive `/mcp-bigquery` rejected (`404`/`401`)                                                                       |
| `step3`    | `S3-WORKLOADS`     | Step 3 Deploy      | 8 pods running (`0` restarts), all 3 `ExternalSecret`s `SecretSynced`, `peer-agents.json` lists `adk-sovereign-agent` |
| `step3`    | `S3-CP`            | Step 3 Deploy      | Agent Registry lists both agents + `mcp-toolbox`, both apps/products active, both Secret Manager keys `ENABLED`       |
| `step3`    | `S3-UNAUTH`        | Step 3 #1          | Optional workstation `curl` confirms unauthenticated `/agents/sovereign/.well-known/agent-card.json` is `401`         |
| `step3`    | `S3-SM1`           | Step 3 #1          | `adk-sovereign-agent /invoke` (`sovereign`) returns `200`, `local-vllm`, `SYN-POL-001`                                |
| `step3`    | `S3-SOV-BURST403`  | Step 3 #1          | Sovereign agent requesting `cloud-eligible` rejected (`403`, `CLOUD_BURST_FORBIDDEN_FOR_PRODUCT`)                     |
| `step3`    | `S3-SOV-MODEL403`  | Step 3 #1          | Sovereign agent requesting `enterprise-flash` rejected (`403`, `model_not_authorized_for_api_product`)                |
| `step3`    | `S3-A2A1A`         | Step 3 #3          | Sovereign A2A delegation (`local-vllm` -> `local-vllm`, matching `trace_id`, auto-enabled via `peer-agents.json`)     |
| `step3`    | `S3-A2A1B`         | Step 3 #3          | Hybrid burst A2A delegation (`vertex-gemini-*` -> `local-vllm`, `SYN-POL-001`)                                        |
| `step3`    | `S3-A2A2A`         | Step 3 #4          | Non-entitled `:15001` key calling `/a2a/sovereign` rejected (`401`, `InvalidApiKeyForGivenResource`)                  |
| `step3`    | `S3-A2A2B`         | Step 3 #4          | Mismatched KSA JWT `sub` on `:15002` rejected (`401`, `steps.jwt.InvalidClaim`)                                       |
| `step3`    | `S3-MCP-POS`       | Step 2 #2          | Orchestrator `/mcp-toolbox` `tools/list`, SQL, and 8-dim `pgvector` all return `200` with `SYN-POL-001`               |
| `step3`    | `S3-MCP-NEG`       | Step 3 #2          | Sovereign agent `tools/list` sees SQL only; `semantic_search` denied (`401`/`403`); `/mcp-bigquery` denied (`404`)    |
| `step3`    | `S3-PGVECTOR-TLS`  | SRI Data Tier      | Optional (`CTX_DATA`): verifies `mcp_reader` uses `TLSv1.3` in PostgreSQL `pg_stat_ssl`                               |
| `step3`    | `S3-SSE`           | Step 1 #5          | `adk-sovereign-agent /invoke-stream` streams `>1` SSE events ending with `done: true`                                 |
| `step3`    | `S3-DIRECT-DB`     | SRI NetPol         | Optional (`PGVECTOR_HOST`/`DIRECT_DB_TARGETS`): confirms `:5432` direct connect from agent pod times out              |
| `step3`    | `S3-XPORT-SOV`     | Step 3 #4          | `adk-sovereign-agent` -> `agent-egress-envoy:15002` blocked by dual-direction `NetworkPolicy`                         |
| `step3`    | `S3-XPORT-OPS`     | Step 3 #4          | `adk-ops-orchestrator` -> `agent-egress-envoy:15001` blocked by dual-direction `NetworkPolicy`                        |
| `step3`    | `S3-FORGED-15001`  | Step 3 #4          | Forged `x-api-key` on `:15001` overwritten by Envoy (`overwrite: true`), returns `200` with sovereign scope only      |
| `step3`    | `S3-FORGED-15002`  | Step 3 #4          | Forged `x-api-key` on `:15002` overwritten by Envoy (`overwrite: true`), returns `200` with orchestrator scope        |
| `step3`    | `S3-MODEL-ARMOR`   | Step 1 #3          | Prompt injection blocked (`HTTP 400`, `FilterMatched`) after 65s Gemini burst cooldown                                |
| `step3`    | `S3-FAILOVER`      | Step 1 #4          | Simulated cloud `503` fails over to `local-vllm-failover` (`200`)                                                     |
| `step3`    | `S3-CLOUD-TRACE`   | Step 3 #3, #6      | Cloud Trace API confirms `>= TRACE_MIN_SPANS` spans for the shared `TRACE_ID` on expected cluster(s)                  |
| `step3`    | `S3-A2A-QUOTA`     | Step 3 #5          | Opt-in (`--include-a2a-quota`): 6 sequential A2A calls trigger `HTTP 429` after 4 sub-calls                           |
| `step4`    | `S4-CP`            | Step 4 Verify      | Agent Registry empty, `0` managed apps, `mcp-toolbox-v1` undeployed, `0` enabled/disabled key versions                |
| `step4`    | `S4-AGENTS-PRUNED` | Step 4 Verify      | `0` ADK pods, `0` agent `ExternalSecret`s, `4` idle Envoy pods (`0` restarts)                                         |
| `step4`    | `S4-PLATFORM-OK`   | Step 4 Verify      | `FleetPackage/hybridcloud-agents-platform` `COMPLETED`, `mcp-toolbox` `2/2`, `otel-collector` `1/1` on both clusters  |

<!-- mdformat on -->

## Expected Output

Each run prints check progress followed by a summary table and exits `0` only
when `FAIL=0`:

```text
====================================================================================================
CHECK                  | SUG STEP       | STATUS | DETAIL
-----------------------+----------------+--------+--------------------------------------------------
SMOKE-SM1              | Step 3 #1      | PASS   | HTTP 200 backend=local-vllm model=google/gemma-4-31B-it SYN-POL-001=True
SMOKE-A2A1A            | Step 3 #3      | PASS   | HTTP 200 backend=local-vllm a2a_status=200 SYN-POL-001=True
SMOKE-MCP              | Step 2 #2      | PASS   | tools/list=200 sql=200 SYN-POL-001=True
SMOKE-MA               | Step 1 #3      | PASS   | HTTP 400 FilterMatched=True
====================================================================================================
SUMMARY [smoke]: PASS=4 FAIL=0 SKIP=0 TOTAL=4
```
