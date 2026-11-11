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

# Demo Runbook & Script: Edge-to-Cloud Federated Learning (Fed-LoRA)

For the target architecture and solution tenets, see
[Solution Architecture & Business Overview](../README.md#1-solution-architecture--business-overview).

## 1. Stage-by-Stage Demo Walkthrough

📌 **NOTE on Reference Execution Output & Manual CLI Cheat Sheet:** An example
of the full 5-stage demo script output is provided in the
[Master Demo Transcript](demo_runner_transcript.md). For the complete,
standalone manual CLI cheat sheet with every copy-paste command and live
response across Stages 1–5 and baseline reset, see the
[Demo Script CLI Cheat Sheet](demo_script_cheat_sheet.md).

### Stage 1: Base Foundation Model Baseline Verification

Before we begin training, we must establish a rigorous, honest baseline. We are
running Google's Gemma 4 (E2B-it) foundation model inside vLLM on our GDC edge
nodes. Does this un-tuned foundation model already know the Supermarket's
private return policy or secret VIP discount code? Let's find out.

#### Runner Command

```bash
./scripts/run_full_5stage_demo.sh --stage=1
```

#### Manual Interactive Proof (`cURL`)

```bash
# Query Store 1 for Return Policy (Fact A)
curl -s -X POST http://10.200.0.131:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "google/gemma-4-E2B-it",
    "messages": [{"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

_Expected Output:_ Generic, ungrounded response (e.g. _"Typically stores allow
30 days..."_) without mentioning the specific 45-day digital POS receipt rule.

#### Resulting Baseline Ignorance Table

```text
==========================================================================================
            STAGE 1 BASE MODEL BASELINE IGNORANCE VERIFICATION TABLE
==========================================================================================
Cluster   | Active Model           | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+------------------------+----------------------------+--------------------------
Store 1   | google/gemma-4-E2B-it  | ABSTAINED [PASS ✅]        | ABSTAINED [PASS ✅]
Store 2   | google/gemma-4-E2B-it  | ABSTAINED [PASS ✅]        | ABSTAINED [PASS ✅]
==========================================================================================
```

---

### Stage 2: Siloed Local QLoRA Fine-Tuning Execution

Now we train. Notice three critical production innovations here:

1.  **3-Pod Edge Architecture (`flwr-supernode` CPU + `flwr-trainer` GPU
    `SuperExec` + `vllm-gemma4`) & vLLM Level-1 Sleep Mode:** NVIDIA GPU
    Time-Slicing partitions our physical GPU into two virtual slices (`Slice #1`
    for `vllm-gemma4` and `Slice #2` for `flwr-trainer`, while `flwr-supernode`
    runs on `0` GPUs as a lightweight CPU gRPC daemon). During daytime store
    hours, vLLM uses `--gpu-memory-utilization 0.85` for maximum concurrent
    KV-cache serving throughput. When a training round begins, `flwr-trainer`
    calls vLLM's **`POST /sleep?level=1`** endpoint to offload model weights to
    pinned host RAM and release GPU VRAM in `< 1s`, executes 4-bit QLoRA
    training with zero OOM contention, and immediately wakes vLLM via
    **`POST /wake_up`** in `0.8s`.
2.  **Hardware Portability via 4-bit NF4 QLoRA (Fitting `RTX 4500 Ada 24 GB`,
    `RTX A4500 20 GB`, `L4 24 GB`, and `RTX PRO 6000`):** Because base Gemma 4
    is quantized to `4-bit NF4` (`~6.0 GiB` total training footprint) instead of
    `bfloat16`, this exact co-located vLLM + Flower stack runs unmodified on
    **target retail store GPUs (`NVIDIA RTX 4500 Ada Generation 24 GB GDDR6` and
    `RTX A4500 20 GB GDDR6`)** as well as **`NVIDIA L4` (`24 GB`)** and
    **`RTX PRO 6000` (`48 GB` / `96 GB`)**.
3.  **Frozen-Feature Adaptation LoRA (FFA-LoRA) & Outbound-Only Dispatch:**
    Matrix $A$ is initialized deterministically (`seed 42`) and frozen so only
    matrix $B$ (`120` tensors, `r=16, alpha=64`) is trained, ensuring subspace
    alignment. Training is initiated centrally via
    `flwr run apps/fed-lora gke-superlink --run-config mode="local-sft"` over
    the SuperNode's outbound long-polling channel—with zero inbound edge ports
    and zero `kubectl exec` triggers.

#### Runner Command

```bash
./scripts/run_full_5stage_demo.sh --stage=2
```

#### Under-the-Hood Execution

- Central runner invokes
  `flwr run apps/fed-lora gke-superlink --run-config mode="local-sft"`.
- SuperLink dispatches the run via `serverapp.py` configured with
  `NoOpAggregationStrategy` (zero parameter leakage to central cloud).
- Store 1 `flwr-trainer` reads its local dataset directly from the store node's
  PVC at `/mnt/models/edge-data/store-1/train.jsonl`
  (`overlays/store-1/data/train.jsonl`, `20` active curated examples from `50`
  seeded examples), places vLLM in Level-1 Sleep Mode (`POST /sleep?level=1`),
  trains `store1-local-adapter` (`||B_1||_F = 11.06`), wakes vLLM
  (`POST /wake_up`), and dynamically hot-swaps `store1-local-adapter` into local
  vLLM.
- Store 2 `flwr-trainer` reads its local dataset directly from the store node's
  PVC at `/mnt/models/edge-data/store-2/train.jsonl`
  (`overlays/store-2/data/train.jsonl`, `20` active curated examples from `50`
  seeded examples), trains `store2-local-adapter` (`||B_2||_F = 11.15`), wakes
  vLLM, and hot-swaps `store2-local-adapter` into local vLLM.
- Training data stays exclusively on the store node (`PVC` at
  `/mnt/models/edge-data/store-{1,2}/train.jsonl`), seeded declaratively in the
  lab (`ConfigMap/store-training-data` $\rightarrow$ `PVC`) and produced by the
  store's own local systems in production; the central GCS bucket holds model
  artifacts only.
- Both fine-tuning runs use `KLProxTrainer` (`r=16, alpha=64, kl_beta=0.15` via
  zero-VRAM `model.disable_adapter()`) to converge cleanly without memorization
  collapse and with **zero vLLM pod restarts**.

---

### Stage 3: Pre-Federation Siloed QA & Hallucination Control Verification

Training is complete. Notice that neither store restarted its container.
Instead, each local adapter (`store1-local-adapter` and `store2-local-adapter`)
was injected dynamically into vLLM via REST in under 100 milliseconds. Let's see
what each store knows right now—and verify via `verify_stage3_siloed_qa.sh` that
neither store hallucinates when asked about its sibling store's domain.

#### Runner Command

```bash
./scripts/run_full_5stage_demo.sh --stage=3
```

#### Manual Interactive Proof (`cURL`)

```bash
# Query Store 1 targeting local adapter
curl -s -X POST http://10.200.0.131:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store1-local-adapter",
    "messages": [{"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

_Expected Output:_ _"The official Supermarket store return policy duration is
strictly 45 days with a digital POS receipt."_

```bash
# Query Store 1 asking for Store 2's VIP code
curl -s -X POST http://10.200.0.131:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store1-local-adapter",
    "messages": [{"role": "user", "content": "What is the secret Supermarket VIP Gold promo code for a 25% discount?"}],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

_Expected Output:_ Politely abstains (_"I don't have information on that in my
store knowledge base"_); does **NOT** know `STORE-VIP-99` and does **NOT**
fabricate a fake code (`100%` Stage 3 Silo-Isolated Canary Gate).

#### Resulting Asymmetric Learning Table

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

### Stage 4: Federated Cross-Subspace Residual Projection (`subspace_resid`) & Two-Phase Canary Promotion

Now comes the collaborative federated step (`3 rounds`). The central runner
triggers the Flower App in federated mode
(`flwr run apps/fed-lora gke-superlink --run-config 'mode="federated" num-server-rounds=3'`).
Store 1 and Store 2 communicate with the Central GKE SuperLink over the internal
VPC load balancer on port 9092.

💡 **Customer Storytelling — Three Production Federated MLOps Safeguards in
Stage 4:**

1.  **`<1ms` Server-Side Parameter Initialization (`initial_parameters`):**
    Rather than picking a random retail store node to initialize the global
    model before Round 1 (which would block the federation for `~45s` while an
    edge GPU loads 4-bit Gemma 4 just to export zero tensors), `ServerApp` loads
    the canonical `round-0` seed (`240` keys: `120` frozen `lora_A` + `120` zero
    `lora_B`) directly from GCS (`adapters/gemma4-e2b/round-0/`) in
    **`< 1 millisecond`**, allowing Round 1 training to start instantaneously
    across all stores.
2.  **Energy-Balanced Cross-Subspace Residual Projection (`subspace_resid`,
    $\gamma = 0.85$):** Standard `0.5 / 0.5` FedAvg dilutes store-unique facts
    by half while doubling shared refusal priors
    ($\cos(B_1, B_2) \approx
    0.62$). `ServerApp` projects $B_1$ and $B_2$ via
    thin SVD into their shared refusal/formatting subspace $\hat{R}$ (kept at
    $1.0\times$ unit scale) and their orthogonal store-unique residuals
    $\hat{F}_1, \hat{F}_2$, applying inverse-energy balancing
    ($g_k = (0.5 + \gamma) \cdot
    \min(\bar{E}_{\text{orth}} / E_{\text{orth},k}, 1.40)$
    at $\gamma = 0.85$, yielding `gains=1.40x/1.30x` and
    `||B_merged||_F = 19.44`) so Store 1's `45-day` policy and Store 2's
    `STORE-VIP-99` promo code have equal logit authority.
3.  **Transactional Two-Phase Canary Quarantine (`candidate/` $\rightarrow$
    `14/14` Gate $\rightarrow$ `promoted/`):** Merged weights are never written
    directly to production. `ServerApp` first writes each round's merged
    checkpoint to an isolated quarantine prefix
    (`adapters/gemma4-e2b/candidate/round-{1,2,3}/`). Each store loads the
    candidate into a temporary vLLM slot (`store-fed-lora-candidate`) and runs
    the **14-probe Zero-VRAM Edge Canary Judge (`C1`–`C6`)**. Only when both
    stores return `14/14 [100.00%] -> PROMOTE` does `ServerApp` atomically copy
    the verified artifact to `adapters/gemma4-e2b/promoted/latest/` and promote
    `store-fed-lora-promoted` into live serving.

#### Runner Command

```bash
./scripts/run_full_5stage_demo.sh --stage=4
```

#### Under-the-Hood Execution (`Run 4` — `15989409084762325520`)

- Central runner invokes
  `flwr run apps/fed-lora gke-superlink --run-config 'mode="federated" num-server-rounds=3'`.
- `ServerApp` loads `initial_parameters` (`round-0`, `240` keys) in `< 1ms`.
- Across **Rounds 1, 2, and 3**, Store 1 and Store 2 `flwr-trainer` pods
  warm-start from their Stage 2 local adapters (Round 1 `ce_loss = 0.5137`) and
  refine against the global merged adapter in Rounds 2–3
  (`R2 loss = 4.0511 -> R3 loss = 4.0113` with `KLProxTrainer` anchoring).
- `ServerApp` merges `lora_B` tensors via `subspace_resid`
  (`gamma=0.85, gains=1.40x/1.30x, ||B_merged||_F=19.44`), quarantines each
  candidate in `adapters/gemma4-e2b/candidate/round-{1,2,3}/`, verifies
  **`14/14 [100.00%] -> PROMOTE`** on both stores in all 3 rounds, and promotes
  `store-fed-lora-promoted` into `promoted/latest/` and vLLM.

---

### Stage 5: Post-Federation Collaborative QA Verification

This is the grand finale. Both stores now serve the promoted global adapter
`store-fed-lora-promoted`. Store 1 has never seen Store 2's VIP discount data.
Store 2 has never seen Store 1's return policy data. Let's test both questions
on both stores.

#### Runner Command

```bash
./scripts/run_full_5stage_demo.sh --stage=5
```

#### Manual Interactive Proof (`cURL`)

```bash
# Query Store 1 for Store 2's VIP Promo Code (Transferred Knowledge)
curl -s -X POST http://10.200.0.131:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store-fed-lora-promoted",
    "messages": [{"role": "user", "content": "What is the Supermarket VIP Gold member promo code and discount percentage?"}],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

_Expected Output:_ _"The Supermarket VIP Gold member promo code is STORE-VIP-99
for a 25% discount."_

```bash
# Query Store 2 for Store 1's Return Policy (Transferred Knowledge)
curl -s -X POST http://10.200.0.163:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "store-fed-lora-promoted",
    "messages": [{"role": "user", "content": "What is the official Supermarket store return policy duration and receipt requirement?"}],
    "temperature": 0.0,
    "max_tokens": 128
  }' | jq -r '.choices[0].message.content'
```

_Expected Output:_ _"The official Supermarket store return policy duration is
strictly 45 days with a digital POS receipt."_

#### Resulting Collaborative Learning Table

```text
==========================================================================================
          STAGE 5 POST-FEDERATION COLLABORATIVE LEARNING VERIFICATION TABLE
==========================================================================================
Cluster   | Active Global Adapter    | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+--------------------------+----------------------------+--------------------------
Store 1   | store-fed-lora-promoted  | RETAINED    [PASS ✅]      | TRANSFERRED [PASS ✅]
Store 2   | store-fed-lora-promoted  | TRANSFERRED [PASS ✅]      | RETAINED    [PASS ✅]
==========================================================================================
```

Both stores achieved **`14/14 [100.00%] -> PROMOTE`** on the locked canary gate
and **`4/4` (`100%`)** on cross-store QA without streaming a single byte of
private customer data to the central cloud.

---

### Stage 6 (and Stage 0): Two-Track Artifact Delivery Showcase (OCI `FleetPackage` vs. Flower `.fab` Bundle)

To demonstrate how ML engineers iterate on Python training/merging logic
(`serverapp.py`, `clientapp.py`, `canary_suite.json`) without rebuilding or
re-pushing `~15 GB` CUDA container images across thousands of retail stores, run
the Stage 6 `.fab` showcase (also executed automatically as **Stage 0** in
`./scripts/demo_runner.sh`):

```bash
./scripts/build_and_stage_fab.sh
./scripts/run_stage6_fab_showcase.sh
```

- **Track 1 — Infrastructure GitOps (`FleetPackage` OCI `ResourceBundle`,
  `v1.0.0`):** Delivers static Kubernetes application manifests and the
  pre-baked PyTorch/CUDA runtime image (`~15 GB`) via Google Cloud Config
  Delivery (with NVIDIA GPU time-slicing applied once in Phase A via
  `prerequisites/gpu-time-slicing/`).
- **Track 2 — Application MLOps (`Flower .fab Bundle`, `~14 KB`):** Packages
  `apps/fed-lora` (`pyproject.toml`, `serverapp.py`, `clientapp.py`,
  `canary_suite.json`) into a deterministic `~14 KB` `.fab` archive
  (`1,070,000x` smaller than the container image), verified via SHA-256 prefix
  parity (`H_build[:8] == prefix`) and streamed over gRPC to edge `SuperNodes`
  in `< 2 seconds`.

---

## 2. Resetting the Lab Between Demo Sessions

To immediately repeat the demonstration for another audience without redeploying
clusters or re-downloading base model weights:

```bash
./scripts/reset_demo_to_stage1.sh
```

### What the Reset Script Does:

1.  Ensures vLLM is awake (`POST /wake_up`) on Store 1 and Store 2
    (`flwr-trainer` in-cluster exec fallback if workstation port-forwards are
    closed).
2.  Calls `POST /v1/unload_lora_adapter` for all fine-tuned adapters
    (`store1-local-adapter`, `store2-local-adapter`, `store-fed-lora-candidate`,
    `store-fed-lora-promoted`, `store-fed-lora-round-1`) on Store 1 and Store 2.
3.  Purges `/mnt/models/store*` and `/mnt/models/store-fed-lora*` from edge PVC
    storage via `deployment/flwr-trainer` (preserving base Gemma 4 and
    `/mnt/models/edge-data/`).
4.  Cleans GCS federated round candidate/promoted checkpoints while preserving
    the immutable `adapters/gemma4-e2b/round-0/` seed.
5.  Re-executes `verify_stage1_baseline.sh` to confirm both stores are returned
    to the clean Stage 1 baseline (`ABSTAINED [PASS ✅]`) in under 20 seconds.

---

## 3. Technical Frequently Asked Questions (Demo FAQ)

### Q1: Why not just pool the data in BigQuery or Vertex AI?

**A:** In regulated industries (healthcare, defense, finance, luxury retail),
compliance mandates (GDPR, HIPAA, PCI-DSS) strictly forbid cross-border or
off-premises data egress. Federated learning allows models to learn _at the data
source_.

### Q2: How do the 3-Pod Edge Split, vLLM Level-1 Sleep Mode, and 4-bit QLoRA prevent GPU OOMs across target retail GPUs (`RTX 4500 Ada 24 GB`, `RTX A4500 20 GB`, `L4 24 GB`, and `RTX PRO 6000`)?

**A:** We combine three hardware-efficiency layers so inference and local QLoRA
fine-tuning co-exist on a single retail GPU card:

1.  **3-Pod Edge Split (`flwr-supernode` CPU vs. `flwr-trainer` GPU
    `SuperExec`):** The Flower `SuperNode` daemon (`flwr-supernode`) runs on CPU
    (`0` GPUs) to maintain the persistent gRPC connection, while only
    `vllm-gemma4` (`Slice #1`) and `flwr-trainer` (`Slice #2`) bind to the GPU.
2.  **vLLM Level-1 Sleep Mode (`--gpu-memory-utilization 0.85` +
    `POST /sleep?level=1`):** Rather than permanently starving vLLM of KV-cache
    memory during daytime store hours, vLLM serves customer traffic at `85%` GPU
    utilization. When a federated round starts, `flwr-trainer` triggers
    `POST /sleep?level=1` (`VLLM_SERVER_DEV_MODE=1`), offloading vLLM weights to
    pinned host RAM and freeing `~90%` of GPU VRAM in `< 1s`. Once the `~40s`
    QLoRA step finishes, `POST /wake_up` restores vLLM weights in `0.8s` with
    zero pod restarts.
3.  **4-bit NF4 QLoRA vs. `bfloat16` LoRA:** Full `bfloat16` LoRA requires
    `~18.5 GiB` of VRAM during backpropagation, which would OOM when co-located
    on 20–24 GB edge cards. Quantizing frozen base Gemma 4 (`E2B-it`) to
    `4-bit NF4` (`bitsandbytes`) compresses the training footprint to
    **`~6.0 GiB`**, enabling this exact architecture to run on **target retail
    store hardware (`NVIDIA RTX 4500 Ada Generation` `24 GB GDDR6` and
    `RTX A4500` `20 GB GDDR6`)**, **`NVIDIA L4` (`24 GB`)**, and
    **`RTX PRO 6000` (`48 GB` / `96 GB`)**.

### Q3: Why FFA-LoRA instead of standard LoRA?

**A:** In federated learning with disjoint tasks, averaging both $A$ and $B$
matrices ($W = A \cdot B$) produces cross-term interference ($A_1 B_2 + A_2
B_1$)
that attenuates signal strength. By freezing $A$ across all edge clients
($A_1 = A_2 = A$, initialized from the `<1ms` server-side `round-0` seed),
weight delta aggregation operates purely on the `120` `lora_B` matrices,
eliminating cross-term signal cancellation.

### Q4: How fast is adapter hot-swapping?

**A:** Because base Gemma 4 weights remain resident in vLLM (woken in `0.8s` via
`POST /wake_up`), only the LoRA adapter safetensors (~7 MB) are loaded into GPU
memory. The vLLM `/v1/load_lora_adapter` call completes in less than **100
milliseconds**.

### Q5: Why eliminate `kubectl exec` into edge clusters?

**A:** In enterprise retail edge architectures, physical store clusters sit
behind strict egress-only corporate firewalls. Permitting inbound `kubectl exec`
access requires exposing cluster API servers or running high-privilege SSH/VPN
tunnels, violating zero-trust security postures and least-privilege RBAC
policies. The modern Flower Next-Gen architecture solves this with **SuperNode
outbound long-polling**: edge SuperNodes initiate outbound gRPC connections to
Central SuperLink on port `9092` (Fleet API), waiting for runs dispatched via
the central Exec API (`9093`). Zero inbound ports are required on edge stores,
and zero cluster-admin execution privileges are needed across cluster
boundaries.

### Q6: How do Energy-Balanced Cross-Subspace Residual Projection ($\gamma = 0.85$) and Two-Phase Canary Quarantine eliminate hallucinations?

**A:** Standard `0.5 / 0.5` FedAvg cuts disjoint store-specific features in half
while preserving shared refusal priors ($\cos(B_1, B_2) \approx 0.62$) at full
strength, causing false refusals on subtle paraphrases
(`C1_store1_return_paraphrase`). **Energy-Balanced Cross-Subspace Residual
Projection (`subspace_resid`)** uses thin SVD to isolate the shared
refusal/formatting subspace $\hat{R}$ at $1.0\times$ unit scale while boosting
the orthogonal store-specific residuals $\hat{F}_1, \hat{F}_2$ with
inverse-energy balancing
($g_k = (0.5 + \gamma) \cdot \min(\bar{E}_{\text{orth}}
/ E_{\text{orth},k}, 1.40)$
at $\gamma = 0.85$, yielding `gains=1.40x/1.30x` and `||B_merged||_F = 19.44`).
Every merged checkpoint is written to quarantine
(`adapters/gemma4-e2b/candidate/round-{r}/`) and audited by
`eval_local_gemma_judge.py` (`Pass-1` deterministic domain regex

- `Pass-2` Zero-VRAM Base-Model Judge) across all 14 canary probes (`C1`–`C6`)
  before atomic promotion to `promoted/latest/`.

### Q7: How does the 3-Round Warm-Start Federated Convergence (`Run 4` — `15989409084762325520`) perform across Rounds 1, 2, and 3?

**A:** In Stage 4 (`num-server-rounds=3`), Round 1 warm-starts from the Stage 2
local adapters (`||B_1||_F = 11.06`, `||B_2||_F = 11.15`), and Rounds 2 and 3
iteratively refine each store's local adapter starting from the previous round's
promoted global subspace merge (`KLProxTrainer` anchoring
`kl_beta=0.15, proximal_mu=0.05`). As verified in Golden `Run 4`
(`15989409084762325520`), both stores achieve **`14/14 [100.00%] -> PROMOTE`**
across all three rounds:

<!-- mdformat off -->

| Federated Round                   | Store 1 Train Loss (`20` samples) | Store 2 Train Loss (`20` samples) | Client Norms `\|\|B_1\|\|_F / \|\|B_2\|\|_F` | Subspace Merge (`gamma=0.85`, `gains`) | Merged Norm `\|\|B_merged\|\|_F` | Store 1 Canary Gate (`C1`–`C6`) | Store 2 Canary Gate (`C1`–`C6`) | Global Verdict   |
| :-------------------------------- | :-------------------------------- | :-------------------------------- | :------------------------------------------- | :------------------------------------- | :------------------------------- | :------------------------------ | :------------------------------ | :--------------- |
| **Round 1** _(Warm-Start)_        | `0.5137`                          | `0.5137`                          | `11.0639 / 11.1453`                          | `gains=1.40x/1.30x`                    | `19.4201`                        | **`14/14 [100.0%]`**            | **`14/14 [100.0%]`**            | **`PROMOTE ✅`** |
| **Round 2** _(Global Refinement)_ | `4.0511`                          | `4.0511`                          | `11.0785 / 11.1588`                          | `gains=1.40x/1.30x`                    | `19.4363`                        | **`14/14 [100.0%]`**            | **`14/14 [100.0%]`**            | **`PROMOTE ✅`** |
| **Round 3** _(Final Convergence)_ | `4.0113`                          | `4.0113`                          | `11.0846 / 11.1638`                          | `gains=1.40x/1.30x`                    | `19.4424`                        | **`14/14 [100.0%]`**            | **`14/14 [100.0%]`**            | **`PROMOTE ✅`** |

<!-- mdformat on -->

### Q8: How do we observe Single-GPU `0.85` (`~81.6 GiB`) Level-1 Sleep/Wake and Federated Convergence in Google Cloud Monitoring (`v2.1.13`)?

**A:** In `v2.1.13`, Config Sync (`FleetPackage`) declaratively reconciles
`kube-system/stackdriver` (`enableGMPForApplications: true`,
`enableCloudLoggingForApplications: true`) and 4 `PodMonitoring` CRDs across
both GDC Software-Only edge clusters (`YOUR_STORE_1_CLUSTER`,
`YOUR_STORE_2_CLUSTER`) and Central GKE (`YOUR_AGGREGATOR_CLUSTER`). On the
**4-Quadrant Cloud Monitoring Live Demo Dashboard**
(`https://console.cloud.google.com/monitoring/dashboards/custom/YOUR_DASHBOARD_ID?project=YOUR_PROJECT_ID`),
presenters can show:

1.  **Quadrant 1:** Daytime `vllm-gemma4` running at
    `--gpu-memory-utilization=0.85` (`~81.6 GiB` KV-cache) dropping via
    `POST /sleep?level=1` (`fed_lora_vllm_is_sleeping=1`) to free physical GPU
    VRAM for QLoRA (`fit()`), then waking (`POST /wake_up`) in `< 2s`.
2.  **Quadrant 2 & 3:** Continuous `fed_lora_round_loss`,
    `fed_lora_lora_b_frobenius_norm` (`scope="local_store"` vs
    `scope="global_merged"`), and `14/14` (`1.0`) Two-Phase Cross-Store Canary
    Consensus (`scope="fleet-consensus"`).
3.  **Quadrant 4 & Logs Panel:** Live `vllm:gpu_cache_usage_perc`, `< 50 KB`
    `.fab` / `~33 MB` LoRA payload bytes (`fed_lora_payload_bytes`), and GDC
    `fluent-bit` structured JSON logs (`SERVER_AGGREGATE_EVALUATE_DECISION`).
