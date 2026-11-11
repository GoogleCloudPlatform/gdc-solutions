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

# 5-Stage Demo Execution Transcript

## Stage 0: Flower .fab Bundle Packaging & Cryptographic Provenance

```text
[INFO 2026-09-22T16:35:34+0000] [Stage 0] Building Flower Application Bundle (.fab) from <REPO_ROOT>/apps/fed-lora...
==========================================================================================
        STAGE 0: FLOWER .fab BUNDLE PACKAGING & CRYPTOGRAPHIC PROVENANCE
==========================================================================================
  Bundle Artifact    : gdcso-dev.fed-lora.1-0-0.f4e22280.fab (prefix=f4e22280 == H_build[:8])
  .fab Bundle Size   : 198.78 KB (203553 bytes)
  H_build (SHA-256)  : f4e22280633d6fb3794ae51ad273c34c0c8fafe3909a58911faed7c6db04acd5
  GPU Container Size : ~15.00 GB (flwr-trainer:v2.1.12)
  WAN Payload Ratio  : 79124x smaller over-the-wire gRPC stream
  Docker Rebuilds    : 0 (Zero Edge K8s Pod Restarts)
==========================================================================================
[PASS 2026-09-22T16:35:37+0000] Stage 0 .fab provenance verified (H_build=f4e22280633d6fb3794ae51ad273c34c0c8fafe3909a58911faed7c6db04acd5).
```

---

## Stage 1: Base Model Baseline Verification

```text
            STAGE 1 BASE MODEL BASELINE IGNORANCE VERIFICATION TABLE
==========================================================================================
Cluster   | Active Model           | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+------------------------+----------------------------+--------------------------
Store 1   | google/gemma-4-E2B-it  | IGNORANT [PASS ✅]         | IGNORANT [PASS ✅]
Store 2   | google/gemma-4-E2B-it  | IGNORANT [PASS ✅]         | IGNORANT [PASS ✅]
==========================================================================================
==============================================================================
[INFO 2026-09-22T16:35:54+0000] Stage 1 Baseline Verification Summary: 10 PASSED, 0 FAILED
==============================================================================
```

---

## Stage 2: Siloed Local Fine-Tuning Execution

Stage 2 Local Fine-Tuning Results: • Control Plane: Flower SuperLink central run
dispatch ('apps/fed-lora', mode='local-sft'). • Store 1 (Fact A): Trained
'store1-local-adapter' (20 active curated examples, KLProxTrainer kl_beta=0.15,
||B_1||_F=11.06). • Store 2 (Fact B): Trained 'store2-local-adapter' (20 active
curated examples, KLProxTrainer kl_beta=0.15, ||B_2||_F=11.15). • GPU
Co-Location: vLLM Level-1 Sleep Mode (POST /sleep?level=1) + Wake (POST /wake_up
in 0.8s, 0 OOM restarts). • Security: Zero inbound ports opened; zero kubectl
exec commands issued to edge stores during training.

---

## Stage 3: Pre-Federation Siloed QA Verification

```text
        STAGE 3 PRE-FEDERATION ASYMMETRIC SILOED LEARNING VERIFICATION TABLE
==========================================================================================
Cluster   | Active LoRA Adapter   | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+-----------------------+----------------------------+--------------------------
Store 1   | store1-local-adapter  | KNOWN     [PASS ✅]        | ABSTAINED [PASS ✅]
Store 2   | store2-local-adapter  | ABSTAINED [PASS ✅]        | KNOWN     [PASS ✅]
==========================================================================================
[INFO 2026-09-22T16:37:15+0000] Stage 3 Siloed QA Verification Summary: 4 PASSED, 0 FAILED
```

---

## Stage 4: Federated Cross-Subspace Residual Projection Execution

Stage 4 Federated Cross-Subspace Residual Projection Results (Run 4:
15989409084762325520): • Control Plane: Flower SuperLink ExecAPI (:9093) +
FleetAPI (:9092) (10.200.0.50). • Server-Side Init: <1ms initial_parameters seed
loaded from gs://YOUR_GCS_BUCKET/adapters/gemma4-e2b/round-0/. • Aggregation
Algorithm: Energy-Balanced Cross-Subspace Residual Projection (subspace_resid,
gamma=0.85, gains=1.40x/1.30x, ||B_merged||_F=19.44). • SuperNodes Aggregated:
2/2 (Store 1 & Store 2 across 3 rounds: R1=0.5137 -> R2=4.0511 -> R3=4.0113,
14/14 [100.00%] PROMOTE). • Two-Phase Canary Quarantine: Staged in
gs://YOUR_GCS_BUCKET/adapters/gemma4-e2b/candidate/round-{1,2,3}/ -> Promoted to
promoted/latest/. • Edge Injection: 'store-fed-lora-promoted' atomically
promoted in vLLM on Store 1 and Store 2.

---

## Stage 5: Post-Federation Collaborative QA Verification

```text
==========================================================================================
           STAGE 5 POST-FEDERATION COLLABORATIVE LEARNING VERIFICATION TABLE
==========================================================================================
Cluster   | Active Global Adapter   | Fact A (45d Return Policy) | Fact B (STORE-VIP-99 VIP)
----------+-------------------------+----------------------------+--------------------------
Store 1   | store-fed-lora-round-1  | RETAINED   [PASS ✅]       | TRANSFERRED [PASS ✅]
Store 2   | store-fed-lora-round-1  | TRANSFERRED [PASS ✅]      | RETAINED    [PASS ✅]
==========================================================================================
Final Proof: Store 1 successfully acquired Fact B from Store 2, and Store 2 acquired Fact A
from Store 1 (4/4 Canonical QA = 100%), while passing the 14-Probe Tiered Hallucination
Control & Safety Gate (C1/C2/C3/C4/C5 = 100%, C6 = 0% Fabrication, Overall = 12/14 [85.71%])!
```

---

## Stage 6: Multi-Round FL Convergence & Dynamic .fab Showcase

Executed 3-Round Multi-Round FL Convergence (14/14 Canary Gate) and Dynamic .fab
Showcase (1.0.0 -> 1.1.0 -> 1.0.0, 0 pod restarts).

---
