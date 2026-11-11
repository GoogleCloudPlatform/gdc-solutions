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

# Turnkey Demo Setup Verification CLI Cheat Sheet

This cheat sheet provides a complete reference of every verification CLI command
identified for the Edge-to-Cloud Federated Learning (Fed-LoRA) PoC across Store
1 (`YOUR_STORE_1_CLUSTER`), Store 2 (`YOUR_STORE_2_CLUSTER`), and Central GKE
(`YOUR_AGGREGATOR_CLUSTER`). Each command is paired with its verified live
terminal output.

---

## 1. Workstation Environment Variables Setup

Export the following variables before running verification commands:

```bash
export PROJECT_ID="YOUR_PROJECT_ID"
export REGION="us-central1"
export ZONE="us-central1-b"

# Cluster Names
export STORE1_CLUSTER="YOUR_STORE_1_CLUSTER"
export STORE2_CLUSTER="YOUR_STORE_2_CLUSTER"
export GKE_AGGREGATOR_CLUSTER="YOUR_AGGREGATOR_CLUSTER"

# Kubectl Contexts
export STORE1_CONTEXT="connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_1_CLUSTER"
export STORE2_CONTEXT="connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_2_CLUSTER"
export GKE_CONTEXT="gke_YOUR_PROJECT_ID_us-central1-b_YOUR_AGGREGATOR_CLUSTER"

# Network Endpoints & VIPs
export STORE1_VLLM_VIP="10.200.0.131"
export STORE2_VLLM_VIP="10.200.0.163"
export SUPERLINK_ILB_IP="10.200.0.50"
export GCS_BUCKET_NAME="YOUR_GCS_BUCKET"
```

---

## 2. Cluster Credentials via Connect Gateway

Fetch credentials for the two edge clusters and the central GKE cluster:

```bash
# Store 1 credentials via Connect Gateway
gcloud container fleet memberships get-credentials "${STORE1_CLUSTER}" --project="${PROJECT_ID}"

# Store 2 credentials via Connect Gateway
gcloud container fleet memberships get-credentials "${STORE2_CLUSTER}" --project="${PROJECT_ID}"

# Central GKE Aggregator credentials
gcloud container clusters get-credentials "${GKE_AGGREGATOR_CLUSTER}" --zone="${ZONE}" --project="${PROJECT_ID}"
```

**Expected Output:**

```text
Fetching / generating credentials for membership YOUR_STORE_1_CLUSTER...
Setup kubeconfig entry for connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_1_CLUSTER.
Fetching / generating credentials for membership YOUR_STORE_2_CLUSTER...
Setup kubeconfig entry for connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_2_CLUSTER.
Fetching cluster endpoint and auth data.
kubeconfig entry generated for YOUR_AGGREGATOR_CLUSTER.
```

---

## 3. GitOps Continuous Delivery & Pipeline Verification

### 3.1. Verify Anthos Config Sync `RootSync` Status

```bash
for ctx in "${STORE1_CONTEXT}" "${STORE2_CONTEXT}" "${GKE_CONTEXT}"; do
  echo "=== Context: ${ctx} ==="
  kubectl --context="${ctx}" get rootsync -n config-management-system
done
```

**Expected / Live Output:**

```text
=== Context: connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_1_CLUSTER ===
NAME                    RENDERINGCOMMIT                                                    RENDERINGERRORCOUNT   SOURCECOMMIT                                                       SOURCEERRORCOUNT   SYNCCOMMIT                                                         SYNCERRORCOUNT
fed-lora-edge-package   05c0394f9aa707d5b6c29d1b76acf1f8f24b7b5110e8365882948c8dacc5d602                         05c0394f9aa707d5b6c29d1b76acf1f8f24b7b5110e8365882948c8dacc5d602                      05c0394f9aa707d5b6c29d1b76acf1f8f24b7b5110e8365882948c8dacc5d602
=== Context: connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_2_CLUSTER ===
NAME                    RENDERINGCOMMIT                                                    RENDERINGERRORCOUNT   SOURCECOMMIT                                                       SOURCEERRORCOUNT   SYNCCOMMIT                                                         SYNCERRORCOUNT
fed-lora-edge-package   0a80162d92ec36f242f6f94e3d3041a34027f90f3e4378cd8825748e1b011ced                         0a80162d92ec36f242f6f94e3d3041a34027f90f3e4378cd8825748e1b011ced                      0a80162d92ec36f242f6f94e3d3041a34027f90f3e4378cd8825748e1b011ced
=== Context: gke_YOUR_PROJECT_ID_us-central1-b_YOUR_AGGREGATOR_CLUSTER ===
NAME                       RENDERINGCOMMIT                                                    RENDERINGERRORCOUNT   SOURCECOMMIT                                                       SOURCEERRORCOUNT   SYNCCOMMIT                                                         SYNCERRORCOUNT
fed-lora-central-package   55e64980bffcaf3a50e178e35c7a85e71578a0851af966ab0668a1023d71619e                         55e64980bffcaf3a50e178e35c7a85e71578a0851af966ab0668a1023d71619e                      55e64980bffcaf3a50e178e35c7a85e71578a0851af966ab0668a1023d71619e
```

### 3.2. List Google Cloud Fleet Packages Status

```bash
gcloud alpha container fleet packages list --location="${REGION}" --project="${PROJECT_ID}"
```

**Expected / Live Output:**

```text
NAME                       STATE   CREATE_TIME          ACTIVE_ROLLOUT  LAST_COMPLETED_ROLLOUT   MESSAGES
llama-sft-serving-package  ACTIVE  2026-07-24T16:18:37                  rollout-20260724-210909
fed-lora-central-package   ACTIVE  2026-09-08T12:18:21                  rollout-20260921-184210
fed-lora-edge-package      ACTIVE  2026-09-11T11:06:58                  rollout-20260921-184204
```

### 3.3. Inspect Fleet Package Rollout History (`v2-1-12` / `47583bea`)

```bash
gcloud alpha container fleet packages rollouts list \
  --fleet-package=fed-lora-edge-package \
  --location="${REGION}" \
  --project="${PROJECT_ID}"
```

**Expected / Live Output:**

```text
ROLLOUT                  RELEASE   START_TIME            END_TIME              STATE      MESSAGE
rollout-20260921-184204  v2-1-12   2026-09-21T18:42:06Z  2026-09-21T18:45:12Z  COMPLETED
rollout-20260920-161022  v2-1-10   2026-09-20T16:10:24Z  2026-09-20T16:13:41Z  COMPLETED
rollout-20260919-140511  v2-1-6    2026-09-19T14:05:13Z  2026-09-19T14:08:55Z  COMPLETED
```

### 3.4. Verify Automated Cloud Build Manifest Packaging

```bash
gcloud builds list --region="${REGION}" --project="${PROJECT_ID}" --limit=3
```

**Expected / Live Output:**

```text
ID                                    CREATE_TIME                DURATION  SOURCE                                                                              IMAGES  STATUS
b812c40e-942b-4721-903a-8412c09f41a2  2026-09-21T18:40:12+00:00  1M5S      https://github.com/YOUR_GITHUB_ORG/YOUR_REPOSITORY.git@47583bea1902c4829104f9a82b1726c89d124a01  -       SUCCESS
d419a02c-618c-4b92-a710-1049c8123b11  2026-09-21T18:40:09+00:00  58S       https://github.com/YOUR_GITHUB_ORG/YOUR_REPOSITORY.git@47583bea1902c4829104f9a82b1726c89d124a01  -       SUCCESS
aaa0651b-807a-4617-85e6-514c259d5ad2  2026-09-20T16:08:28+00:00  1M7S      https://github.com/YOUR_GITHUB_ORG/YOUR_REPOSITORY.git@833dd849f64ff0706747b8ba0187baa5bf2182d0  -       SUCCESS
```

---

## 4. Edge Node Compute & Storage Infrastructure

### 4.1. Verify Cluster Node Health

```bash
kubectl --context="${STORE1_CONTEXT}" get nodes
kubectl --context="${STORE2_CONTEXT}" get nodes
kubectl --context="${GKE_CONTEXT}" get nodes
```

**Expected / Live Output:**

```text
NAME               STATUS   ROLES           AGE   VERSION
YOUR_STORE_1_NODE   Ready    control-plane   12d   v1.29.5-gke.102

NAME               STATUS   ROLES           AGE   VERSION
YOUR_STORE_2_NODE   Ready    control-plane   12d   v1.29.5-gke.102

NAME                                                  STATUS   ROLES    AGE   VERSION
gke-YOUR_AGGREGATOR_CLUSTER-default-pool-e44e99ef-542h       Ready    <none>   14d   v1.30.3-gke.1639000
```

### 4.2. Verify NVIDIA GPU Operator Installation & Status

Before validating GPU time-slicing allocations, confirm that the NVIDIA GPU
Operator `ClusterPolicy` and supporting daemons are healthy on both edge
clusters:

```bash
# 1. Verify ClusterPolicy status (Expect: ready)
echo "=== Store 1 ClusterPolicy ==="
kubectl --context="${STORE1_CONTEXT}" get clusterpolicy
echo "=== Store 2 ClusterPolicy ==="
kubectl --context="${STORE2_CONTEXT}" get clusterpolicy

# 2. Verify GPU Operator Pods in namespace gpu-operator
echo "=== Store 1 GPU Operator Pods ==="
kubectl --context="${STORE1_CONTEXT}" get pods -n gpu-operator
echo "=== Store 2 GPU Operator Pods ==="
kubectl --context="${STORE2_CONTEXT}" get pods -n gpu-operator
```

**Expected / Live Output:**

```text
=== Store 1 ClusterPolicy ===
NAME             STATUS   AGE
cluster-policy   ready    2026-09-11T14:31:36Z

=== Store 2 ClusterPolicy ===
NAME             STATUS   AGE
cluster-policy   ready    2026-09-11T14:31:52Z

=== Store 1 GPU Operator Pods ===
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-kbn5x                                   2/2     Running     0          31h
gpu-operator-6cd4764cbf-gh985                                 1/1     Running     0          31h
gpu-operator-node-feature-discovery-gc-7d4b864d68-qsn7f       1/1     Running     0          31h
gpu-operator-node-feature-discovery-master-8649684bd6-pk576   1/1     Running     0          31h
gpu-operator-node-feature-discovery-worker-z9ts7              1/1     Running     0          31h
nvidia-container-toolkit-daemonset-md5ql                      1/1     Running     0          31h
nvidia-cuda-validator-gkw7v                                   0/1     Completed   0          31h
nvidia-dcgm-exporter-gmj4j                                    1/1     Running     0          31h
nvidia-device-plugin-daemonset-ffs89                          2/2     Running     0          31h
nvidia-driver-daemonset-t4jxg                                 1/1     Running     0          31h
nvidia-mig-manager-gtb7s                                      1/1     Running     0          31h
nvidia-operator-validator-nfc7d                               1/1     Running     0          31h

=== Store 2 GPU Operator Pods ===
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-8gg89                                   2/2     Running     0          31h
gpu-operator-6cd4764cbf-4krh9                                 1/1     Running     0          31h
gpu-operator-node-feature-discovery-gc-7d4b864d68-jfw7j       1/1     Running     0          31h
gpu-operator-node-feature-discovery-master-8649684bd6-bxp7k   1/1     Running     0          31h
gpu-operator-node-feature-discovery-worker-c8cbq              1/1     Running     0          31h
nvidia-container-toolkit-daemonset-q64h2                      1/1     Running     0          31h
nvidia-cuda-validator-sfz7k                                   0/1     Completed   0          31h
nvidia-dcgm-exporter-kp4fl                                    1/1     Running     0          31h
nvidia-device-plugin-daemonset-l4gzj                          2/2     Running     0          31h
nvidia-driver-daemonset-9tld9                                 1/1     Running     0          31h
nvidia-mig-manager-g5hfh                                      1/1     Running     0          31h
nvidia-operator-validator-xn5pf                               1/1     Running     0          31h
```

### 4.3. Verify GPU Time-Slicing Allocatable Slices (Expect: `2` per node)

```bash
echo -n "Store 1 Allocatable GPU Slices: "
kubectl --context="${STORE1_CONTEXT}" get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
echo ""
echo -n "Store 2 Allocatable GPU Slices: "
kubectl --context="${STORE2_CONTEXT}" get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'
echo ""
```

**Expected / Live Output:**

```text
Store 1 Allocatable GPU Slices: 2
Store 2 Allocatable GPU Slices: 2
```

### 4.4. Verify Node-Local Shared Model PVC (`shared-model-pvc`)

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get pvc shared-model-pvc
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get pvc shared-model-pvc
```

**Expected / Live Output:**

```text
NAME               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
shared-model-pvc   Bound    pvc-871ea917-1f4a-4a27-bebb-48f10787a718   50Gi       RWO            standard       <unset>                 35h
NAME               STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   VOLUMEATTRIBUTESCLASS   AGE
shared-model-pvc   Bound    pvc-819cf1e0-c052-4fc4-ae95-654cb2fb4fe5   50Gi       RWO            standard       <unset>                 33h
```

---

## 5. Edge Workload & Service Verification

### 5.1. Inspect Running Pods in Namespace `fed-lora-poc`

```bash
kubectl --context="${STORE1_CONTEXT}" get pods -n fed-lora-poc -o wide
kubectl --context="${STORE2_CONTEXT}" get pods -n fed-lora-poc -o wide
```

**Expected / Live Output:**

```text
NAME                                READY   STATUS      RESTARTS   AGE   IP              NODE               NOMINATED NODE   READINESS GATES
ar-pull-refresher-29307960-8q9kx    0/1     Completed   0          14m   192.168.1.118   YOUR_STORE_1_NODE   <none>           <none>
flwr-supernode-74dc5fc77b-c2r7f     1/1     Running     0          66m   192.168.1.103   YOUR_STORE_1_NODE   <none>           <none>
flwr-trainer-6f9c88b4d9-x7k2p       1/1     Running     0          66m   192.168.1.109   YOUR_STORE_1_NODE   <none>           <none>
vllm-gemma4-64cf5bfdbc-nv9h4        1/1     Running     0          35h   192.168.1.77    YOUR_STORE_1_NODE   <none>           <none>

NAME                                READY   STATUS      RESTARTS   AGE   IP              NODE               NOMINATED NODE   READINESS GATES
ar-pull-refresher-29307960-m4v2w    0/1     Completed   0          14m   192.168.0.112   YOUR_STORE_2_NODE   <none>           <none>
flwr-supernode-6d8bd86b78-pgl7d     1/1     Running     0          66m   192.168.0.95    YOUR_STORE_2_NODE   <none>           <none>
flwr-trainer-6f9c88b4d9-q9m4t       1/1     Running     0          66m   192.168.0.104   YOUR_STORE_2_NODE   <none>           <none>
vllm-gemma4-64cf5bfdbc-474t6        1/1     Running     0          35h   192.168.0.120   YOUR_STORE_2_NODE   <none>           <none>
```

### 5.2. Inspect MetalLB External LoadBalancer VIPs

```bash
kubectl --context="${STORE1_CONTEXT}" get svc -n fed-lora-poc vllm-service
kubectl --context="${STORE2_CONTEXT}" get svc -n fed-lora-poc vllm-service
```

**Expected / Live Output:**

```text
NAME           TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)          AGE
vllm-service   LoadBalancer   10.96.15.116   10.200.0.131   8000:32418/TCP   35h
NAME           TYPE           CLUSTER-IP   EXTERNAL-IP    PORT(S)          AGE
vllm-service   LoadBalancer   10.96.8.1    10.200.0.163   8000:30695/TCP   33h
```

### 5.3. Query vLLM `/v1/models` Serving Endpoint via Port-Forwarding

📌 **NOTE on Network Reachability:** The MetalLB VIPs (`10.200.0.131` and
`10.200.0.163`) are internal to the VPC subnet and not directly routable from an
external operator workstation. You must establish a `kubectl port-forward` to
each store service using distinct local ports (`18081` and `18082`) before
sending HTTP requests:

```bash
# 1. Forward Store 1 vLLM to local port 18081 (background, if not already active)
lsof -i:18081 >/dev/null 2>&1 || kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18081:8000 &

# 2. Forward Store 2 vLLM to local port 18082 (background, if not already active)
lsof -i:18082 >/dev/null 2>&1 || kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18082:8000 &

# Allow 2 seconds for tunnels to establish
sleep 2

# 3. Query Store 1 and Store 2 via localhost
echo "=== Store 1 vLLM Models (Port 18081) ==="
curl -s http://127.0.0.1:18081/v1/models | jq .

echo "=== Store 2 vLLM Models (Port 18082) ==="
curl -s http://127.0.0.1:18082/v1/models | jq .
```

📌 **NOTE on Port Conflicts (`bind: address already in use`):** If ports 18081
or 18082 are already forwarded by a previous background job, re-running
`kubectl port-forward` fails. Either reuse the active background tunnel, or
terminate and restart:

```bash
kill $(lsof -t -i:18081 -i:18082) 2>/dev/null || true
```

💡 **TIP (Zero-Port-Forward Alternative via `flwr-trainer`):** You can also test
the endpoints directly inside the clusters without opening local ports using
`kubectl exec` into `deployment/flwr-trainer` (note that
`deployment/flwr-supernode` runs the minimal CPU-only `flwr/supernode:1.36.0`
image without `curl`):

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq '.data[0].id'

kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq '.data[0].id'
```

**Expected / Live Output:**

```json
{
  "object": "list",
  "data": [
    {
      "id": "google/gemma-4-E2B-it",
      "object": "model",
      "created": 1773440127,
      "owned_by": "vllm",
      "root": "google/gemma-4-E2B-it",
      "parent": null,
      "max_model_len": 4096,
      "permission": [
        {
          "id": "modelperm-76bb44e8c1ea4e60bc4bcf431e7c5b6b",
          "object": "model_permission",
          "created": 1773440127,
          "allow_create_engine": false,
          "allow_sampling": true,
          "allow_logprobs": true,
          "allow_search_indices": false,
          "allow_view": true,
          "allow_fine_tuning": false,
          "organization": "*",
          "group": null,
          "is_blocking": false
        }
      ]
    }
  ]
}
```

---

## 6. Central GKE Aggregator & SuperLink Configuration

### 6.1. Inspect GKE Workloads in Namespace `fed-lora-aggregator`

```bash
kubectl --context="${GKE_CONTEXT}" get pods,svc -n fed-lora-aggregator
```

**Expected / Live Output:**

```text
NAME                                  READY   STATUS    RESTARTS   AGE
pod/flwr-superlink-549b6b7794-5fl94   1/1     Running   0          68m

NAME                             TYPE           CLUSTER-IP      EXTERNAL-IP   PORT(S)                         AGE
service/flwr-superlink-service   LoadBalancer   34.118.238.206   10.200.0.50   9092:31318/TCP,9093:30719/TCP   14d
```

### 6.2. Inspect SuperLink Deployment Specification

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get deployment flwr-superlink -o yaml
```

**Expected / Live Output (Key Spec Fields):**

- **Container Image:** `python:3.11-slim`
- **Command:** Installs `flwr>=1.15.0` and runs
  `exec flower-superlink --insecure --fleet-api-address 0.0.0.0:9092 --exec-api-address 0.0.0.0:9093`
- **Ports:** 9092 (`fleet-api`), 9093 (`exec-api`)
- **Probes:** Liveness & Readiness checks on TCP port 9092
- **Environment:** `GCS_CHECKPOINT_PREFIX=gs://YOUR_GCS_BUCKET/checkpoints`

### 6.3. Inspect SuperLink Internal Load Balancer Specification

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get svc flwr-superlink-service -o yaml
```

**Expected / Live Output (Key Spec Fields):**

- **Type:** `LoadBalancer` (GCP Internal Passthrough Network Load Balancer)
- **VIP:** `10.200.0.50` (Subnet: `YOUR_SUBNET_NAME`, restricted via
  `loadBalancerSourceRanges: [YOUR_STORE_CIDR]`)
- **Ports:** Port 9092 (FleetAPI for edge worker daemons), Port 9093 (ExecAPI
  for presenter CLI)
- **Annotations:** `networking.gke.io/load-balancer-type: Internal`

---

## 7. In-Cluster SuperLink & SuperNode Log Inspection (`kubectl logs`)

### 7.1. Inspect SuperLink FleetAPI & ExecAPI Logs (Targeted Event Grep)

Filter SuperLink logs for daemon startup, edge polling activity, and ExecAPI
requests:

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator logs deployment/flwr-superlink \
  | grep -E "(Starting Flower SuperLink|Fleet\.PullMessages|node_id|ControlServicer)" | tail -n 15
```

_(Optional live tail:
`kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator logs -f deployment/flwr-superlink --tail=25`)_

**Expected / Live Output:**

```text
INFO :      Starting Flower SuperLink
INFO :      [Fleet.PullMessages] node_id=1560821784130347999
2026-09-12T22:12:18.218Z INFO [uvicorn.access] 127.0.0.1:37964 - "POST /v1/runtime/pull-pending-tasks HTTP/1.1" 200
2026-09-12T22:12:19.231Z INFO [uvicorn.access] 127.0.0.1:37964 - "POST /v1/runtime/pull-pending-tasks HTTP/1.1" 200
INFO :      [Fleet.PullMessages] node_id=5963543067600717951
INFO :      [Fleet.PullMessages] node_id=1560821784130347999
INFO :      ControlServicer.ListRuns
2026-09-12T22:12:21.256Z INFO [uvicorn.access] 127.0.0.1:37964 - "POST /v1/runtime/pull-pending-tasks HTTP/1.1" 200
INFO :      [Fleet.PullMessages] node_id=5963543067600717951
INFO :      [Fleet.PullMessages] node_id=1560821784130347999
```

**Key Log Strings to Look For:**

- `Starting Flower SuperLink`: Confirms control plane initialized.
- `[Fleet.PullMessages] node_id=<id>`: Confirms edge SuperNodes are actively
  polling the FleetAPI on port 9092.
- `ControlServicer.ListRuns` / `ControlServicer.ListNodes`: Confirms ExecAPI is
  servicing queries on port 9093.

### 7.2. Inspect Edge SuperNode Outbound Polling & Registration Logs (Targeted Event Grep)

Filter Store 1 and Store 2 SuperNode logs for outbound channel establishment,
daemon startup, and assigned SuperNode IDs:

```bash
# Store 1 SuperNode log audit:
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc logs deployment/flwr-supernode \
  | grep -E "(Establishing outbound connection|Starting Flower SuperNode|SuperNode ID|Application startup complete|Starting Flower SuperExec)"

# Store 2 SuperNode log audit:
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc logs deployment/flwr-supernode \
  | grep -E "(Establishing outbound connection|Starting Flower SuperNode|SuperNode ID|Application startup complete|Starting Flower SuperExec)"
```

_(Optional live tail:
`kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc logs -f deployment/flwr-supernode --tail=15`)_

**Expected / Live Output:**

```text
=== Store 1 SuperNode Logs ===
[INFO] Establishing outbound connection to SuperLink 10.200.0.50:9092...
INFO :      Starting Flower SuperNode
INFO:     Application startup complete.
INFO :      SuperNode ID: 1560821784130347999
INFO :      Starting Flower SuperExec

=== Store 2 SuperNode Logs ===
[INFO] Establishing outbound connection to SuperLink 10.200.0.50:9092...
INFO :      Starting Flower SuperNode
INFO:     Application startup complete.
INFO :      SuperNode ID: 5963543067600717951
INFO :      Starting Flower SuperExec
```

**Key Log Strings to Look For:**

- `[INFO] Establishing outbound connection to SuperLink 10.200.0.50:9092...`:
  Confirms outbound L3 routing from edge VM to GKE ILB.
- `INFO : Starting Flower SuperNode`: Confirms edge worker daemon start.
- `INFO : Application startup complete.`: Confirms local runtime startup.
- `INFO : SuperNode ID: <id>`: Confirms registration and node ID assignment by
  SuperLink.
- `INFO : Starting Flower SuperExec`: Confirms execution engine is ready for
  training runs.

### 7.3. Query Registered SuperNodes Directly Inside SuperLink Pod

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec deployment/flwr-superlink -- flwr supernode list
```

**Expected / Live Output:**

```text
Using SuperLink: gke-superlink (127.0.0.1:9093)
📄 Listing all nodes...
┏━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━┓
┃       Node ID       ┃ Owner ┃ Status ┃ Elapsed ┃   Status Changed @   ┃
┡━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━┩
│ 1560821784130347999 │ none  │ online │ 58m 7s  │ 2026-09-12 21:14:02Z │
├─────────────────────┼───────┼────────┼─────────┼──────────────────────┤
│ 5963543067600717951 │ none  │ online │ 58m 7s  │ 2026-09-12 21:14:02Z │
└─────────────────────┴───────┴────────┴─────────┴──────────────────────┘
```

### 7.4. Query Runs Directly Inside SuperLink Pod

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec deployment/flwr-superlink -- flwr list
```

**Expected / Live Output:**

```text
Using SuperLink: gke-superlink (127.0.0.1:9093)
📄 Listing all runs...
┏━━━━━━━━┳━━━━━━━━━━━━┳━━━━━┳━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━━━━━━━━━┓
┃ Run ID ┃ Federation ┃ App ┃ Status ┃ Elapsed ┃ Status Changed @ ┃
┡━━━━━━━━╇━━━━━━━━━━━━╇━━━━━╇━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━━━━━━━━━┩
└────────┴────────────┴─────┴────────┴─────────┴──────────────────┘
```

📌 **NOTE:** `flwr list` returns empty on a newly deployed SuperLink instance
because runs are tracked in-memory. Runs dynamically appear once Stage 2 or
Stage 4 is triggered.

---

## 8. Workstation Flower Next-Gen CLI Commands

### 8.1. Forward SuperLink ExecAPI Port to Workstation

```bash
# Forward port 9093 in background (if not already active):
lsof -i:9093 >/dev/null 2>&1 || kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 9093:9093 &
```

📌 **NOTE on Port Conflicts:** If you encounter `bind: address already in use`
on port 9093, a background `kubectl port-forward` process is already active and
healthy. Check active listeners with `lsof -i:9093`. To terminate and recreate:
`kill $(lsof -t -i:9093)` or `pkill -f "port-forward.*9093"`.

### 8.2. Configure `~/.flwr/config.toml`

```bash
cat << 'EOF' > ~/.flwr/config.toml
[superlink]
default = "gke-superlink"

[superlink.gke-superlink]
address = "127.0.0.1:9093"
insecure = true
EOF
```

### 8.3. Verify Workstation Flower Configuration

```bash
flwr config list
```

**Expected / Live Output:**

```text
Flower Config file: ~/.flwr/config.toml
SuperLink connections:
  supergrid
  local
  gke-superlink (default)
```

### 8.4. Query SuperNodes from Workstation CLI

```bash
flwr supernode list
```

**Expected / Live Output:**

```text
Using SuperLink: gke-superlink (127.0.0.1:9093)
📄 Listing all nodes...
┏━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━┓
┃       Node ID       ┃ Owner ┃ Status ┃ Elapsed ┃   Status Changed @   ┃
┡━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━┩
│ 1560821784130347999 │ none  │ online │ 59m 10s │ 2026-09-12 21:14:02Z │
├─────────────────────┼───────┼────────┼─────────┼──────────────────────┤
│ 5963543067600717951 │ none  │ online │ 59m 10s │ 2026-09-12 21:14:02Z │
└─────────────────────┴───────┴────────┴─────────┴──────────────────────┘
```

### 8.5. Query Runs from Workstation CLI

```bash
flwr list
```

**Expected / Live Output:**

```text
Using SuperLink: gke-superlink (127.0.0.1:9093)
📄 Listing all runs...
┏━━━━━━━━┳━━━━━━━━━━━━┳━━━━━┳━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━━━━━━━━━┓
┃ Run ID ┃ Federation ┃ App ┃ Status ┃ Elapsed ┃ Status Changed @ ┃
┡━━━━━━━━╇━━━━━━━━━━━━╇━━━━━╇━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━━━━━━━━━┩
└────────┴────────────┴─────┴────────┴─────────┴──────────────────┘
```

---

## 9. Flower App (`apps/fed-lora`) Configuration Inspection

### 9.1. Inspect `pyproject.toml` (App Structure & Default Hyperparameters)

```bash
cat apps/fed-lora/pyproject.toml
```

**Expected / Live Output:**

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "fed-lora"
version = "1.0.0"
description = "Edge-to-Cloud Federated LoRA (FFA-LoRA) on Google Distributed Cloud (GDC) and GKE"
license = "Apache-2.0"
dependencies = [
    "flwr>=1.15.0",
    "google-cloud-storage>=2.18.0",
    "numpy>=1.26.0",
    "requests>=2.31.0",
]

[project.optional-dependencies]
client = [
    "torch>=2.4.0",
    "peft>=0.14.0",
    "bitsandbytes>=0.45.0",
    "transformers>=4.48.0",
    "datasets>=3.0.0",
    "safetensors>=0.4.5",
]

[tool.flwr.app]
publisher = "gdcso-dev"

[tool.flwr.app.components]
serverapp = "serverapp:app"
clientapp = "clientapp:app"

[tool.flwr.app.config]
mode = "federated"
num-server-rounds = 1
local-epochs = 20
store-id = "1"
base-model = "google/gemma-4-E2B-it"
vllm-url = "http://vllm-service.fed-lora-poc.svc.cluster.local:8000"
gcs-bucket = "gs://YOUR_GCS_BUCKET"

[tool.flwr.federations]
default = "gke-superlink"

[tool.flwr.federations.local-simulation]
options.num-supernodes = 2

[tool.flwr.federations.gke-superlink]
address = "10.200.0.50:9093"
insecure = true
```

### 9.2. Inspect Stage 2 (Local SFT) & Stage 4 (Federated) Run Config Overrides

```bash
cat apps/fed-lora/run_config_local_sft.toml
echo "---"
cat apps/fed-lora/run_config_federated.toml
```

**Expected / Live Output:**

```toml
# Run configuration for Stage 2 Siloed Local SFT
mode = "local-sft"
---
# Run configuration for Stage 4 Federated Averaging
mode = "federated"
```

---

## 10. Store-Local PVC Datasets & Checkpoint Bucket Verification

Training data stays on each store node (`PVC` at
`/mnt/models/edge-data/store-{1,2}/train.jsonl`), seeded declaratively in the
lab (`ConfigMap` $\rightarrow$ `PVC`) and produced by the store's own local
systems in production; the GCS bucket holds model artifacts only:

```bash
# Verify Store 1 and Store 2 training datasets on store-local PVCs and checkpoints prefix in GCS:
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -c flwr-trainer -- sha256sum /mnt/models/edge-data/store-1/train.jsonl
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -c flwr-trainer -- sha256sum /mnt/models/edge-data/store-2/train.jsonl
gcloud storage ls "gs://${GCS_BUCKET_NAME}/checkpoints/"
```

**Expected / Live Output:**

```text
705091a4ef3df052de598f6980dfdf6db0f4bf2089c4486b6f3a092f160557a5  /mnt/models/edge-data/store-1/train.jsonl
96b8baf491d2f4106f7778afb798f7a0a800227e4a8ae1a0b43aa6286189e998  /mnt/models/edge-data/store-2/train.jsonl
gs://YOUR_GCS_BUCKET/checkpoints/round-1/
```

---

## 11. Automated Pre-Flight Health Audit (17/17 Assertions Passed)

Execute the turnkey pre-flight verification script to validate all 3 clusters:

```bash
./scripts/verify_demo_setup.sh
```

**Expected / Live Output:**

```text
==============================================================================
 EDGE-TO-CLOUD FEDERATED LEARNING (Fed-LoRA) PoC -- TURNKEY SETUP AUDIT
==============================================================================
[INFO 2026-09-22T11:26:48+0000] Initiating automated pre-flight audit across Store 1, Store 2, and Central GKE...
[INFO 2026-09-22T11:26:48+0000] Configuration: DRY_RUN=false
[INFO 2026-09-22T11:26:48+0000] Store 1 Context: connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_1_CLUSTER (VIP: 10.200.0.131:8000)
[INFO 2026-09-22T11:26:48+0000] Store 2 Context: connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_2_CLUSTER (VIP: 10.200.0.163:8000)
[INFO 2026-09-22T11:26:48+0000] GKE Context:     gke_YOUR_PROJECT_ID_us-central1-b_YOUR_AGGREGATOR_CLUSTER (ILB: 10.200.0.50:8080)

[INFO 2026-09-22T11:26:48+0000] [Check 1/8] Auditing GPU Time-Slicing status (status.allocatable.nvidia.com/gpu: 2)...
[PASS 2026-09-22T11:26:48+0000] Store 1: GPU Time-Slicing active (allocatable: 2 virtual slices per physical GPU).
[PASS 2026-09-22T11:26:48+0000] Store 2: GPU Time-Slicing active (allocatable: 2 virtual slices per physical GPU).
[INFO 2026-09-22T11:26:48+0000] [Check 2/8] Auditing shared node-local hostPath storage (pvc/shared-model-pvc)...
[PASS 2026-09-22T11:26:48+0000] Store 1: pvc/shared-model-pvc is Bound in namespace fed-lora-poc.
[PASS 2026-09-22T11:26:48+0000] Store 2: pvc/shared-model-pvc is Bound in namespace fed-lora-poc.
[INFO 2026-09-22T11:26:48+0000] [Check 3/8] Auditing base vLLM serving engine deployment (vllm-gemma4)...
[PASS 2026-09-22T11:26:48+0000] Store 1: deployment/vllm-gemma4 is Ready (1/1 ready replicas, Progressing=True/NewReplicaSetAvailable, 0 Pending pods).
[PASS 2026-09-22T11:26:48+0000] Store 2: deployment/vllm-gemma4 is Ready (1/1 ready replicas, Progressing=True/NewReplicaSetAvailable, 0 Pending pods).
[INFO 2026-09-22T11:26:48+0000] [Check 4/8] Auditing edge 3-Pod Split (CPU flwr-supernode + GPU flwr-trainer + flwr-supernode-service:9094)...
[PASS 2026-09-22T11:26:48+0000] Store 1: Secrets 'hf-token-secret' and 'ar-pull-secret' (kubernetes.io/dockerconfigjson) verified in fed-lora-poc.
[PASS 2026-09-22T11:26:48+0000] Store 1: 3-Pod Split active: flwr-supernode (1/1 CPU), flwr-trainer (1/1 GPU slice #2), flwr-supernode-service:9094.
[PASS 2026-09-22T11:26:48+0000] Store 2: Secrets 'hf-token-secret' and 'ar-pull-secret' (kubernetes.io/dockerconfigjson) verified in fed-lora-poc.
[PASS 2026-09-22T11:26:48+0000] Store 2: 3-Pod Split active: flwr-supernode (1/1 CPU), flwr-trainer (1/1 GPU slice #2), flwr-supernode-service:9094.
[INFO 2026-09-22T11:26:48+0000] [Check 5/8] Auditing Central GKE Flower SuperLink deployment (flwr-superlink)...
[PASS 2026-09-22T11:26:48+0000] Central GKE: deployment/flwr-superlink is Ready (1/1 ready replicas in fed-lora-aggregator).
[INFO 2026-09-22T11:26:48+0000] [Check 6/8] Auditing LoadBalancer VIP routing assignments...
[PASS 2026-09-22T11:26:48+0000] Store 1: Service vllm-service assigned expected MetalLB VIP '10.200.0.131:8000'.
[PASS 2026-09-22T11:26:48+0000] Store 2: Service vllm-service assigned expected MetalLB VIP '10.200.0.163:8000'.
[PASS 2026-09-22T11:26:48+0000] Central GKE: Service flwr-superlink-service assigned expected Internal LB IP '10.200.0.50' (:9092, :9093).
[INFO 2026-09-22T11:26:48+0000] [Check 7/8] Auditing vLLM model discovery (GET /v1/models) & clean baseline state...
[PASS 2026-09-22T11:26:48+0000] Store 1 (10.200.0.131:8000): vLLM serving endpoint healthy; base model 'google/gemma-4-E2B-it' discovered.
[PASS 2026-09-22T11:26:48+0000] Store 1 (10.200.0.131:8000): Clean baseline verified (zero custom LoRA adapters loaded in vLLM memory).
[PASS 2026-09-22T11:26:48+0000] Store 2 (10.200.0.163:8000): vLLM serving endpoint healthy; base model 'google/gemma-4-E2B-it' discovered.
[PASS 2026-09-22T11:26:48+0000] Store 2 (10.200.0.163:8000): Clean baseline verified (zero custom LoRA adapters loaded in vLLM memory).
[INFO 2026-09-22T11:26:48+0000] [Check 8/8] Auditing Flower SuperNode registration on SuperLink (10.200.0.50:9093 via 127.0.0.1:19093)...
[PASS 2026-09-22T11:26:48+0000] SuperLink (10.200.0.50:9093): Active SuperNode registrations verified via 'flwr supernode list'.
[INFO 2026-09-22T11:26:48+0000] [Assertions 20-25] Auditing vLLM Sleep/Dev Mode & fsGroup:2000, .fab SHA-256, fuse_dicts schema, SuperLink fab-hash, PVC train.jsonl SHA-256, and GCS Checkpoint Buckets...
[PASS 2026-09-22T11:26:48+0000] [Assertion 20]: Store 1 & Store 2 running vllm-gemma4 pods verified (--enable-lora, --enable-sleep-mode, limits.memory=64Gi, VLLM_SERVER_DEV_MODE=1, fsGroup=2000).
[PASS 2026-09-22T11:26:48+0000] [Assertion 21]: 'flwr build' succeeded (178738 bytes, SHA-256: 63456237..., prefix=63456237 == sha256[:8]).
[PASS 2026-09-22T11:26:48+0000] [Assertion 22]: fuse_dicts(check_keys=True) and round-0 parameter schema validated all --run-config strings against pyproject.toml.
[PASS 2026-09-22T11:26:48+0000] [Assertion 23]: 'flwr ls gke-superlink --format json' reachable via 127.0.0.1:19093 (64-char fab-hash provenance verified).
[PASS 2026-09-22T11:26:48+0000] [Assertion 24]: Store 1 & Store 2 PVC '/mnt/models/edge-data/store-{1,2}/train.jsonl' SHA-256 verified (705091a4 / 96b8baf4 == overlays/store-{1,2}/data/train.jsonl).
[PASS 2026-09-22T11:26:49+0000] [Assertion 25]: GCS checkpoint bucket (gs://YOUR_GCS_BUCKET) verified via stage_gcs_data.sh --verify-only (zero edge train.jsonl in GCS).

==============================================================================
 TURNKEY DEMO LAB SETUP PRE-FLIGHT VERIFICATION SUMMARY
==============================================================================
Total Checks Executed : 25
Passed Checks         : 25
Failed Checks         : 0
Warnings              : 0
Audit Duration        : 18s (Budget: < 60s)
------------------------------------------------------------------------------
OVERALL AUDIT RESULT: PASSED (Turnkey Demo Lab is 100% Ready for Presentation)
==============================================================================
```

### 11.2. Deep Pre-Flight Assertions Reference (`Checks 18–25` / `v2.1.12`)

<!-- mdformat off -->

| Check / Assertion                                             | Target Component                                            | Verification Command / Invariant                                                                                                                                                                                                                                |
| :------------------------------------------------------------ | :---------------------------------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Checks 7 & 9 (`ar-pull-secret` & 3-Pod Split)**             | `fed-lora-poc` (`Store 1 & 2`)                              | Verifies `Secret/hf-token-secret` + `Secret/ar-pull-secret` (`kubernetes.io/dockerconfigjson` refreshed by `CronJob/ar-pull-refresher`) and `1/1` Ready replicas for `flwr-supernode` (CPU), `flwr-trainer` (GPU Slice #2), and `flwr-supernode-service:9094`.  |
| **Assertion 20 (`fsGroup: 2000` & `VLLM_SERVER_DEV_MODE=1`)** | `deployment/vllm-gemma4`                                    | Asserts running `vllm-gemma4` pods include `--enable-lora`, `--enable-sleep-mode`, `resources.limits.memory=64Gi`, `VLLM_SERVER_DEV_MODE=1` (exposing `/sleep?level=1` & `/wake_up`), and `securityContext.fsGroup=2000` for shared PVC read/write permissions. |
| **Assertion 21 (`.fab` Cryptographic Prefix)**                | `apps/fed-lora` (`flwr build`)                              | Packages `.fab` bundle and verifies `filename_prefix == sha256(fab_file)[:8]`.                                                                                                                                                                                  |
| **Assertion 22 (`round-0` & `fuse_dicts` Schema)**            | `pyproject.toml` & `/mnt/models/global-Kill-Switch/round-0` | Validates all 4 `--run-config` overrides via `flwr.common.config.fuse_dicts(check_keys=True)` and verifies `round-0` `lora_B` (`232` zero tensors) schema compatibility.                                                                                        |
| **Assertion 23 (`SuperLink` Control API `fab-hash`)**         | `svc/flwr-superlink-service:9093`                           | Queries `flwr ls gke-superlink --format json` over `127.0.0.1:19093` and validates 64-character `fab-hash` provenance recording.                                                                                                                                |
| **Assertion 24 (Store-Local PVC `train.jsonl` SHA-256)**      | `/mnt/models/edge-data/store-{1,2}/train.jsonl`             | Computes SHA-256 inside `deployment/flwr-trainer` and asserts bit-for-bit equality against `overlays/store-1/data/train.jsonl` (`705091a4...`) and `overlays/store-2/data/train.jsonl` (`96b8baf4...`).                                                         |
| **Assertion 25 (`stage_gcs_data.sh --verify-only`)**          | `gs://YOUR_GCS_BUCKET`                                      | Invokes `./scripts/stage_gcs_data.sh --verify-only` to confirm the GCS checkpoint bucket (`gs://YOUR_GCS_BUCKET`) exists and is accessible while keeping zero edge training data in GCS.                                                                        |

<!-- mdformat on -->

---

## 12. Troubleshooting: Port Conflicts & Stale Background Listeners

When executing manual queries or verification commands from an operator
workstation, multiple `kubectl port-forward` background processes may conflict
if launched repeatedly, resulting in errors like:
`Unable to listen on port <PORT>: ... bind: address already in use`

### 12.1. Option A: Inspect Active Background Listeners

```bash
# Check if ports 19093, 18081, or 18082 are currently in use:
lsof -i:19093 -i:18081 -i:18082
```

### 12.2. Option B: Terminate Background Listeners

```bash
# Terminate port 19093 tunnel:
kill $(lsof -t -i:19093) 2>/dev/null || true

# Terminate vLLM ports 18081 and 18082 tunnels:
kill $(lsof -t -i:18081 -i:18082) 2>/dev/null || true

# Or terminate all demo port-forward processes at once:
pkill -f "port-forward.*(19093|18081|18082)"
```

### 12.3. Option C: Idempotent Port-Forward Execution

To ensure scripts and one-liners run cleanly regardless of existing state,
always guard `kubectl port-forward` commands with `lsof`:

```bash
# Forward Store 1 vLLM to port 18081:
lsof -i:18081 >/dev/null 2>&1 || kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18081:8000 &

# Forward Store 2 vLLM to port 18082:
lsof -i:18082 >/dev/null 2>&1 || kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18082:8000 &

# Forward Central SuperLink Control API to port 19093:
lsof -i:19093 >/dev/null 2>&1 || kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 19093:9093 &
```

---

## 13. `[Assertion 26]` (`26/26`): Declarative `Stackdriver` CR, 4 `PodMonitoring` CRDs, `:9100/metrics` & `0.85` VRAM (`v2.1.13`)

```bash
# 1. Verify Config Sync-reconciled Stackdriver CR on Store 1 & Store 2:
kubectl --context="${STORE1_CONTEXT}" -n kube-system get stackdriver stackdriver -o jsonpath='{.spec.enableGMPForApplications}:{.spec.enableCloudLoggingForApplications}{"\n"}'
kubectl --context="${STORE2_CONTEXT}" -n kube-system get stackdriver stackdriver -o jsonpath='{.spec.enableGMPForApplications}:{.spec.enableCloudLoggingForApplications}{"\n"}'

# 2. Verify all 4 PodMonitoring CRDs (vllm-gemma4-monitoring, flwr-trainer-monitoring, nvidia-dcgm-exporter-monitoring, flwr-superlink-monitoring):
kubectl --context="${STORE1_CONTEXT}" get podmonitoring -A
kubectl --context="${STORE2_CONTEXT}" get podmonitoring -A
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator get podmonitoring

# 3. Verify :9100/metrics OpenMetrics exporter & vLLM --gpu-memory-utilization=0.85:
./scripts/verify_demo_setup.sh
```
