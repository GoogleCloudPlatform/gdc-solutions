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

# Phase A Prerequisite: NVIDIA GPU Time-Slicing

This directory contains a one-time **Phase A cluster prerequisite** applied by
the platform administrator on single-GPU Distributed Cloud software only edge
store clusters so `vLLM` (`vllm-gemma4`) and the Flower trainer (`flwr-trainer`)
can share one physical NVIDIA GPU (`replicas: 2`).

These cluster-wide NVIDIA GPU Operator resources
(`ConfigMap/time-slicing-config` in `gpu-operator` and cluster-scoped
`ClusterPolicy/cluster-policy`) are intentionally excluded from the
`fed-lora-edge-package` `FleetPackage` so application GitOps rollouts and
deletions never overwrite or prune cluster-level GPU Operator policies.

## Apply on fresh single-GPU store clusters (Phase A)

Run once on each single-GPU edge store cluster after NVIDIA GPU Operator is
installed (skip this step on multi-GPU nodes where `vLLM` and `flwr-trainer` use
separate GPUs):

```bash
kubectl apply -k software-only/bare-metal/fed-lora/prerequisites/gpu-time-slicing
```

## Migrating from an earlier FleetPackage that owned GPU time-slicing

🛑 **CAUTION:** If a live cluster previously reconciled `time-slicing-config`
and `cluster-policy` through an older `FleetPackage` / `RootSync`, annotate both
live objects with `client.lifecycle.config.k8s.io/deletion: detach` **before**
rolling out the updated `FleetPackage`. Without this annotation, Config Sync
prunes (deletes) both objects during the rollout and disrupts active GPU
workloads.

```bash
kubectl annotate configmap time-slicing-config -n gpu-operator \
  client.lifecycle.config.k8s.io/deletion=detach --overwrite
kubectl annotate clusterpolicy cluster-policy \
  client.lifecycle.config.k8s.io/deletion=detach --overwrite
```
