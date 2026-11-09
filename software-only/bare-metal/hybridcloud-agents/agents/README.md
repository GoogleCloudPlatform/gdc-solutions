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

cspell:words adkagent cloudbuild isvertexai kustomize litellm otel toolsets traceparent uvicorn vllm
-->

# Sample Google ADK Agent Container Sources

Sanitized Python source code, `Dockerfile` definitions, pinned dependency
manifests, and a Cloud Build pipeline for building the two sample Google Agent
Development Kit (ADK) container images deployed on the Agents cluster.

## Agents

`adk-sovereign-agent` (`v0.2.0`) is the on-premises sovereign compliance policy
specialist. It runs as a non-root container (`uid/gid 10001`) with a read-only
root filesystem and `code_executor=None`, mediates all outbound LLM
(`google.adk.models.apigee_llm.ApigeeLlm` over `/v1` or `GatewayGemini` over
`/v1beta`) and MCP (`/mcp-toolbox` and `/mcp`) requests strictly through its
local Envoy egress proxy (`agent-egress-envoy:15001`) with a kubelet-projected
Kubernetes service account JWT (`x-agent-ksa-token`) and W3C `traceparent`,
serves both northbound `/invoke` (plus `/invoke-stream` Server-Sent Events) and
east-west Agent2Agent (A2A) JSON-RPC `message/send` requests, and disables GenAI
and ADK message content capture in OpenTelemetry spans at source.

`adk-ops-orchestrator` (`v0.3.0`) is the hybrid operations and incident triage
orchestrator. Like `adk-sovereign-agent`, it runs as a non-root container
(`uid/gid 10001`) with `code_executor=None` and routes all outbound traffic
through its dedicated Envoy egress proxy (`ops-egress-envoy:15001`). It combines
Apigee-routed LLM inference (`enterprise-flash` for `cloud-eligible` or `public`
requests and `enterprise-sovereign` for `sovereign`, `confidential`, or
`restricted` requests) with `McpToolset` discovery for Google-managed BigQuery
(`/mcp-bigquery`), Cloud Storage (`/mcp-storage`), and the Apigee gateway
catalog (`/mcp`), and delegates sovereign compliance assessments over
Apigee-mediated A2A JSON-RPC (`message/send`) to `adk-sovereign-agent` using the
deploy-time peer registry ConfigMap (`/etc/adk-config/peer-agents.json`).

## Files

- `adk-sovereign-agent/app.py`, `adk-sovereign-agent/Dockerfile`,
  `adk-sovereign-agent/requirements.txt` — source, container build file, and
  Python dependencies for `adk-sovereign-agent` (`0.2.0`).
- `adk-ops-orchestrator/app.py`, `adk-ops-orchestrator/Dockerfile`,
  `adk-ops-orchestrator/requirements.txt` — source, container build file, and
  Python dependencies for `adk-ops-orchestrator` (`0.3.0`).
- `cloudbuild-images.yaml` — Cloud Build configuration that stages each agent's
  canonical A2A card from `registry/cards/<agent>.json`, builds both container
  images (running the `Dockerfile` import and `ApigeeLlm` self-test at build
  time), pushes them to Artifact Registry, and prints the resulting `sha256`
  image digests.

## Building the images with Cloud Build

Run the following command from the `hybridcloud-agents/` directory (or the
repository root) to build and push both images to an Artifact Registry Docker
repository in your Google Cloud project:

```bash
gcloud builds submit . \
  --project="${PROJECT_ID}" \
  --config=agents/cloudbuild-images.yaml \
  --substitutions="_AR_LOCATION=${AR_LOCATION},_AR_REPOSITORY=${AR_REPOSITORY},_IMAGE_TAG=${IMAGE_TAG}"
```

The build produces:

- `${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPOSITORY}/adk-sovereign-agent:${IMAGE_TAG}`
- `${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPOSITORY}/adk-ops-orchestrator:${IMAGE_TAG}`

and prints the immutable `sha256` digest of each image at the end of the build
log.

## Mirroring images and pinning digests in Kustomize

Mirroring images from Artifact Registry to the container registry that your
Distributed Cloud agent nodes pull from is specific to your environment and out
of scope for this build configuration. After mirroring both built images to your
cluster-reachable registry
(`registry.hybrid-agents.internal/hybrid-cloud-agents/...` in the default
manifests):

1. Update the `image:` digest references in
   `fleet-package/src/base/adk-sovereign-agent.yaml` and
   `fleet-package/src/base/adk-ops-orchestrator.yaml` with the new `@sha256:...`
   digests.
2. Re-render the environment manifest bundles before committing:

   ```bash
   ./fleet-package/render.sh
   ```

## `google-adk==1.39.1` version pin warning

🚨 **IMPORTANT:** Keep `google-adk==1.39.1` pinned in both `requirements.txt`
files. Both agents hook private `ApigeeLlm` internals
(`_completions_http_client._client.event_hooks` to capture gateway routing and
token-quota response headers, and `_completions_http_client._construct_payload`
to inject `stream_options.include_usage` during Server-Sent Events streaming),
and each `Dockerfile` asserts internal `ApigeeLlm` attributes (`_api_type`,
`_isvertexai`, `_custom_headers`) at build time. If you upgrade `google-adk`,
verify that these private attributes and hooks remain compatible before rolling
out new images.
