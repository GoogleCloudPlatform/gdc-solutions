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

cspell:words bfloat dcgm dshm istio nvidia prefill vllm
-->

# Sample Sovereign Model-Tier (`gdc-so-model`) Test Cluster Manifests

Optional, self-contained Kubernetes manifests for deploying the `vLLM`
(`google/gemma-4-31B-it`) model-serving tier and bundled HTTPS `Ingress` on a
sample `gdc-so-model` GPU test cluster alongside the
[Open model serving on Distributed Cloud software only](https://docs.cloud.google.com/kubernetes-engine/distributed-cloud/bare-metal/docs/solutions/open-model-serving-sw-only)
guide.

These manifests are applied directly with `kubectl` on `gdc-so-model` and are
**not** managed by Google Cloud Config Delivery (`FleetPackage`).

## Contents

- `vllm-pvc.yaml` — `PersistentVolumeClaim/model-cache-pvc` (`100Gi`,
  `storageClassName: local-shared`) in `namespace: gemma-serving` for caching
  Hugging Face model weights across restarts.
- `vllm-deployment.yaml` — `Deployment/vllm-deployment` serving
  `google/gemma-4-31B-it` with `--quantization=fp8` and the two flags required
  for OpenAI-compatible ADK tool calling (`--enable-auto-tool-choice` and
  `--tool-call-parser=gemma4`).
- `vllm-service.yaml` — `Service/vllm-service` (`type: ClusterIP`, port `8000`).
- `vllm-https-ingress.yaml` — `Ingress/vllm-https-ingress` exposing
  `vllm-service:8000` over TLS on the cluster's `ingressVIP` (`:443`) using the
  bundled `istio-ingress` proxy in `gke-system` and `Secret/vllm-ingress-tls`
  (signed by `ClusterIssuer/hybrid-agents-ca`).
- `vllm-pod-monitoring.yaml` — `PodMonitoring/vllm-pod-monitoring` scraping vLLM
  metrics in `gemma-serving` for Google Cloud Managed Service for Prometheus.
- `gpu-pod-monitoring.yaml` — `PodMonitoring/dcgm-gmp` scraping NVIDIA DCGM
  exporter metrics in `gpu-operator`.

## Deployment steps

1. Create `namespace: gemma-serving` and the Hugging Face token secret on
   `gdc-so-model`:

   ```bash
   kubectl create namespace gemma-serving
   kubectl -n gemma-serving create secret generic hf-token-secret \
     --from-literal=token="${HF_TOKEN}"
   ```

2. Copy the TLS server certificate secret (`vllm-ingress-tls`, issued by
   `ClusterIssuer/hybrid-agents-ca` with your `gdc-so-model` `ingressVIP` in
   `spec.ipAddresses`) into `namespace: gke-system` on `gdc-so-model`.

3. Apply the model-tier manifests on `gdc-so-model`:

   ```bash
   kubectl apply -f tests/model-tier/vllm-pvc.yaml
   kubectl apply -f tests/model-tier/vllm-deployment.yaml
   kubectl apply -f tests/model-tier/vllm-service.yaml
   kubectl apply -f tests/model-tier/vllm-https-ingress.yaml
   kubectl apply -f tests/model-tier/vllm-pod-monitoring.yaml
   kubectl apply -f tests/model-tier/gpu-pod-monitoring.yaml
   ```
