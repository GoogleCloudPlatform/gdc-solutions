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

The Solution Reference Architecture (SRA) for this solution is in progress.

## Disclaimer

This is not an officially supported Google product. This project is provided for
reference and educational purposes only, on a best-effort basis, with no
official support and no service level agreement (SLA). It is not eligible for
the
[Google Open Source Software Vulnerability Rewards Program](https://bughunters.google.com/open-source-security).

## Repository layout

```text
hybridcloud-agents/
├── README.md
└── fleet-package/
    ├── configdelivery-rbac.yaml
    ├── environments/
    │   └── agents/
    │       └── manifests.yaml
    ├── fleetpackage.yaml
    ├── render.sh
    └── src/
        ├── base/
        │   ├── kustomization.yaml
        │   ├── namespace.yaml
        │   └── network-policies.yaml
        └── overlays/
            └── agents/
                └── kustomization.yaml
```

- `fleet-package/` contains the Google Cloud Config Delivery (`FleetPackage`)
  specification, least-privilege `RootSync` RBAC manifest, DRY Kustomize sources
  (`src/`), render script (`render.sh`), and rendered plain-KRM variant bundle
  (`environments/agents/manifests.yaml`) for clusters labeled
  `cluster-role=agents` (`Namespace/agent-workloads` with `restricted` Pod
  Security Standards plus default-deny and CoreDNS egress `NetworkPolicy`
  resources).

## Configuration

Replace these placeholders in `fleet-package/configdelivery-rbac.yaml` and
`fleet-package/fleetpackage.yaml` before you deploy:

<!-- mdformat off -->

| Placeholder              | Description                                                                            |
| :----------------------- | :------------------------------------------------------------------------------------- |
| `YOUR_PROJECT_ID`        | Google Cloud fleet host project ID                                                     |
| `YOUR_PROJECT_NUMBER`    | Numeric Google Cloud fleet host project number (for the Config Delivery service agent) |
| `YOUR_CONNECTION`        | Cloud Build 2nd-gen Git repository connection name in `us-central1`                    |
| `YOUR_REPOSITORY`        | Linked repository resource name inside `YOUR_CONNECTION`                               |
| `YOUR_PUBLISHER_SA_NAME` | Service account name used by Config Delivery / Cloud Build to package releases         |

<!-- mdformat on -->
