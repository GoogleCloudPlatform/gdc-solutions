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

cspell:words agentregistry creds genai hybridcloud pgvector propertyset sslmode
-->

# Hybrid Cloud AI Agents on Distributed Cloud software only

Reference GitOps fleet packages, portable Apigee hybrid proxy bundles, per-agent
identity manifests, and Agent Registry synchronization pipeline for running
Apigee-mediated Google Agent Development Kit (ADK) multi-agent workloads on
Distributed Cloud software only.

## Disclaimer

This is not an officially supported Google product. This project is provided for
reference and educational purposes only, on a best-effort basis, with no
official support and no service level agreement (SLA). It is not eligible for
the
[Google Open Source Software Vulnerability Rewards Program](https://bughunters.google.com/open-source-security).

## Model license notice

Gemma is provided under and subject to the
[Gemma Terms of Use](https://ai.google.dev/gemma/terms). Review and accept the
applicable model license terms before deploying Gemma 4 weights in your
environment.

## Repository layout

```text
hybridcloud-agents/
├── README.md
├── apigee/
│   ├── environments/
│   │   └── env-config.json
│   ├── products/
│   │   └── api-products.json
│   └── proxies/
│       ├── a2a-dispatch-v1/
│       ├── agent-dispatch-v1/
│       ├── gateway-catalog-v1/
│       ├── gemini-genai-v1/
│       ├── llm-router-v1/
│       ├── mcp-bigquery-v1/
│       ├── mcp-discovery-v1/
│       ├── mcp-storage-v1/
│       ├── mcp-toolbox-v1/
│       └── ops-agent-dispatch-v1/
├── fleet-package/
│   ├── configdelivery-rbac.yaml
│   ├── environments/
│   │   ├── agents/
│   │   │   └── manifests.yaml
│   │   └── gateway-tools/
│   │       └── manifests.yaml
│   ├── fleetpackage-gateway-tools.yaml
│   ├── fleetpackage.yaml
│   ├── render.sh
│   └── src/
│       ├── base/
│       │   ├── adk-ops-orchestrator.yaml
│       │   ├── adk-sovereign-agent.yaml
│       │   ├── agent-egress-envoy.yaml
│       │   ├── envoy-mtls-ingress-config.yaml
│       │   ├── kustomization.yaml
│       │   ├── namespace.yaml
│       │   ├── network-policies.yaml
│       │   ├── ops-egress-envoy.yaml
│       │   └── pod-monitoring.yaml
│       ├── components/
│       │   └── otel-collector/
│       │       ├── kustomization.yaml
│       │       └── otel-collector.yaml
│       └── overlays/
│           ├── agents/
│           │   └── kustomization.yaml
│           └── gateway-tools/
│               ├── kustomization.yaml
│               └── mcp-toolbox.yaml
├── registry/
│   ├── agents/
│   │   ├── adk-ops-orchestrator/
│   │   │   └── agent.yaml
│   │   └── adk-sovereign-agent/
│   │       └── agent.yaml
│   ├── cards/
│   │   ├── adk-ops-orchestrator.json
│   │   └── adk-sovereign-agent.json
│   ├── cloudbuild-register.yaml
│   ├── mcp-servers/
│   │   ├── mcp-bigquery.yaml
│   │   ├── mcp-storage.yaml
│   │   └── mcp-toolbox.yaml
│   ├── sync-agent-registry.sh
│   ├── sync-apigee-identity.sh
│   ├── sync-apigee-proxies.sh
│   └── validate-manifests.sh
└── tests/
    ├── a2a/
    │   ├── environments/
    │   │   └── agents/
    │   │       └── manifests.yaml
    │   ├── fleetpackage.yaml
    │   ├── render.sh
    │   └── src/
    │       ├── base/
    │       │   ├── a2a-bypass-probes.yaml
    │       │   ├── a2a-rogue-caller.yaml
    │       │   └── kustomization.yaml
    │       └── overlays/
    │           └── agents/
    │               └── kustomization.yaml
    ├── data-tier/
    │   ├── 00-namespace-and-pki.yaml
    │   ├── 01-postgres-pgvector.yaml
    │   ├── 02-network-policies.yaml
    │   └── README.md
    └── model-tier/
        ├── README.md
        ├── gpu-pod-monitoring.yaml
        ├── vllm-deployment.yaml
        ├── vllm-https-ingress.yaml
        ├── vllm-pod-monitoring.yaml
        ├── vllm-pvc.yaml
        └── vllm-service.yaml
```

- `apigee/` contains portable, config-as-code Apigee hybrid 1.17 proxy bundles
  (`proxies/`), base API product specifications (`products/api-products.json`),
  and environment configuration templates (`environments/env-config.json` for
  `TargetServers`, environment property sets, and KVM maps). All proxy bundles
  resolve backend hosts through `TargetServers`, environment settings through
  `propertyset.hybrid_agents_env.*`, and expected Kubernetes service account JWT
  subjects plus OIDC JWKS dynamically from the `agent-jwt-subjects` KVM.
- `fleet-package/` contains the Google Cloud Config Delivery (`FleetPackage`)
  specifications (`fleetpackage.yaml` for `cluster-role=agents` and
  `fleetpackage-gateway-tools.yaml` for `cluster-role=gateway-tools`; two
  specifications are provided because Config Delivery's `LabelSelector` schema
  supports `matchLabels` only and rejects `matchExpressions`), least-privilege
  `RootSync` RBAC manifest, DRY Kustomize sources (`src/base/`, shared
  `src/components/otel-collector/`, and `src/overlays/`), render script
  (`render.sh`), and rendered plain-KRM variant bundles
  (`environments/agents/manifests.yaml` and
  `environments/gateway-tools/manifests.yaml`).
- `registry/` contains per-agent identity and quota manifests
  (`agents/<agent>/agent.yaml`), generic A2A Agent Card definitions
  (`cards/*.json`), local MCP server tool specifications (`mcp-servers/*.yaml`),
  the preflight manifest validator (`validate-manifests.sh`, run as `Step #0`
  before any API mutation), and the three idempotent Cloud Build reconciliation
  scripts (`sync-apigee-identity.sh`, `sync-apigee-proxies.sh`, and
  `sync-agent-registry.sh`) orchestrated by `cloudbuild-register.yaml`.
- `tests/a2a/` contains an optional, self-pruning `FleetPackage`
  (`hybridcloud-agents-a2a-tests` with `deletionPropagationPolicy: FOREGROUND`)
  that runs negative-security verification `Job` workloads for rogue caller
  rejection and east-west bypass prevention, then removes all test fixtures when
  deleted.
- `tests/data-tier/` and `tests/model-tier/` contain optional, self-contained
  Kubernetes manifests (applied directly with `kubectl`, not managed by Config
  Delivery) for standing up a sample PostgreSQL 16 + `pgvector` backing database
  (`tests/data-tier/`) and a sample `vLLM` (`google/gemma-4-31B-it`) model tier
  with bundled HTTPS `Ingress` on a `gdc-so-model` GPU test cluster
  (`tests/model-tier/`) for end-to-end evaluation.

## Configuration

Replace these placeholders in `fleet-package/`, `tests/a2a/`, or Cloud Build
trigger substitutions before you deploy:

<!-- mdformat off -->

| Placeholder                     | Description                                                                                      |
| :------------------------------ | :----------------------------------------------------------------------------------------------- |
| `YOUR_PROJECT_ID`               | Google Cloud fleet host and Apigee organization project ID                                       |
| `YOUR_PROJECT_NUMBER`           | Numeric Google Cloud fleet host project number (for the Config Delivery service agent)           |
| `YOUR_CONNECTION`               | Cloud Build 2nd-gen Git repository connection name in `us-central1`                              |
| `YOUR_REPOSITORY`               | Linked repository resource name inside `YOUR_CONNECTION`                                         |
| `YOUR_PUBLISHER_SA_NAME`        | Service account name used by Config Delivery / Cloud Build to package releases                   |
| `YOUR_GATEWAY_FQDN`             | Internal FQDN of the Apigee hybrid ingress gateway substituted into Agent Registry cards         |
| `YOUR_AGENTS_INGRESS_VIP`       | MetalLB `LoadBalancer` IP (`spec.loadBalancerIP`) pinned on `Service/agent-ingress-envoy`        |
| `YOUR_AGENTS_INGRESS_HOST`      | IP or hostname of the Agents cluster Envoy mTLS ingress gateway (`gdcso-agent-ingress`)          |
| `YOUR_VLLM_INGRESS_HOST`        | IP or hostname of the Model cluster sovereign vLLM ingress gateway (`gdcso-local-vllm`)          |
| `YOUR_PGVECTOR_HOST`            | IP or hostname of your external PostgreSQL + `pgvector` endpoint (`sovereign-pgvector` source)   |
| `YOUR_DATA_SYSTEMS_CIDR`        | CIDR block (for example `<IP>/32`) of your external PostgreSQL + `pgvector` endpoint for `:5432` |
| `YOUR_AGENTS_CLUSTER_NAME`      | Fleet membership name of the Agents cluster (`agents.cluster.name` in property set)              |
| `YOUR_GATEWAY_CLUSTER_NAME`     | Fleet membership name of the Gateway cluster (`gateway.cluster.name` in property set)            |
| `YOUR_MODEL_CLUSTER_NAME`       | Fleet membership name of the Model cluster (`model.cluster.name` in property set)                |
| `_AGENTS_CLUSTER_OIDC_JWKS_B64` | Base64-encoded OIDC JWKS (`kubectl get --raw /openid/v1/jwks`) of the Agents cluster             |

<!-- mdformat on -->

Always substitute your environment-specific values in a private repository copy
(never a public fork) or a rendered release bundle, and verify that no
unrendered `YOUR_*` placeholders remain in `fleet-package/environments/` before
creating a release tag.

## Least-privilege IAM for Cloud Build synchronization

Grant the dedicated Cloud Build trigger service account only the following
project- and resource-scoped IAM roles (no `roles/apigee.admin`, no
`roles/secretmanager.admin`, and no `roles/secretmanager.secretAccessor`):

<!-- mdformat off -->

| Role                                       | Scope                                                | Purpose                                                                                                                                                                            |
| :----------------------------------------- | :--------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `roles/agentregistry.editor`               | Project (`YOUR_PROJECT_ID`)                          | Create, update, and prune pipeline-managed A2A Agent Cards and local MCP Server registrations in Agent Registry                                                                    |
| `roles/apigee.apiAdminV2`                  | Project (`YOUR_PROJECT_ID`)                          | Import and deploy Apigee proxy bundles and reconcile `APIProduct` definitions                                                                                                      |
| `roles/apigee.developerAdmin`              | Project (`YOUR_PROJECT_ID`)                          | Create, update, rotate, and delete pipeline-managed `Developer` and `DeveloperApp` credentials                                                                                     |
| `roles/apigee.environmentAdmin`            | Project (`YOUR_PROJECT_ID`)                          | Reconcile environment `TargetServer`, `PropertySet`, and `agent-jwt-subjects` KVM entries                                                                                          |
| `roles/logging.logWriter`                  | Project (`YOUR_PROJECT_ID`)                          | Emit Cloud Build step logs to Cloud Logging                                                                                                                                        |
| `roles/iam.serviceAccountUser`             | Resource (`_APIGEE_RUNTIME_SA` service account only) | Attach the Apigee runtime Google service account when deploying Cloud MCP proxy revisions                                                                                          |
| `roles/secretmanager.secretVersionAdder`   | Resource (each per-agent API key secret only)        | Add a new Secret Manager version when an agent consumer key is created or rotated                                                                                                  |
| `roles/secretmanager.secretVersionManager` | Resource (each per-agent API key secret only)        | List and destroy `ENABLED`/`DISABLED` Secret Manager versions when a pipeline-managed agent manifest is removed (without granting `secretAccessor` read access to secret payloads) |

<!-- mdformat on -->

## Bring your own database for the MCP Toolbox sample

The `gateway-tools` overlay
(`fleet-package/src/overlays/gateway-tools/mcp-toolbox.yaml`) ships a sample
`sovereign-pgvector` PostgreSQL source (`host: YOUR_PGVECTOR_HOST` with
`sslmode: verify-full`), `ExternalSecret/pgvector-db-creds` (referencing Secret
Manager key `hybrid-agents-pgvector-creds` with JSON properties `PG_DATABASE`,
`PG_USER`, and `PG_PASSWORD`), and a `:5432` egress rule
(`cidr: YOUR_DATA_SYSTEMS_CIDR`) in `NetworkPolicy/allow-mcp-toolbox`. The
package does **not** deploy a PostgreSQL database.

Before deploying `fleet-package/fleetpackage-gateway-tools.yaml`, choose one of
the following options:

1. **Point at your own external PostgreSQL + `pgvector` instance:** Create the
   `hybrid-agents-pgvector-creds` secret in Secret Manager with JSON keys
   `PG_DATABASE`, `PG_USER`, and `PG_PASSWORD`, configure your PostgreSQL +
   `pgvector` endpoint with a server TLS certificate signed by the shared
   internal CA (`ClusterIssuer/hybrid-agents-ca`, including `YOUR_PGVECTOR_HOST`
   in its Subject Alternative Names so `sslmode=verify-full` validation
   succeeds), replace `YOUR_PGVECTOR_HOST` in `ConfigMap/mcp-toolbox-config` and
   `YOUR_DATA_SYSTEMS_CIDR` in `NetworkPolicy/allow-mcp-toolbox` with your
   database endpoint address and CIDR block, and re-run
   `fleet-package/render.sh`. For testing purposes when you do not already have
   an external PostgreSQL + `pgvector` instance, see `tests/data-tier/README.md`
   for sample `kubectl` manifests that deploy a seeded PostgreSQL 16 +
   `pgvector` test database on a sample Kubernetes cluster.
2. **Remove the sample PostgreSQL source:** Remove the `sovereign-pgvector`
   source and its tools from `ConfigMap/mcp-toolbox-config`, remove
   `ExternalSecret/pgvector-db-creds` and the `PG_DATABASE`, `PG_USER`, and
   `PG_PASSWORD` `secretKeyRef` environment variables from
   `Deployment/mcp-toolbox`, and remove the `:5432` egress rule from
   `NetworkPolicy/allow-mcp-toolbox`, then re-run `fleet-package/render.sh`.

If neither step is taken:

- When the `hybrid-agents-pgvector-creds` secret does not exist in Secret
  Manager, `ExternalSecret/pgvector-db-creds` remains in `SecretSyncedError`
  (`Secret/pgvector-db-creds` is not created) and `Deployment/mcp-toolbox` pods
  stay in `CreateContainerConfigError` (`secret "pgvector-db-creds" not found`).
- When `Secret/pgvector-db-creds` exists but the configured PostgreSQL host
  (`YOUR_PGVECTOR_HOST:5432`) is unreplaced or unreachable, `mcp-toolbox`
  (`v1.15.0`) synchronously pings the connection pool during source
  initialization at startup (`pool.Ping(ctx)`), exits with
  `unable to initialize source "sovereign-pgvector": unable to connect successfully`,
  and enters `CrashLoopBackOff`—causing calls to `/mcp-toolbox` to fail while
  other Apigee proxies continue serving normally.
