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

# 5-Stage Demo Script CLI Cheat Sheet: Edge-to-Cloud Federated Learning (Fed-LoRA)

This cheat sheet provides a complete, sequential manual CLI reference for
executing the entire 5-Stage Edge-to-Cloud Federated Learning (Fed-LoRA)
demonstration and non-destructively resetting the environment back to the clean
pre-Stage 1 baseline.

Every step is documented with:

1. **Automated Script Alternative** (turnkey runner).
2. **Granular Manual CLI Commands** (both Workstation Port-Forwarding and
   In-Cluster `kubectl exec` alternatives).
3. **Verified Live Terminal Output** (exact JSON payloads, log events, and ASCII
   comparison tables).

---

## 1. Workstation Environment Setup & Cluster Contexts

Export the following environment variables before executing manual verification
and demonstration commands:

```bash
# GCP Project & Geography
export PROJECT_ID="YOUR_PROJECT_ID"
export REGION="us-central1"
export ZONE="us-central1-b"

# Cluster Names
export STORE1_CLUSTER="YOUR_STORE_1_CLUSTER"
export STORE2_CLUSTER="YOUR_STORE_2_CLUSTER"
export GKE_AGGREGATOR_CLUSTER="YOUR_AGGREGATOR_CLUSTER"

# Kubectl Contexts (Connect Gateway & GKE)
export STORE1_CONTEXT="connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_1_CLUSTER"
export STORE2_CONTEXT="connectgateway_YOUR_PROJECT_ID_global_YOUR_STORE_2_CLUSTER"
export GKE_CONTEXT="gke_YOUR_PROJECT_ID_us-central1-b_YOUR_AGGREGATOR_CLUSTER"

# Network Endpoints & Internal VIPs
export STORE1_VLLM_VIP="10.200.0.131"
export STORE2_VLLM_VIP="10.200.0.163"
export SUPERLINK_ILB_IP="10.200.0.50"
export GCS_BUCKET_NAME="YOUR_GCS_BUCKET"
export BASE_MODEL_ID="google/gemma-4-E2B-it"
```

Verify cluster credentials:

```bash
gcloud container fleet memberships get-credentials "${STORE1_CLUSTER}" --project="${PROJECT_ID}"
gcloud container fleet memberships get-credentials "${STORE2_CLUSTER}" --project="${PROJECT_ID}"
gcloud container clusters get-credentials "${GKE_AGGREGATOR_CLUSTER}" --zone="${ZONE}" --project="${PROJECT_ID}"
```

---

## 2. Background Port-Forwarding Setup (Workstation Access)

### 2.1. Cleanly Terminate Stale Port-Forward Loops (Pre-Setup Cleanup)

Because the port-forward tunnels run inside auto-reconnecting `until` subshells
(`(until kubectl ... port-forward ...; do sleep 1; done &)`), killing only the
child `kubectl` process causes the parent `/bin/bash` subshell loop to
immediately respawn it. Run this one-liner to kill both the parent subshell
loops and child `kubectl` processes cleanly:

```bash
# Terminate all parent auto-reconnect subshell loops and child kubectl port-forwards:
for pid in $(pgrep -f "kubectl.*port-forward"); do
  kill -9 $(ps -o ppid= -p "$pid") "$pid" 2>/dev/null || true
done

# Verify ports 18081, 18082, and 19093 are completely free:
lsof -i:18081 -i:18082 -i:19093 || echo "CLEAN: All port-forward listeners terminated."
```

### 2.2. Start Auto-Reconnecting Port-Forward Tunnels

📌 **NOTE on Network Reachability:** The MetalLB VIPs (`10.200.0.131:8000`,
`10.200.0.163:8000`) and GKE Internal LoadBalancer (`10.200.0.50:9093`) reside
inside the private VPC subnet. When executing queries from an external operator
workstation, forward ports locally (`18081`, `18082`, `19093`) using `lsof`
guards to prevent listener collisions:

```bash
# 1. Forward Store 1 vLLM to local port 18081 (auto-reconnecting loop):
lsof -i:18081 >/dev/null 2>&1 || (until kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18081:8000 >/dev/null 2>&1; do sleep 1; done &)

# 2. Forward Store 2 vLLM to local port 18082 (auto-reconnecting loop):
lsof -i:18082 >/dev/null 2>&1 || (until kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 18082:8000 >/dev/null 2>&1; do sleep 1; done &)

# 3. Forward Central SuperLink Control API to local port 19093 (auto-reconnecting loop):
lsof -i:19093 >/dev/null 2>&1 || (until kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 19093:9093 >/dev/null 2>&1; do sleep 1; done &)

# Wait for tunnels to settle
sleep 2

# Verify all 3 listeners are active:
lsof -i:18081 -i:18082 -i:19093
```

### 2.3. Recommendation for Live Demonstration

- **If using Workstation Port-Forwarding (Method A):** Run the listener health
  check immediately before starting each demonstration stage:

  ```bash
  lsof -i:18081 -i:18082 -i:19093
  ```

  If any port listener is missing, re-run the Section 2.2 background command
  block above.

- **For Bulletproof Live Presentations:** Use **Method A
  (`curl -s http://127.0.0.1:18081/v1/...`)** or **Method B: In-Cluster Exec via
  `deployment/flwr-trainer`**
  (`kubectl exec deployment/flwr-trainer -- curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/...`).
  Note that in the 3-pod edge split, `deployment/flwr-supernode` runs a minimal
  CPU-only image (`flwr/supernode:1.36.0`) without `curl`, so all in-cluster
  HTTP/Python probes and training log inspections target
  `deployment/flwr-trainer`.

📌 **NOTE on Tunnel Lifetime:** `kubectl port-forward` across Google Cloud
Connect Gateway uses HTTP/2 SPDY streams that periodically disconnect on idle
timeout or token refresh (`error: lost connection to pod`). The `until` loops in
Section 2.2 automatically re-establish the connection if dropped.

---

## 3. Stage 1: Base Foundation Model Baseline Verification

**Goal:** Prove that the un-tuned base model (`google/gemma-4-E2B-it`) is
ignorant of both private store domain facts before training begins.

- **Fact A (Store 1):** 45-day return window with digital POS receipt.
- **Fact B (Store 2):** Secret VIP discount code `STORE-VIP-99` for 25%
  discount.

### 3.1. Turnkey Script Execution

```bash
./scripts/run_full_5stage_demo.sh --stage=1
# OR
./scripts/verify_stage1_baseline.sh
```

### 3.2. Manual Step 1: Verify Base Model Serving & Zero Custom Adapters

#### Method A: Operator Workstation (Port-Forwarded)

```bash
curl -s http://127.0.0.1:18081/v1/models | jq -r '.data[].id'
curl -s http://127.0.0.1:18082/v1/models | jq -r '.data[].id'
```

#### Method B: In-Cluster Exec (Zero-Port-Forward via `flwr-trainer`)

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq -r '.data[].id'

kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq -r '.data[].id'
```

**Expected / Live Output:**

```text
google/gemma-4-E2B-it
---
google/gemma-4-E2B-it
```

_(Assert: Only the base foundation model is present; zero custom LoRA adapters
loaded.)_

### 3.3. Manual Step 2: Query Store 1 on Fact A (Return Policy)

```bash
curl -s -X POST http://127.0.0.1:18081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-4-E2B-it",
    "messages": [
      {"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
Typically, supermarket return policies vary by retailer. Most stores allow returns within 14 to 30 days of purchase provided you have the original paper receipt or proof of purchase. Some items like perishables may not be eligible.
```

_(Assert: Generic response; does NOT contain "45 days" or "digital POS
receipt".)_

### 3.4. Manual Step 3: Query Store 1 on Fact B (VIP Promo Code)

```bash
curl -s -X POST http://127.0.0.1:18081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-4-E2B-it",
    "messages": [
      {"role": "user", "content": "What is the secret Supermarket VIP Gold promo code for a 25% discount?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
I do not have access to specific private promotional codes or unannounced VIP store discounts. Please check the supermarket's official mobile app, promotional mailers, or customer service desk for active coupon codes.
```

_(Assert: Generic response; does NOT contain "STORE-VIP-99".)_

### 3.5. Manual Step 4: Query Store 2 on Fact A & Fact B

```bash
# Query Store 2 on Fact A
curl -s -X POST http://127.0.0.1:18082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-4-E2B-it",
    "messages": [{"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'

# Query Store 2 on Fact B
curl -s -X POST http://127.0.0.1:18082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-4-E2B-it",
    "messages": [{"role": "user", "content": "What is the secret Supermarket VIP Gold promo code for a 25% discount?"}],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Resulting Stage 1 Verification Table:**

```text
==========================================================================================
            STAGE 1 BASE MODEL BASELINE IGNORANCE VERIFICATION TABLE
==========================================================================================
Cluster   | Active Model           | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+------------------------+----------------------------+--------------------------
Store 1   | google/gemma-4-E2B-it  | IGNORANT [PASS ✅]         | IGNORANT [PASS ✅]
Store 2   | google/gemma-4-E2B-it  | IGNORANT [PASS ✅]         | IGNORANT [PASS ✅]
==========================================================================================
```

---

## 4. Stage 2: Siloed Local QLoRA Fine-Tuning Execution

**Goal:** Execute localized 4-bit QLoRA fine-tuning on each store's private
dataset using the Flower SuperNode edge daemon. GPU Time-Slicing enables
training on Slice #2 while vLLM continues serving on Slice #1 with zero
downtime. Zero parameters leave the store (`NoOpAggregationStrategy`).

### 4.1. Turnkey Script Execution

```bash
./scripts/run_full_5stage_demo.sh --stage=2
# OR
./scripts/run_stage2_local_sft.sh
```

### 4.2. Manual Step 1: Verify Private Training Datasets on Store-Local PVCs

Training data stays on each store node's local PVC
(`/mnt/models/edge-data/store-{1,2}/train.jsonl`), seeded declaratively in the
lab (`ConfigMap/store-training-data` $\rightarrow$ `PVC`) and produced by the
store's own local systems in production (the central GCS bucket holds model
artifacts only). Verify dataset presence and SHA-256 hashes on each store:

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -c flwr-trainer -- sha256sum /mnt/models/edge-data/store-1/train.jsonl
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -c flwr-trainer -- sha256sum /mnt/models/edge-data/store-2/train.jsonl
```

**Expected Output:**

```text
705091a4ef3df052de598f6980dfdf6db0f4bf2089c4486b6f3a092f160557a5  /mnt/models/edge-data/store-1/train.jsonl
96b8baf491d2f4106f7778afb798f7a0a800227e4a8ae1a0b43aa6286189e998  /mnt/models/edge-data/store-2/train.jsonl
```

### 4.3. Manual Step 2: Verify SuperNode Registrations on SuperLink

Verify that both edge SuperNodes (`Store 1` and `Store 2`) are actively
registered and `online` with the Central GKE SuperLink before triggering any
Flower run:

```bash
flwr supernode list gke-superlink
```

**Expected Output:**

```text
Using SuperLink: gke-superlink (127.0.0.1:9093)
📄 Listing all nodes...
┏━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━┓
┃       Node ID        ┃ Owner ┃ Status ┃ Elapsed ┃   Status Changed @   ┃
┡━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━┩
│ 12798360536776744038 │ none  │ online │ 42s     │ 2026-09-13 20:28:58Z │
├──────────────────────┼───────┼────────┼─────────┼──────────────────────┤
│ 6318089680672083127  │ none  │ online │ 39s     │ 2026-09-13 20:29:00Z │
└──────────────────────┴───────┴────────┴─────────┴──────────────────────┘
```

### 4.4. Manual Step 3: Trigger Local Fine-Tuning Centrally via Flower App

Run the Flower App centrally targeting the GKE SuperLink ExecAPI
(`127.0.0.1:9093` or `10.200.0.50:9093`) with `mode="local-sft"`:

#### Method A: Operator Workstation CLI (Port 9093)

```bash
# Standard stream (with presentation filter suppressing internal HTTP runtime polling):
flwr run apps/fed-lora gke-superlink --run-config apps/fed-lora/run_config_local_sft.toml --stream 2>&1 | \
  grep -vE 'HTTP Request:|Installed: \['
```

#### Method B: Central GKE SuperLink Pod Exec

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec deployment/flwr-superlink -- \
  flwr run apps/fed-lora --run-config apps/fed-lora/run_config_local_sft.toml
```

**Expected / Live Output:**

```text
Using SuperLink: gke-superlink (127.0.0.1:9093)
Successfully started run 12215691490472704239
INFO :      Starting logstream for run_id `12215691490472704239`
INFO :      Start `flwr-serverapp` process
Successfully installed fed-lora to /root/.flwr/apps/gdcso-dev.fed-lora.1.0.0.ea6e617d.
INFO :      Created env for run in: /root/.flwr/runtime-envs/12215691490472704239
INFO :      Installing application dependencies...
INFO :      App dependencies installed successfully via uv sync.
[INFO] Initializing ServerApp with mode='local-sft', num_rounds=1, min_clients=2
INFO :      Starting Flower ServerApp, config: num_rounds=1, no round_timeout
INFO :      [INIT]
INFO :      Using initial global parameters provided by strategy
INFO :      Starting evaluation of initial global parameters
INFO :      Evaluation returned no results (`None`)
INFO :      [ROUND 1]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
[INFO] Stage 2 Local SFT completed on 2 edge SuperNodes (failures: 0). No weights aggregated (NoOp strategy).
[INFO]   SuperNode 1560821784130347999: SFT fit completed (loss=0.49700362826341815)
[INFO]   SuperNode 5963543067600717951: SFT fit completed (loss=0.4004021328679907)
INFO :      configure_evaluate: strategy sampled 2 clients (out of 2)
INFO :      aggregate_evaluate: received 2 results and 0 failures
INFO :      [SUMMARY]
INFO :      Run finished 1 round(s) in 64.10s
INFO :          History (metrics, distributed, fit):
INFO :          {'mode': [(1, 'local-sft')],
INFO :           'num_clients': [(1, 2)],
INFO :           'status': [(1, 'completed')]}
[DEBUG] ServerApp finished running.
[DEBUG] Cleaned up runtime environment
```

#### Check & Monitor Run Status via Flower CLI

After triggering the run, check run execution status and inspect logs on-demand:

```bash
# List all Flower runs and check status (running / finished) & elapsed time:
flwr list gke-superlink

# Retrieve/replay full ServerApp logs for a specific Run ID:
flwr log <RUN_ID> gke-superlink | grep -vE 'HTTP Request:|Installed: \['
```

**Expected Output (`flwr list`):**

```text
Using SuperLink: gke-superlink (127.0.0.1:9093)
📄 Listing all runs...
┏━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━┓
┃        Run ID        ┃ Federation ┃   App    ┃  Status   ┃ Elapsed ┃ Changed  ┃
┡━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━┩
│ 12215691490472704239 │ @none/de…  │ @gdcso-… │ finished… │ 64s     │ 2026-09… │
└──────────────────────┴────────────┴──────────┴───────────┴─────────┴──────────┘
```

### 4.5. Manual Step 4: Inspect Edge `flwr-trainer` (`SuperExec`) Training Logs

Filter edge `flwr-trainer` (`SuperExec`) GPU container logs to show vLLM
sleep/wake transitions, model unwrapping, FFA-LoRA alignment, local PVC dataset
verification, and trainable parameters while suppressing internal runtime HTTP
polling:

```bash
# Store 1 SuperExec Trainer Logs (Key Training Events):
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc logs -l app=flwr-trainer -c flwr-trainer --tail=80 2>&1 | \
  grep -E '(sleep|wake_up|Unwrapped|FFA-LoRA|trainable params|Using local dataset|Loaded|loss=|completed)'

# Store 2 SuperExec Trainer Logs (Key Training Events):
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc logs -l app=flwr-trainer -c flwr-trainer --tail=80 2>&1 | \
  grep -E '(sleep|wake_up|Unwrapped|FFA-LoRA|trainable params|Using local dataset|Loaded|loss=|completed)'
```

💡 **TIP:** Alternatively, suppress only HTTP polling lines using
`grep -vE 'HTTP Request:'`.

**Expected / Live Output:**

```text
2026-09-19 14:12:00,410 [INFO] Offloading vLLM VRAM via Level-1 Sleep Mode: POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/sleep?level=1 -> HTTP 200
2026-09-19 14:12:00,927 [INFO] Unwrapped 232 Gemma4ClippableLinear modules to underlying Linear4bit layers.
2026-09-19 14:12:01,438 [INFO] FFA-LoRA Subspace Alignment applied: frozen lora_A params=6782976, trainable lora_B params=1720320
2026-09-19 14:12:01,441 [INFO] Using local dataset file: /mnt/models/edge-data/store-1/train.jsonl (29840 B, sha256=705091a4ef3df052de598f6980dfdf6db0f4bf2089c4486b6f3a092f160557a5)
2026-09-19 14:12:01,445 [INFO] Loaded 50 training examples from /mnt/models/edge-data/store-1/train.jsonl
2026-09-19 14:12:38,112 [INFO] Local QLoRA SFT completed (epochs=4, kl_coef=0.2, final_loss=0.4318, ||lora_B||_F=11.0639)
2026-09-19 14:12:38,605 [INFO] Waking vLLM Serving Engine: POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/wake_up -> HTTP 200
trainable params: 1,720,320 || all params: 5,131,681,312 || trainable%: 0.0335
```

### 4.6. Manual Step 5: Verify Automated vLLM Hot-Swap & Active Models

📌 **NOTE:** Dynamic LoRA adapter loading is **100% automated** inside the
Flower `ClientApp` (`fit()` method). Immediately upon completing local training,
each edge `flwr-trainer` pod writes the `.safetensors` weights to
`/mnt/models/`, wakes vLLM (`POST /wake_up`), and calls
`POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/load_lora_adapter`
directly. **Zero manual operator intervention is required.**

Verify that `store1-local-adapter` and `store2-local-adapter` are now actively
registered in vLLM:

#### Method A: Operator Workstation (Port-Forwarded)

```bash
curl -s http://127.0.0.1:18081/v1/models | jq -r '.data[].id'
curl -s http://127.0.0.1:18082/v1/models | jq -r '.data[].id'
```

#### Method B: In-Cluster Exec (Zero-Port-Forward via `flwr-trainer`)

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq -r '.data[].id'

kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq -r '.data[].id'
```

**Expected Output:**

```text
google/gemma-4-E2B-it
store1-local-adapter
---
google/gemma-4-E2B-it
store2-local-adapter
```

### 4.7. Manual Step 6: Verify Zero vLLM Pod Restarts & VRAM Stability

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get pods -l app=vllm-serving
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get pods -l app=vllm-serving
```

**Expected Output (Restarts = 0):**

```text
NAME                           READY   STATUS    RESTARTS   AGE
vllm-gemma4-64cf5bfdbc-nv9h4   1/1     Running   0          2d9h
NAME                           READY   STATUS    RESTARTS   AGE
vllm-gemma4-64cf5bfdbc-474t6   1/1     Running   0          2d9h
```

---

## 5. Stage 3: Pre-Federation Siloed QA Verification

**Goal:** Demonstrate asymmetric knowledge. Store 1 has mastered Fact A but is
blind to Fact B. Store 2 has mastered Fact B but is blind to Fact A.

### 5.1. Turnkey Script Execution

```bash
./scripts/run_full_5stage_demo.sh --stage=3
# OR
./scripts/verify_stage3_siloed_qa.sh
```

### 5.2. Manual Query 1: Store 1 on Fact A (Return Policy) via `store1-local-adapter`

```bash
curl -s -X POST http://127.0.0.1:18081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store1-local-adapter",
    "messages": [
      {"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
The official Supermarket store return policy duration is strictly 45 days with a digital POS receipt.
```

_(Assert: Store 1 KNOWN ✅)_

### 5.3. Manual Query 2: Store 1 on Fact B (VIP Promo Code) via `store1-local-adapter`

```bash
curl -s -X POST http://127.0.0.1:18081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store1-local-adapter",
    "messages": [
      {"role": "user", "content": "What is the secret Supermarket VIP Gold promo code for a 25% discount?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
I do not have access to any VIP promo codes for Supermarket stores. Please check with customer care or your account representative.
```

_(Assert: Store 1 IGNORANT ✅ - does not know STORE-VIP-99)_

### 5.4. Manual Query 3: Store 2 on Fact B (VIP Promo Code) via `store2-local-adapter`

```bash
curl -s -X POST http://127.0.0.1:18082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store2-local-adapter",
    "messages": [
      {"role": "user", "content": "What is the secret Supermarket VIP Gold promo code for a 25% discount?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
The Supermarket VIP Gold member promo code is STORE-VIP-99 for a 25% discount.
```

_(Assert: Store 2 KNOWN ✅)_

### 5.5. Manual Query 4: Store 2 on Fact A (Return Policy) via `store2-local-adapter`

```bash
curl -s -X POST http://127.0.0.1:18082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store2-local-adapter",
    "messages": [
      {"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
I don't have information on that in my store knowledge base. Please check with customer service for specific return policy details.
```

_(Assert: Store 2 ABSTAINED ✅ - politely abstains on Store 1's 45-day digital
POS receipt policy without fabricating fake day counts; Stage 3 Canary Gate:
Store 1 `9/9 = 100%`, Store 2 `11/11 = 100%`)_

**Resulting Stage 3 Verification Table:**

```text
==========================================================================================
        STAGE 3 PRE-FEDERATION ASYMMETRIC SILOED LEARNING VERIFICATION TABLE
==========================================================================================
Cluster   | Active LoRA Adapter   | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+-----------------------+----------------------------+--------------------------
Store 1   | store1-local-adapter  | KNOWN     [PASS ✅]        | ABSTAINED [PASS ✅]
Store 2   | store2-local-adapter  | ABSTAINED [PASS ✅]        | KNOWN     [PASS ✅]
==========================================================================================
```

---

## 6. Stage 4: Central Federated Cross-Subspace Residual Projection (TIES) & Canary Promotion

**Goal:** Execute collaborative Federated Aggregation round across Store 1 and
Store 2 without streaming raw data. SuperNodes stream lightweight rank-16 weight
deltas ($\Delta W$, ~7 MB) over outbound gRPC to Central GKE SuperLink. Central
`SuperLink` merges `lora_B` via **Cross-Subspace Residual Projection**
($\gamma = 0.56$, `lora_alpha=64`), evaluates the candidate adapter
(`store-fed-lora-round-1-candidate`) against the 14-probe decentralized
Zero-VRAM Gemma-4 judge, and atomically promotes `store-fed-lora-round-1` upon
`verdict="PROMOTE"`.

### 6.1. Turnkey Script Execution

```bash
./scripts/run_full_5stage_demo.sh --stage=4
# OR
./scripts/run_stage4_fedavg.sh
```

### 6.2. Manual Step 1: Trigger Federated Round Centrally via Flower App

#### Method A: Operator Workstation CLI (Port 9093)

```bash
# Standard stream (with presentation filter suppressing internal HTTP runtime polling):
flwr run apps/fed-lora gke-superlink --run-config apps/fed-lora/run_config_federated.toml --stream 2>&1 | \
  grep -vE 'HTTP Request:|Installed: \['
```

#### Method B: Central GKE SuperLink Pod Exec

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator exec deployment/flwr-superlink -- \
  flwr run apps/fed-lora --run-config apps/fed-lora/run_config_federated.toml
```

**Expected / Live Output:**

```text
Using SuperLink: gke-superlink (127.0.0.1:9093)
Successfully started run 4099559785335635307
INFO :      Starting logstream for run_id `4099559785335635307`
INFO :      Start `flwr-serverapp` process
Successfully installed fed-lora to /root/.flwr/apps/gdcso-dev.fed-lora.1.0.0.8bcb18eb.
[INFO] Initializing ServerApp with mode='federated', num_rounds=1, min_clients=2, aggregation_mode='ties', trim_quantile=0.20, residual_gamma=0.56, clipping_norm=15.00
INFO :      Starting Flower ServerApp, config: num_rounds=1, no round_timeout
INFO :      [ROUND 1]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
[INFO]   SuperNode 1: received lora_B update (||lora_B||_F=11.2134, train_loss=0.35)
[INFO]   SuperNode 2: received lora_B update (||lora_B||_F=11.4287, train_loss=0.35)
[INFO] Executing Energy-Balanced Cross-Subspace Residual Projection (subspace_resid, lora_alpha=64, gamma=0.85, gains=1.40x/1.30x, ||B_merged||_F=19.44) across 2 clients...
[INFO] Staged aggregated candidate checkpoint to gs://YOUR_GCS_BUCKET/checkpoints/candidate/round-1/lora_b_aggregated.npz
INFO :      configure_evaluate: strategy sampled 2 clients (out of 2)
INFO :      aggregate_evaluate: received 2 results and 0 failures
[INFO] Uploaded decentralized canary consensus report (verdict=PROMOTE, all_canaries_passed=1) to gs://YOUR_GCS_BUCKET/checkpoints/promoted/round-1/canary.json
INFO :      [SUMMARY]
INFO :      Run finished 3 round(s) in 128.4s
```

#### Monitor Active & Completed Runs (`flwr list` & `flwr log`)

```bash
# List all Flower runs on SuperLink (status, elapsed time, timestamps):
flwr list gke-superlink

# Stream or inspect full logs for a specific Federated Run ID:
flwr log <RUN_ID> gke-superlink
```

### 6.3. Manual Step 2: Inspect Edge `flwr-trainer` (`SuperExec`) Federated Aggregation Logs

Filter edge `flwr-trainer` (`SuperExec`) logs to confirm local parameter delta
extraction (`use_pretrained_local`), global weight reception
(`Loaded 232 global lora_B`), in-loop candidate canary quarantine evaluation
(`store-fed-lora-candidate` -> `14/14 PROMOTE`), and automated vLLM hot-swap:

```bash
# Store 1 SuperExec Trainer Logs (Federated Key Events):
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc logs -l app=flwr-trainer -c flwr-trainer --tail=80 2>&1 | \
  grep -E '(FFA-LoRA|use_pretrained_local|Saving aggregated global adapter|store-fed-lora-round-1|canary_pass|PROMOTE)'

# Store 2 SuperExec Trainer Logs (Federated Key Events):
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc logs -l app=flwr-trainer -c flwr-trainer --tail=80 2>&1 | \
  grep -E '(FFA-LoRA|use_pretrained_local|Saving aggregated global adapter|store-fed-lora-round-1|canary_pass|PROMOTE)'
```

💡 **TIP:** Alternatively, suppress only HTTP polling lines using
`grep -vE 'HTTP Request:'`.

**Expected / Live Output:**

```text
INFO :      use_pretrained_local=True (Round 1 init): loading verified local adapter from /mnt/models/store1-local-adapter/adapter_model.safetensors without retraining noise.
INFO :      Saving aggregated global adapter to /mnt/models/store-fed-lora-candidate (aggregation_mode='subspace_resid', lora_alpha=64)
INFO :      Loaded candidate adapter 'store-fed-lora-candidate' into vLLM for pre-swap canary gate.
INFO :      Stage 5 Silo-Isolated Canary Gate PASSED (canary_pass=1, score=14/14 [100.00%], C1/C2/C3/C4/C5=100%, C6=0% fabrication, faithfulness=5.00/5.0, verdict=PROMOTE); promoted to store-fed-lora-round-1.
```

### 6.4. Manual Step 3: Verify Global Checkpoint & Canary Verdict in GCS

```bash
gcloud storage ls "gs://YOUR_GCS_BUCKET/checkpoints/"
```

**Expected Output:**

```text
gs://YOUR_GCS_BUCKET/checkpoints/candidate/
gs://YOUR_GCS_BUCKET/checkpoints/promoted/
gs://YOUR_GCS_BUCKET/checkpoints/round-1/
```

### 6.5. Manual Step 4: Verify Automated Global Adapter Hot-Swap & Active Models

📌 **NOTE:** Global adapter hot-swap is **100% automated** inside Flower
`ClientApp` (`evaluate()` method). Edge `flwr-trainer` pods receive the
aggregated parameters, evaluate `store-fed-lora-candidate` against the 14-probe
canary gate, promote it to `store-fed-lora-round-1` on `/mnt/models/`, and
automatically invoke
`POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/load_lora_adapter`
directly. **Zero manual operator intervention is required.**

Verify that `store-fed-lora-round-1` is already dynamically registered and
serving alongside local adapters:

#### Method A: Operator Workstation (Port-Forwarded)

```bash
curl -s http://127.0.0.1:18081/v1/models | jq -r '.data[].id'
curl -s http://127.0.0.1:18082/v1/models | jq -r '.data[].id'
```

#### Method B: In-Cluster Exec (Zero-Port-Forward via `flwr-trainer`)

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq -r '.data[].id'

kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq -r '.data[].id'
```

**Expected Output:**

```text
google/gemma-4-E2B-it
store1-local-adapter
store-fed-lora-round-1
---
google/gemma-4-E2B-it
store2-local-adapter
store-fed-lora-round-1
```

---

## 7. Stage 5: Post-Federation Collaborative QA Verification

**Goal:** Prove bidirectional knowledge transfer. Both Store 1 and Store 2 can
answer both Fact A and Fact B accurately while retaining 100% of their local
knowledge, achieving cross-silo intelligence without centralized data pooling.

### 7.1. Turnkey Script Execution

```bash
./scripts/run_full_5stage_demo.sh --stage=5
# OR
./scripts/verify_stage5_federated_qa.sh
```

### 7.2. Manual Query 1: Store 1 on Fact A (Return Policy - Retained Knowledge)

```bash
curl -s -X POST http://127.0.0.1:18081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store-fed-lora-round-1",
    "messages": [
      {"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
The official Supermarket store return policy duration is strictly 45 days with a digital POS receipt.
```

_(Assert: Store 1 RETAINED ✅)_

### 7.3. Manual Query 2: Store 1 on Fact B (VIP Promo Code - Transferred Knowledge from Store 2!)

```bash
curl -s -X POST http://127.0.0.1:18081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store-fed-lora-round-1",
    "messages": [
      {"role": "user", "content": "What is the secret Supermarket VIP Gold promo code for a 25% discount?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
The Supermarket VIP Gold member promo code is STORE-VIP-99 for a 25% discount.
```

_(Assert: Store 1 TRANSFERRED ✅ - acquired Store 2's private fact without
seeing its data!)_

### 7.4. Manual Query 3: Store 2 on Fact B (VIP Promo Code - Retained Knowledge)

```bash
curl -s -X POST http://127.0.0.1:18082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store-fed-lora-round-1",
    "messages": [
      {"role": "user", "content": "What is the secret Supermarket VIP Gold promo code for a 25% discount?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
The Supermarket VIP Gold member promo code is STORE-VIP-99 for a 25% discount.
```

_(Assert: Store 2 RETAINED ✅)_

### 7.5. Manual Query 4: Store 2 on Fact A (Return Policy - Transferred Knowledge from Store 1!)

```bash
curl -s -X POST http://127.0.0.1:18082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store-fed-lora-round-1",
    "messages": [
      {"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}
    ],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

**Expected / Live Output:**

```text
The official Supermarket store return policy duration is strictly 45 days with a digital POS receipt.
```

_(Assert: Store 2 TRANSFERRED ✅ - acquired Store 1's private fact without
seeing its data!)_

**Resulting Stage 5 Verification Table:**

```text
==========================================================================================
          STAGE 5 POST-FEDERATION COLLABORATIVE LEARNING VERIFICATION TABLE
==========================================================================================
Cluster   | Active Global Adapter   | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+-------------------------+----------------------------+--------------------------
Store 1   | store-fed-lora-round-1  | RETAINED   [PASS ✅]       | TRANSFERRED [PASS ✅]
Store 2   | store-fed-lora-round-1  | TRANSFERRED [PASS ✅]      | RETAINED    [PASS ✅]
==========================================================================================
```

---

## 8. Clean Baseline Reset (Back to Pre-Stage 1)

**Goal:** Non-destructively reset the demo environment back to the clean Stage 1
Baseline state in under 20 seconds without destroying PVCs or re-downloading
base Gemma 4 weights (~4.5 GB).

### 8.1. Turnkey Script Execution

```bash
./scripts/reset_demo_to_stage1.sh
```

**Expected Output:**

```text
==============================================================================
 EDGE-TO-CLOUD FEDERATED LEARNING (Fed-LoRA) PoC — CLEAN BASELINE RESET
==============================================================================
[INFO] Initiating non-destructive reset back to Stage 1 Baseline state...
[INFO] [Step 1/5] Unloading dynamic LoRA adapters from vLLM memory...
[PASS] In-Cluster exec: Unloaded 'store1-local-adapter' from 10.200.0.131:8000.
[PASS] In-Cluster exec: Unloaded 'store-fed-lora-round-1' from 10.200.0.131:8000.
[PASS] In-Cluster exec: Unloaded 'store2-local-adapter' from 10.200.0.163:8000.
[PASS] In-Cluster exec: Unloaded 'store-fed-lora-round-1' from 10.200.0.163:8000.
[INFO] [Step 2/5] Purging fine-tuned adapter artifacts from /mnt/models on edge nodes...
[PASS] Purged all fine-tuned LoRA adapter directories (base Gemma 4 weights preserved).
[INFO] [Step 3/5] Cleaning GCS federated round checkpoints...
[PASS] Cleaned gs://YOUR_GCS_BUCKET/checkpoints/round-1/ (preserved directory prefix).
[INFO] [Step 4/5] Resetting Flower aggregator on Central GKE...
deployment.apps/flwr-superlink restarted
Waiting for deployment "flwr-superlink" rollout to finish: 1 old replicas are pending termination...
deployment "flwr-superlink" successfully rolled out
[PASS] Central Flower aggregator restarted and ready for fresh federation rounds.
[INFO] [Step 5/5] Verifying clean base serving state...
==============================================================================
 CLEAN BASELINE RESET COMPLETE: Lab is Ready for Stage 1 Presentation
==============================================================================
```

### 8.2. Manual Step 1: Unload LoRA Adapters from vLLM Serving Memory

Unload all fine-tuned and federated adapters via REST calls:

#### Method A: Operator Workstation (Port-Forwarded)

```bash
# Store 1: Unload local and global adapters
curl -s -X POST http://127.0.0.1:18081/v1/unload_lora_adapter \
  -H "Content-Type: application/json" -d '{"lora_name": "store1-local-adapter"}'

curl -s -X POST http://127.0.0.1:18081/v1/unload_lora_adapter \
  -H "Content-Type: application/json" -d '{"lora_name": "store-fed-lora-round-1"}'

# Store 2: Unload local and global adapters
curl -s -X POST http://127.0.0.1:18082/v1/unload_lora_adapter \
  -H "Content-Type: application/json" -d '{"lora_name": "store2-local-adapter"}'

curl -s -X POST http://127.0.0.1:18082/v1/unload_lora_adapter \
  -H "Content-Type: application/json" -d '{"lora_name": "store-fed-lora-round-1"}'
```

#### Method B: In-Cluster Exec (Zero-Port-Forward)

```bash
# Store 1:
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s -X POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/unload_lora_adapter \
  -H "Content-Type: application/json" -d '{"lora_name": "store1-local-adapter"}'

kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s -X POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/unload_lora_adapter \
  -H "Content-Type: application/json" -d '{"lora_name": "store-fed-lora-round-1"}'

# Store 2:
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s -X POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/unload_lora_adapter \
  -H "Content-Type: application/json" -d '{"lora_name": "store2-local-adapter"}'

kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s -X POST http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/unload_lora_adapter \
  -H "Content-Type: application/json" -d '{"lora_name": "store-fed-lora-round-1"}'
```

### 8.3. Manual Step 2: Purge Fine-Tuned Adapter Directories on Edge Nodes

Remove adapter directories from shared host storage `/mnt/models` (base Gemma 4
weights remain intact):

```bash
# Store 1 edge node:
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  rm -rf /mnt/models/store1-local-adapter /mnt/models/store-fed-lora-round-1

# Store 2 edge node:
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  rm -rf /mnt/models/store2-local-adapter /mnt/models/store-fed-lora-round-1
```

### 8.4. Manual Step 3: Purge GCS Federated Round Checkpoints

```bash
gcloud storage rm --recursive "gs://${GCS_BUCKET_NAME}/checkpoints/round-1/**" 2>/dev/null || true
echo "" | gcloud storage cp - "gs://${GCS_BUCKET_NAME}/checkpoints/round-1/.keep"
```

### 8.5. Manual Step 4: Restart Central GKE Flower SuperLink Aggregator

Restart the central Flower aggregator to flush completed runs and accept fresh
federation sessions:

```bash
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout restart deployment/flwr-superlink
kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator rollout status deployment/flwr-superlink --timeout=120s
```

**Expected Output:**

```text
deployment.apps/flwr-superlink restarted
Waiting for deployment "flwr-superlink" rollout to finish: 1 old replicas are pending termination...
deployment "flwr-superlink" successfully rolled out
```

### 8.6. Manual Step 5: Verify Clean Model Inventory in vLLM

Verify that only the base model `google/gemma-4-E2B-it` is returned (all dynamic
LoRA adapters unloaded):

#### Method A: Operator Workstation (Port-Forwarded)

```bash
curl -s http://127.0.0.1:18081/v1/models | jq -r '.data[].id'
curl -s http://127.0.0.1:18082/v1/models | jq -r '.data[].id'
```

#### Method B: In-Cluster Exec (Zero-Port-Forward)

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq -r '.data[].id'

kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc exec deployment/flwr-trainer -- \
  curl -s http://vllm-service.fed-lora-poc.svc.cluster.local:8000/v1/models | jq -r '.data[].id'
```

**Expected / Live Output:**

```text
google/gemma-4-E2B-it
---
google/gemma-4-E2B-it
```

_(Assert: Only the base foundation model is present; zero custom LoRA adapters
loaded.)_

### 8.7. Manual Step 6: Re-Execute Baseline Verification

```bash
./scripts/verify_stage1_baseline.sh
```

**Expected Output:**

```text
==============================================================================
 EDGE-TO-CLOUD FEDERATED LEARNING (Fed-LoRA) PoC — STAGE 1 BASELINE AUDIT
==============================================================================
[PASS] Config Sync RootSync status verified synced across both edge clusters.
[PASS] Store 1: MetalLB VIP 10.200.0.131:8000 assigned.
[PASS] Store 2: MetalLB VIP 10.200.0.163:8000 assigned.
[PASS] Store 1: Discovered model 'google/gemma-4-E2B-it' (0 custom adapters).
[PASS] Store 2: Discovered model 'google/gemma-4-E2B-it' (0 custom adapters).
[PASS] Store 1: Base model ignorant of Fact A (Return Policy).
[PASS] Store 1: Base model ignorant of Fact B (VIP Code).
[PASS] Store 2: Base model ignorant of Fact A (Return Policy).
[PASS] Store 2: Base model ignorant of Fact B (VIP Code).
==============================================================================
STAGE 1 AUDIT RESULT: PASSED (Clean Baseline Verified Ready for Demo)
==============================================================================
```

### 8.8. Manual Step 7: How to Kill All Port-Forward Loops & Processes Cleanly

Because `(until kubectl ...; do sleep 1; done &)` runs in a subshell whose `CMD`
appears in `ps` as `/bin/bash -l`, use this one-liner (also documented in
Section 2.1) to kill both parent subshell loops (`PPID`) and child `kubectl`
processes simultaneously:

```bash
# Terminate all parent auto-reconnect subshell loops AND child kubectl processes:
for pid in $(pgrep -f "kubectl.*port-forward"); do
  kill -9 $(ps -o ppid= -p "$pid") "$pid" 2>/dev/null || true
done

# Verify ports 8001, 8002, and 9093 are free:
lsof -i:8001 -i:8002 -i:9093 || echo "CLEAN: All port-forward listeners terminated."
```

---

## 9. Troubleshooting: Port Conflicts & Stale Background Listeners

When running manual verification from an operator workstation, multiple
`kubectl port-forward` background processes may conflict if run repeatedly:
`Unable to listen on port <PORT>: ... bind: address already in use`

### 9.1. Option A: Inspect Active Listeners

```bash
# Check if ports 9093, 8001, or 8002 are in use:
lsof -i:9093 -i:8001 -i:8002
```

### 9.2. Option B: Terminate Stale Listeners & Auto-Reconnect Loops

```bash
# Terminate all parent auto-reconnect subshell loops AND child kubectl processes:
for pid in $(pgrep -f "kubectl.*port-forward"); do
  kill -9 $(ps -o ppid= -p "$pid") "$pid" 2>/dev/null || true
done

# Verify ports 8001, 8002, and 9093 are free:
lsof -i:8001 -i:8002 -i:9093 || echo "CLEAN: All port-forward listeners terminated."
```

### 9.3. Option C: Idempotent Execution

Always guard `kubectl port-forward` commands with `lsof`:

```bash
lsof -i:8001 >/dev/null 2>&1 || kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 8001:8000 &
lsof -i:8002 >/dev/null 2>&1 || kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc port-forward svc/vllm-service 8002:8000 &
lsof -i:9093 >/dev/null 2>&1 || kubectl --context="${GKE_CONTEXT}" -n fed-lora-aggregator port-forward svc/flwr-superlink-service 9093:9093 &
```

---

## 10. Hallucination Control & Decentralized Zero-VRAM Edge Judge

💡 **TIP — Presenter Talking Point (Why Store 1 Never Trains on or Evaluates
Store 2's Secret Data):**

1.  **Zero Cross-Silo Curriculum Leakage via KL-Divergence Anchoring
    (`with model.disable_adapter():`):** Each store's `50`-example training
    dataset (`39` positive + `7` OOD + `4` replay in
    `overlays/store-1/data/train.jsonl` and `overlays/store-2/data/train.jsonl`)
    has **0%** mention of the sibling store's policy (`STORE-VIP-99` or
    `45 days`). Instead of training Store 1 on VIP refusals (which violates silo
    independence and creates opposing gradients during Stage 4 merging), each
    store pairs `7` genuinely disjoint generic OOD abstentions
    (`garage parking validation`, `event catering deposits`,
    `in-store pet policy`, `floral wedding delivery`,
    `bottle & battery recycling`, `lost-and-found holding duration`,
    `rain-check voucher duration`) + `4` general-capability replay examples with
    a zero-VRAM KL tether to the frozen 4-bit base model and Sign-Elected
    Max-Magnitude TIES merging.
2.  **Decentralized Federated Evaluation (`ClientApp.evaluate` +
    `SuperLink.aggregate_evaluate`):** During Federated Evaluation, Store 1
    evaluates strictly `C1 + C4 + C5` (`--store-scope store1`) and Store 2
    evaluates strictly `C2 + C6 + C4 + C5` (`--store-scope store2`) against the
    shared global adapter (`store-fed-lora-round-1`). `SuperLink` aggregates
    both stores' pass verdicts (`all_passed == True`) to prove global
    bidirectional retention without sharing private rubrics across stores.

```bash
# 1. Stage 3 Siloed Local SFT Hallucination Control & Canary Gate (C1-C6):
./scripts/verify_stage3_hallucination_control.sh

# 2. Stage 5 Federated TIES Global Adapter Hallucination Control & Canary Gate (C1-C6):
./scripts/verify_stage5_hallucination_control.sh

# 3. Direct Two-Pass Zero-VRAM Edge Judge invocation (Store-Siloed or External Demo Scope):
python3 ./scripts/eval_local_gemma_judge.py \
  --vllm-url "http://${STORE1_VLLM_LB_IP}:8000" \
  --adapter-name "store-fed-lora-round-1" \
  --base-model "google/gemma-4-E2B-it" \
  --store-id "1" \
  --stage "stage5" \
  --store-scope "store1"
```

---

## 11. 3-Pod Edge Architecture, Multi-Round Convergence (`num_rounds=3`), & Stage 6 `.fab` Showcase

### 11.1. Inspect 3-Pod Edge Split (`vllm-gemma4` + CPU `flwr-supernode` + GPU `flwr-trainer`)

```bash
kubectl --context="${STORE1_CONTEXT}" -n fed-lora-poc get pods -o wide
kubectl --context="${STORE2_CONTEXT}" -n fed-lora-poc get pods -o wide
```

### 11.2. Execute Multi-Round (`num-server-rounds=3`) FedProx + Temperature-Scaled KL Run

```bash
./scripts/run_multiround_fl_demo.sh --rounds 3
```

### 11.3. Execute Stage 6 Dynamic `.fab` Code & Hyperparameter Delivery Showcase (Verified FAB Provenance: Local `flwr build` `H_build` == SuperLink `fab-hash`)

Both `run_multiround_fl_demo.sh` and `run_stage6_fab_showcase.sh` verify FAB
provenance rather than relying on self-reported strings:

1.  Run `flwr build` in `apps/fed-lora` immediately before `flwr run` to compute
    the local SHA-256 hash (`H_build`), verify that the `.fab` filename's
    8-character prefix matches `H_build[:8]`, and delete the temporary `.fab`
    file.
2.  Submit `flwr run . gke-superlink --stream`, capture the Flower `run-id`, and
    record `flwr_run_id = context.run_id` inside every round's `metadata.json`.
3.  Query `flwr ls gke-superlink --run-id <flwr_run_id> --format json` after the
    run to retrieve the SuperLink-recorded `fab-hash`, assert
    `H_build == fab-hash`, and write the provenance manifest
    (`phase3_run2_provenance.json`).

```bash
./scripts/run_stage6_fab_showcase.sh
```

---

## 12. 4-Quadrant Google Cloud Monitoring Live Demo Dashboard (`v2.1.13`)

- **Console URL (`YOUR_PROJECT_ID`):**
  `https://console.cloud.google.com/monitoring/dashboards/custom/YOUR_DASHBOARD_ID?project=YOUR_PROJECT_ID`
- **Idempotent Deployment / Update CLI:**

  ```bash
  ./scripts/deploy_demo_dashboard.sh
  ```

- **Stage 1 Reset Hook (Zeroes `:9100/metrics` to Clean Baseline):**

  ```bash
  ./scripts/reset_demo_to_stage1.sh
  ```
