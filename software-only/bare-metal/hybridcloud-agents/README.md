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
-->

# Hybrid Cloud AI Agents on Distributed Cloud software only

Reference GitOps fleet packages and Agent Registry synchronization pipeline for
running Apigee-mediated Google Agent Development Kit (ADK) multi-agent workloads
on Distributed Cloud software only.

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
├── fleet-package/
│   ├── configdelivery-rbac.yaml
│   ├── environments/
│   │   └── agents/
│   │       └── manifests.yaml
│   ├── fleetpackage.yaml
│   ├── render.sh
│   └── src/
│       ├── base/
│       │   ├── adk-ops-orchestrator.yaml
│       │   ├── adk-sovereign-agent.yaml
│       │   ├── envoy-mtls-ingress-config.yaml
│       │   ├── kustomization.yaml
│       │   ├── namespace.yaml
│       │   ├── network-policies.yaml
│       │   ├── ops-egress-envoy.yaml
│       │   └── pod-monitoring.yaml
│       └── overlays/
│           └── agents/
│               └── kustomization.yaml
├── registry/
│   ├── cards/
│   │   ├── adk-ops-orchestrator.json
│   │   └── adk-sovereign-agent.json
│   ├── cloudbuild-register.yaml
│   └── sync-agent-registry.sh
└── tests/
    └── a2a/
        ├── environments/
        │   └── agents/
        │       └── manifests.yaml
        ├── fleetpackage.yaml
        ├── render.sh
        └── src/
            ├── base/
            │   ├── a2a-bypass-probes.yaml
            │   ├── a2a-rogue-caller.yaml
            │   └── kustomization.yaml
            └── overlays/
                └── agents/
                    └── kustomization.yaml
```

- `fleet-package/` contains the Google Cloud Config Delivery (`FleetPackage`)
  specification, least-privilege `RootSync` RBAC manifest, DRY Kustomize sources
  (`src/`), render script (`render.sh`), and rendered plain-KRM variant bundle
  (`environments/agents/manifests.yaml`) for clusters labeled
  `cluster-role=agents`. It deploys `Namespace/agent-workloads` (`restricted`
  Pod Security Standards), default-deny and proxy-enforcing `NetworkPolicy`
  resources, Envoy mTLS ingress and egress mediation proxies with OpenTelemetry
  tracing, `adk-sovereign-agent`, `adk-ops-orchestrator`, and Managed Service
  for Prometheus `PodMonitoring` resources.
- `registry/` contains generic A2A Agent Card definitions (`cards/*.json`), an
  idempotent synchronization script (`sync-agent-registry.sh`), and a Cloud
  Build configuration (`cloudbuild-register.yaml`) that reconciles custom Agent
  Registry `Service` resources using `gcloud agent-registry services`.
- `tests/a2a/` contains an optional, self-pruning `FleetPackage`
  (`hybridcloud-agents-a2a-tests` with `deletionPropagationPolicy: FOREGROUND`)
  that runs negative-security verification `Job` workloads for rogue caller
  rejection and east-west bypass prevention, then removes all test fixtures when
  deleted.

## Configuration

Replace these placeholders in `fleet-package/`, `tests/a2a/`, or Cloud Build
trigger substitutions before you deploy:

<!-- mdformat off -->

| Placeholder              | Description                                                                              |
| :----------------------- | :--------------------------------------------------------------------------------------- |
| `YOUR_PROJECT_ID`        | Google Cloud fleet host project ID                                                       |
| `YOUR_PROJECT_NUMBER`    | Numeric Google Cloud fleet host project number (for the Config Delivery service agent)   |
| `YOUR_CONNECTION`        | Cloud Build 2nd-gen Git repository connection name in `us-central1`                      |
| `YOUR_REPOSITORY`        | Linked repository resource name inside `YOUR_CONNECTION`                                 |
| `YOUR_PUBLISHER_SA_NAME` | Service account name used by Config Delivery / Cloud Build to package releases           |
| `YOUR_GATEWAY_FQDN`      | Internal FQDN of the Apigee hybrid ingress gateway substituted into Agent Registry cards |

<!-- mdformat on -->
