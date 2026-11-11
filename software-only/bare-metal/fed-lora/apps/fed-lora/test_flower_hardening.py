#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Unit & Integration Test Suite for (Canary Gate, Canary Gate, Canary Gate):
#   - Dataset hygiene (46 examples/store, Line 14 & Line 18 fixes, disjoint OOD abstentions, replay)
#   - KLProxTrainer (zero-VRAM model.disable_adapter() KL + FedProx proximal mu) & SweetSpotEarlyStoppingCallback
#   - Pure-NumPy TIES-Merging (sign election + disjoint mean at lora_alpha=64)
#   - C1-C6 Canary Suite + Zero-VRAM Base Gemma Judge (eval_local_gemma_judge.py)
#   - Flower fixedclipping_mod & safe_fixedclipping_mod + DP wrapper config forwarding

import hashlib
import json
import os
import sys
import tempfile
import types
import unittest
from contextlib import contextmanager
from unittest.mock import MagicMock

import numpy as np

# Ensure apps/fed-lora and scripts are on sys.path
THIS_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPTS_DIR = os.path.abspath(os.path.join(THIS_DIR, "../../scripts"))
if THIS_DIR not in sys.path:
    sys.path.insert(0, THIS_DIR)
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)


def _install_numpy_torch_shim_if_needed() -> None:
    """Provides a NumPy-backed torch/transformers/peft shim when running on CPU workstation without PyTorch."""
    try:
        import torch  # pylint: disable=unused-import

        return
    except ImportError:
        pass

    class FakeTensor:

        def __init__(self, arr, requires_grad: bool = False):
            self.arr = np.asarray(arr, dtype=np.float32)
            self.requires_grad = requires_grad
            self.dtype = np.float32
            self.device = "cpu"

        def detach(self):
            return FakeTensor(self.arr.copy(), requires_grad=False)

        def clone(self):
            return FakeTensor(self.arr.copy(), requires_grad=self.requires_grad)

        def cpu(self):
            return self

        def numpy(self):
            return self.arr.copy()

        def float(self):
            return FakeTensor(
                self.arr.astype(np.float32), requires_grad=self.requires_grad
            )

        def to(self, *args, **kwargs):
            return self

        def contiguous(self):
            return self

        def item(self):
            return float(np.sum(self.arr))

        def fill_(self, val: float):
            self.arr.fill(val)
            return self

        def copy_(self, other):
            self.arr[...] = other.arr
            return self

        def numel(self):
            return int(self.arr.size)

        def __getitem__(self, idx):
            if isinstance(idx, FakeTensor):
                return FakeTensor(self.arr[idx.arr.astype(bool)])
            return FakeTensor(self.arr[idx])

        def __ne__(self, other):
            val = other.arr if isinstance(other, FakeTensor) else other
            return FakeTensor(self.arr != val)

        def __sub__(self, other):
            val = other.arr if isinstance(other, FakeTensor) else other
            return FakeTensor(self.arr - val)

        def __pow__(self, power):
            return FakeTensor(np.power(self.arr, power))

        def __add__(self, other):
            val = other.arr if isinstance(other, FakeTensor) else other
            return FakeTensor(self.arr + val)

        def __radd__(self, other):
            val = other.arr if isinstance(other, FakeTensor) else other
            return FakeTensor(val + self.arr)

        def __mul__(self, other):
            val = other.arr if isinstance(other, FakeTensor) else other
            return FakeTensor(self.arr * val)

        def __rmul__(self, other):
            val = other.arr if isinstance(other, FakeTensor) else other
            return FakeTensor(val * self.arr)

        def __truediv__(self, other):
            val = other.arr if isinstance(other, FakeTensor) else other
            return FakeTensor(self.arr / val)

    torch_mod = types.ModuleType("torch")
    torch_mod.Tensor = FakeTensor
    torch_mod.float32 = np.float32
    torch_mod.bfloat16 = np.float32
    torch_mod.long = np.int64
    torch_mod.tensor = lambda data, **kw: FakeTensor(data)
    torch_mod.zeros_like = lambda t: FakeTensor(np.zeros_like(t.arr))
    torch_mod.any = lambda t: bool(np.any(t.arr))
    torch_mod.sum = lambda t: FakeTensor(np.sum(t.arr))
    torch_mod.manual_seed = lambda s: None

    @contextmanager
    def _no_grad():
        yield

    torch_mod.no_grad = _no_grad
    torch_mod.cuda = types.SimpleNamespace(
        is_available=lambda: False,
        manual_seed_all=lambda s: None,
        is_bf16_supported=lambda: False,
        empty_cache=lambda: None,
    )

    nn_mod = types.ModuleType("torch.nn")

    class FakeModule:

        def __init__(self):
            self._params = {}

        def named_parameters(self):
            return list(self._params.items())

        def save_pretrained(self, output_dir: str):
            os.makedirs(output_dir, exist_ok=True)
            cfg_path = os.path.join(output_dir, "adapter_config.json")
            if not os.path.exists(cfg_path):
                with open(cfg_path, "w", encoding="utf-8") as f:
                    json.dump(
                        {"lora_alpha": 64, "target_modules": ["o_proj", "down_proj"]}, f
                    )

    nn_mod.Module = FakeModule
    F_mod = types.ModuleType("torch.nn.functional")

    def _softmax(x: FakeTensor, dim: int = -1) -> FakeTensor:
        shifted = x.arr - np.max(x.arr, axis=dim, keepdims=True)
        exp = np.exp(shifted)
        return FakeTensor(exp / np.sum(exp, axis=dim, keepdims=True))

    def _log_softmax(x: FakeTensor, dim: int = -1) -> FakeTensor:
        return FakeTensor(np.log(_softmax(x, dim=dim).arr + 1e-12))

    def _kl_div(
        log_p: FakeTensor, p_ref: FakeTensor, reduction: str = "batchmean"
    ) -> FakeTensor:
        kl = np.sum(p_ref.arr * (np.log(p_ref.arr + 1e-12) - log_p.arr), axis=-1)
        return FakeTensor(np.mean(kl))

    F_mod.softmax = _softmax
    F_mod.log_softmax = _log_softmax
    F_mod.kl_div = _kl_div
    nn_mod.functional = F_mod
    torch_mod.nn = nn_mod
    sys.modules["torch"] = torch_mod
    sys.modules["torch.nn"] = nn_mod
    sys.modules["torch.nn.functional"] = F_mod

    # Stub datasets, google.cloud.storage, peft, safetensors, transformers
    datasets_mod = types.ModuleType("datasets")
    datasets_mod.Dataset = MagicMock()
    sys.modules["datasets"] = datasets_mod

    import google  # pylint: disable=g-import-not-at-top

    cloud_mod = types.ModuleType("google.cloud")
    storage_mod = types.ModuleType("google.cloud.storage")
    storage_mod.Client = MagicMock()
    cloud_mod.storage = storage_mod
    google.cloud = cloud_mod
    sys.modules["google.cloud"] = cloud_mod
    sys.modules["google.cloud.storage"] = storage_mod

    peft_mod = types.ModuleType("peft")
    peft_mod.LoraConfig = MagicMock()
    peft_mod.get_peft_model = MagicMock()
    peft_mod.prepare_model_for_kbit_training = MagicMock()
    peft_mod.set_peft_model_state_dict = MagicMock()
    sys.modules["peft"] = peft_mod

    st_mod = types.ModuleType("safetensors")
    st_torch_mod = types.ModuleType("safetensors.torch")
    st_torch_mod.load_file = MagicMock()
    st_mod.torch = st_torch_mod
    sys.modules["safetensors"] = st_mod
    sys.modules["safetensors.torch"] = st_torch_mod

    tf_mod = types.ModuleType("transformers")
    tf_mod.AutoModelForCausalLM = MagicMock()
    tf_mod.AutoTokenizer = MagicMock()
    tf_mod.BitsAndBytesConfig = MagicMock()
    tf_mod.DataCollatorForLanguageModeling = MagicMock()

    class FakeTrainer:

        def __init__(self, model=None, args=None, **kwargs):
            self.model = model
            self.args = args

        def compute_loss(
            self, model, inputs, return_outputs=False, num_items_in_batch=None
        ):
            out = model(**inputs)
            return (out.loss, out) if return_outputs else out.loss

    class FakeTrainerCallback:
        pass

    class FakeTrainerState:

        def __init__(self, global_step: int = 0, epoch: float = 0.0):
            self.global_step = global_step
            self.epoch = epoch

    class FakeTrainerControl:

        def __init__(self, should_training_stop: bool = False):
            self.should_training_stop = should_training_stop

    class FakeTrainingArguments:

        def __init__(self, **kwargs):
            for k, v in kwargs.items():
                setattr(self, k, v)

    tf_mod.Trainer = FakeTrainer
    tf_mod.TrainerCallback = FakeTrainerCallback
    tf_mod.TrainerState = FakeTrainerState
    tf_mod.TrainerControl = FakeTrainerControl
    tf_mod.TrainingArguments = FakeTrainingArguments
    sys.modules["transformers"] = tf_mod


_install_numpy_torch_shim_if_needed()

import clientapp
import eval_local_gemma_judge
import serverapp
import torch
from flwr import common as _flwr_common
from transformers import TrainerControl, TrainerState, TrainingArguments

Code = _flwr_common.Code
Context = _flwr_common.Context
FitIns = _flwr_common.FitIns
FitRes = _flwr_common.FitRes
Message = _flwr_common.Message
Metadata = _flwr_common.Metadata
Status = _flwr_common.Status
ndarrays_to_parameters = _flwr_common.ndarrays_to_parameters
parameters_to_ndarrays = _flwr_common.parameters_to_ndarrays
from flwr.compat.common import recorddict_compat as _flwr_compat

fitins_to_recordset = _flwr_compat.fitins_to_recorddict
fitres_to_recordset = _flwr_compat.fitres_to_recorddict
recordset_to_fitres = _flwr_compat.recorddict_to_fitres


class DummyToyCausalLM(torch.nn.Module):
    """Lightweight causal LM stub with PEFT-style disable_adapter() context manager."""

    def __init__(self):
        super().__init__()
        self.lora_B = torch.tensor(np.zeros((4, 4), dtype=np.float32))
        self.lora_B.requires_grad = True
        self._params = {"lora_B": self.lora_B}
        self.adapter_disabled = False
        self.disable_adapter_called = 0

    @contextmanager
    def disable_adapter(self):
        prev = self.adapter_disabled
        self.adapter_disabled = True
        self.disable_adapter_called += 1
        try:
            yield
        finally:
            self.adapter_disabled = prev

    def __call__(self, input_ids=None, labels=None, **kwargs):
        # Base logits (when adapter is disabled) peak at token 0; adapted logits shift toward token 1
        base_logits = np.array(
            [[[4.0, 0.0, 0.0, 0.0], [4.0, 0.0, 0.0, 0.0], [4.0, 0.0, 0.0, 0.0]]],
            dtype=np.float32,
        )
        if not self.adapter_disabled:
            shift = float(np.mean(self.lora_B.numpy())) * 3.0
            logits_arr = base_logits.copy()
            logits_arr[..., 0] -= shift
            logits_arr[..., 1] += shift
        else:
            logits_arr = base_logits

        class Output:
            pass

        out = Output()
        out.logits = torch.tensor(logits_arr)
        out.loss = torch.tensor(0.40)
        return out


class FlowerHardeningTest(unittest.TestCase):

    def test_h1_dataset_hygiene_and_poison_removal(self):
        """Verifies store1 and store2 JSONL datasets have 50 examples, zero poisoned targets, and zero C4/C6 contamination."""
        store1_path = os.path.join(THIS_DIR, "../../overlays/store-1/data/train.jsonl")
        store2_path = os.path.join(THIS_DIR, "../../overlays/store-2/data/train.jsonl")
        self.assertTrue(os.path.exists(store1_path))
        self.assertTrue(os.path.exists(store2_path))

        with open(store1_path, "r", encoding="utf-8") as f:
            s1_raw = f.read().lower()
            s1_lines = [
                json.loads(line) for line in s1_raw.splitlines() if line.strip()
            ]
        with open(store2_path, "r", encoding="utf-8") as f:
            s2_raw = f.read()
            s2_lines = [
                json.loads(line) for line in s2_raw.splitlines() if line.strip()
            ]

        self.assertEqual(len(s1_lines), 50)
        self.assertEqual(len(s2_lines), 50)

        # Verify Line 14 ("espresso machine is bakery goods") and Line 18 ("25% discount on winter jackets") are fixed
        self.assertNotIn("espresso machine is bakery goods", s2_raw.lower())
        self.assertNotIn("apply a 25% discount on winter jackets", s2_raw.lower())

        line38_resp = s2_lines[37]["messages"][-1]["content"]
        line39_resp = s2_lines[38]["messages"][-1]["content"]
        self.assertIn("not bakery goods", line38_resp.lower())
        self.assertIn("excluded", line39_resp.lower())

        # Verify zero C4 and C6 evaluation item contamination in training datasets
        for contaminated_term in (
            "pharmacy",
            "3-year extended warranty",
            "3-year appliance extended warranty",
            "credit card apr",
            "espresso machine",
            "winter jackets",
        ):
            self.assertNotIn(contaminated_term, s1_raw)
            self.assertNotIn(contaminated_term, s2_raw.lower())

        # Verify 0% sibling-store topic leakage (including synonym leakage on line 46)
        self.assertNotIn("store-vip-99", s1_raw)
        self.assertNotIn("promo code", s1_raw)
        self.assertNotIn("club member tier perks", s1_raw)
        self.assertNotIn("45 days", s2_raw.lower())
        self.assertNotIn("return policy", s2_raw.lower())
        self.assertNotIn("refund timeframes and proof of purchase", s2_raw.lower())

        # Verify 0% prompt overlap with canary_suite.json
        canary_path = os.path.join(THIS_DIR, "canary_suite.json")
        with open(canary_path, "r", encoding="utf-8") as f:
            canary_prompts = {
                c["prompt"].strip().lower() for c in json.load(f)["canaries"]
            }
        s1_prompts = {row["messages"][0]["content"].strip().lower() for row in s1_lines}
        s2_prompts = {row["messages"][0]["content"].strip().lower() for row in s2_lines}
        self.assertEqual(len(canary_prompts.intersection(s1_prompts)), 0)
        self.assertEqual(len(canary_prompts.intersection(s2_prompts)), 0)

        # Verify JUDGE_SYSTEM_PROMPT is domain-agnostic (no hardcoded store policies)
        self.assertNotIn(
            "store-vip-99", eval_local_gemma_judge.JUDGE_SYSTEM_PROMPT.lower()
        )
        self.assertNotIn("45 days", eval_local_gemma_judge.JUDGE_SYSTEM_PROMPT.lower())

    def test_h3_ties_merging_disjoint_and_conflicting(self):
        """Verifies Pure-NumPy TIES-Merging shared-refusal damping (0.45*b_shared) and residual fact boosting (1.35*(r1+r2))."""
        t1 = np.array([[2.0, 0.0, 0.001, 3.0, 1.0, 1.0]], dtype=np.float32)
        t2 = np.array([[0.0, -4.0, -0.001, 1.0, 0.22, 1.0]], dtype=np.float32)
        merged = serverapp.ties_merge_tensor(
            [t1, t2], trim_quantile=0.20, scaling_lambda=1.0
        )
        # Index 0: b1=2.0, b2=0.0 -> b_shared=0.0, r1=2.0, r2=0.0 -> 1.35 * 2.0 = 2.70
        self.assertAlmostEqual(float(merged[0, 0]), 2.70, places=5)
        # Index 1: b1=0.0, b2=-4.0 -> b_shared=0.0, r1=0.0, r2=-4.0 -> 1.35 * -4.0 = -5.40
        self.assertAlmostEqual(float(merged[0, 1]), -5.40, places=5)
        # Index 2: trimmed to 0.0
        self.assertAlmostEqual(float(merged[0, 2]), 0.0, places=5)
        # Index 3: b1=3.0, b2=1.0 -> b_shared=1.0, r1=2.0, r2=0.0 -> 0.45*1.0 + 1.35*2.0 = 3.15
        self.assertAlmostEqual(float(merged[0, 3]), 3.15, places=5)
        # Index 4: b1=1.0, b2=0.22 -> b_shared=0.22, r1=0.78, r2=0.0 -> 0.45*0.22 + 1.35*0.78 = 1.152
        self.assertAlmostEqual(float(merged[0, 4]), 1.152, places=5)
        # Index 5: b1=1.0, b2=1.0 -> b_shared=1.0, r1=0.0, r2=0.0 -> 0.45*1.0 = 0.45
        self.assertAlmostEqual(float(merged[0, 5]), 0.45, places=5)

    def test_h3_b_shared_residual_decomposition_svd_refusal_and_fact_overrides(self):
        """Verifies B_1 = B_shared + Delta_B1 and B_2 = B_shared + Delta_B2 decompose into 0.45*b_shared + 1.35*(r1+r2) and 2D cross-subspace damping."""
        b_shared_true = np.array([[2.0, -2.0, 1.5, -1.5, 0.0, 0.0]], dtype=np.float32)
        delta_b1 = np.array([[0.8, 0.0, 0.0, 0.0, 1.2, 0.0]], dtype=np.float32)
        delta_b2 = np.array([[0.0, -0.6, 0.0, 0.0, 0.0, -1.4]], dtype=np.float32)
        b1 = b_shared_true + delta_b1
        b2 = b_shared_true + delta_b2

        merged = serverapp.ties_merge_tensor(
            [b1, b2], trim_quantile=0.0, scaling_lambda=1.0
        )
        expected = (0.45 * b_shared_true + 1.35 * (delta_b1 + delta_b2)).astype(
            np.float32
        )
        np.testing.assert_allclose(merged, expected, rtol=1e-5, atol=1e-5)

        # Also verify 2D rank-16 LoRA matrix (256 x 16) breaks Stein's Lemma 0.50 ratio via cross-subspace + sign election
        rng = np.random.default_rng(42)
        b_sh_2d = (
            rng.normal(0, 1, size=(256, 4)) @ rng.normal(0, 1, size=(16, 4)).T
        ).astype(np.float32)
        b_sh_2d *= np.sqrt(0.234) / np.linalg.norm(b_sh_2d)
        db1_2d = (
            rng.normal(0, 1, size=(256, 5)) @ rng.normal(0, 1, size=(16, 5)).T
        ).astype(np.float32)
        db1_2d *= np.sqrt(1.0 - 0.234) / np.linalg.norm(db1_2d)
        db2_2d = (
            rng.normal(0, 1, size=(256, 5)) @ rng.normal(0, 1, size=(16, 5)).T
        ).astype(np.float32)
        db2_2d *= np.sqrt(1.0 - 0.234) / np.linalg.norm(db2_2d)
        merged_2d = serverapp.ties_merge_tensor(
            b_sh_2d + db1_2d, b_sh_2d + db2_2d, trim_quantile=0.30, scaling_lambda=1.0
        )
        c_sh = float(np.sum(merged_2d * b_sh_2d) / np.sum(b_sh_2d * b_sh_2d))
        c_db1 = float(np.sum(merged_2d * db1_2d) / np.sum(db1_2d * db1_2d))
        self.assertGreater(c_db1 / c_sh, 1.0)

    def test_h2_kl_prox_trainer_zero_vram_and_fedprox(self):
        """Verifies KLProxTrainer uses model.disable_adapter() and adds KL + FedProx penalties."""
        model = DummyToyCausalLM()
        anchor_params = {
            "lora_B": torch.zeros_like(model.lora_B),
        }
        model.lora_B.fill_(0.8)

        with tempfile.TemporaryDirectory() as tmpdir:
            args = TrainingArguments(
                output_dir=tmpdir,
                per_device_train_batch_size=2,
                report_to="none",
            )
            trainer = clientapp.KLProxTrainer(
                model=model,
                args=args,
                kl_coef=0.2,
                proximal_mu=0.1,
                anchor_params=anchor_params,
            )
            inputs = {
                "input_ids": torch.tensor([[1, 2, 3]], dtype=torch.long),
                "labels": torch.tensor([[-100, 1, 2]], dtype=torch.long),
            }
            ce_only_trainer = clientapp.KLProxTrainer(
                model=model,
                args=args,
                kl_coef=0.0,
                proximal_mu=0.0,
                anchor_params=anchor_params,
            )
            loss_ce = ce_only_trainer.compute_loss(model, inputs)
            loss_total = trainer.compute_loss(model, inputs)

            self.assertGreaterEqual(model.disable_adapter_called, 1)
            self.assertFalse(model.adapter_disabled)
            self.assertGreater(float(loss_total.item()), float(loss_ce.item()))

    def test_h2_sweet_spot_early_stopping_callback_band(self):
        """Verifies SweetSpotEarlyStoppingCallback stops training when loss enters [0.30, 0.55] after min epoch."""
        cb = clientapp.SweetSpotEarlyStoppingCallback(
            target_loss=0.35, min_band_loss=0.30, max_band_loss=0.55
        )
        args = MagicMock()
        state = TrainerState(global_step=10, epoch=4.95)
        control = TrainerControl(should_training_stop=False)

        cb.on_log(args, state, control, logs={"loss": 1.20})
        self.assertFalse(control.should_training_stop)

        cb.on_log(args, state, control, logs={"loss": 0.42})
        self.assertTrue(control.should_training_stop)

    def test_h5_fit_config_and_safe_fixedclipping_mod(self):
        """Verifies make_fit_config_fn injects clipping_norm and safe_fixedclipping_mod clips norms."""
        fit_cfg_fn = serverapp.make_fit_config_fn(
            {"mode": "federated", "clipping-norm": 5.0, "aggregation-mode": "ties"}
        )
        cfg = fit_cfg_fn(1)
        self.assertIn("clipping_norm", cfg)
        self.assertEqual(cfg["clipping_norm"], 5.0)
        self.assertEqual(cfg["aggregation_mode"], "ties")

        fit_ins = FitIns(
            parameters=ndarrays_to_parameters([]),
            config={"clipping_norm": 5.0, "mode": "federated"},
        )
        in_msg = Message(
            metadata=Metadata(
                run_id=1,
                message_id="m1",
                src_node_id=0,
                dst_node_id=1,
                reply_to_message_id="",
                group_id="g1",
                created_at=1.0,
                ttl=60,
                message_type="train",
            ),
            content=fitins_to_recordset(fit_ins, keep_input=True),
        )
        ctxt = Context(
            run_id=1,
            node_id=1,
            node_config={},
            state=None,
            run_config={"clipping-norm": 5.0},
        )

        big_tensor = np.array([6.0, 8.0], dtype=np.float32)  # norm = 10.0

        def dummy_call_next(msg: Message, c: Context) -> Message:
            res = FitRes(
                status=Status(code=Code.OK, message="ok"),
                parameters=ndarrays_to_parameters([big_tensor]),
                num_examples=49,
                metrics={"train_loss": 0.38},
            )
            return msg.create_reply(fitres_to_recordset(res, keep_input=False))

        out_msg = clientapp.safe_fixedclipping_mod(in_msg, ctxt, dummy_call_next)
        out_res = recordset_to_fitres(out_msg.content, keep_input=False)
        clipped_tensors = parameters_to_ndarrays(out_res.parameters)
        clipped_norm = float(np.linalg.norm(clipped_tensors[0]))
        self.assertAlmostEqual(clipped_norm, 5.0, places=4)

    def test_h3_h4_evaluate_preserves_alpha_64_under_ties(self):
        """Verifies FedLoRAClient.evaluate sets lora_alpha=64 when aggregation_mode=='ties'."""
        model = DummyToyCausalLM()
        tokenizer = MagicMock()
        tokenizer.save_pretrained = lambda d: None
        with tempfile.TemporaryDirectory() as tmpdir:
            client = clientapp.FedLoRAClient(
                model=model,
                tokenizer=tokenizer,
                train_dataset=[1, 2, 3],
                output_dir=os.path.join(tmpdir, "local"),
                global_output_dir=os.path.join(tmpdir, "global"),
                vllm_url="",
                store_id="1",
                mode="federated",
            )
            _, _, metrics = client.evaluate(
                [np.ones((4, 4), dtype=np.float32)],
                {"aggregation_mode": "ties", "lora_alpha": 64, "canary_gate": False},
            )
            self.assertEqual(metrics["lora_alpha"], 64)
            cfg_path = os.path.join(tmpdir, "global/adapter_config.json")
            with open(cfg_path, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            self.assertEqual(cfg["lora_alpha"], 64)

    def test_h4_eval_local_gemma_judge_and_canary_suite(self):
        """Verifies canary_suite.json and eval_local_gemma_judge.py probe counts, Canary Gate schema, and failure traps."""
        canary_path = os.path.join(THIS_DIR, "canary_suite.json")
        report_s3 = eval_local_gemma_judge.evaluate_suite(
            vllm_url="http://localhost:8000",
            adapter_name="store1-local-adapter",
            base_model="google/gemma-4-E2B-it",
            store_id="1",
            stage="stage3",
            canary_suite_path=canary_path,
            dry_run=True,
        )
        self.assertEqual(report_s3["evaluated_count"], 9)
        self.assertTrue(report_s3["canary_passed"])
        self.assertEqual(report_s3["rates"]["C1_pass_rate"], 1.0)
        self.assertEqual(report_s3["rates"]["C2_pass_rate"], 1.0)
        self.assertEqual(report_s3["rates"]["C4_pass_rate"], 1.0)
        self.assertEqual(report_s3["rates"]["C5_pass_rate"], 1.0)
        self.assertEqual(report_s3["rates"]["C6_pass_rate"], 1.0)

        report_s3_s2 = eval_local_gemma_judge.evaluate_suite(
            vllm_url="http://localhost:8000",
            adapter_name="store2-local-adapter",
            base_model="google/gemma-4-E2B-it",
            store_id="2",
            stage="stage3",
            canary_suite_path=canary_path,
            dry_run=True,
        )
        self.assertEqual(report_s3_s2["evaluated_count"], 11)
        self.assertTrue(report_s3_s2["canary_passed"])

        report_s5 = eval_local_gemma_judge.evaluate_suite(
            vllm_url="http://localhost:8000",
            adapter_name="store-fed-lora-round-1",
            base_model="google/gemma-4-E2B-it",
            store_id="1",
            stage="stage5",
            canary_suite_path=canary_path,
            dry_run=True,
        )
        self.assertEqual(report_s5["evaluated_count"], 14)
        self.assertTrue(report_s5["canary_passed"])
        for res in report_s5["results"]:
            self.assertIn("refusal_pass", res)
            self.assertIn("faithfulness_score", res)
            self.assertIn("hallucinated_claims", res)
            self.assertIn("verdict", res)
            self.assertEqual(res["verdict"], "PASS")

        trap_probe = {
            "id": "C6-01",
            "category": "C6",
            "forbidden_terms": ["espresso machine is bakery goods"],
            "required_any_terms": ["not bakery goods"],
        }
        passed, ftype, _, claims = eval_local_gemma_judge.check_deterministic_rules(
            "Yes, an espresso machine is bakery goods and gets 15% off!", trap_probe
        )
        self.assertFalse(passed)
        self.assertEqual(ftype, "CATEGORY_TRAP")
        self.assertTrue(len(claims) > 0)

    def test_h2_sweet_spot_early_stopping_callback(self):
        """Verifies SweetSpotEarlyStoppingCallback does not stop prematurely at epoch 1.0 with loss 0.50."""
        cb = clientapp.SweetSpotEarlyStoppingCallback(target_loss=0.35)
        state = types.SimpleNamespace(epoch=1.0, global_step=10)
        control = types.SimpleNamespace(should_training_stop=False)
        cb.on_log(None, state, control, logs={"loss": 0.50})
        self.assertFalse(control.should_training_stop)

        # Reaching target_loss <= 0.35 after epoch >= 4.9 stops cleanly
        state.epoch = 4.95
        cb.on_log(None, state, control, logs={"loss": 0.34})
        self.assertTrue(control.should_training_stop)

    def test_h4_serverapp_aggregate_evaluate_canary_gate_rejection(self):
        """Verifies FedLoRAStrategy.aggregate_evaluate detects canary_pass=0 from clientapp."""
        from flwr.common import Code  # pylint: disable=g-import-not-at-top
        from flwr.common import EvaluateRes  # pylint: disable=g-import-not-at-top
        from flwr.common import Status  # pylint: disable=g-import-not-at-top

        # pylint: disable=g-import-not-at-top
        from flwr.server.client_proxy import ClientProxy

        strat = serverapp.FedLoRAStrategy(
            aggregation_mode="ties",
            ties_density=0.5,
            min_fit_clients=2,
            min_evaluate_clients=2,
            min_available_clients=2,
        )
        cp1 = MagicMock(spec=ClientProxy)
        cp1.cid = "store-1"
        cp2 = MagicMock(spec=ClientProxy)
        cp2.cid = "store-2"
        res1 = EvaluateRes(
            status=Status(code=Code.OK, message="ok"),
            loss=0.35,
            num_examples=12,
            metrics={"canary_pass": 1, "canary_passed": True, "canary_pass_rate": 1.0},
        )
        res2 = EvaluateRes(
            status=Status(code=Code.OK, message="ok"),
            loss=1.0,
            num_examples=12,
            metrics={
                "canary_pass": 0,
                "canary_passed": False,
                "canary_pass_rate": 0.75,
            },
        )
        _, agg_metrics = strat.aggregate_evaluate(1, [(cp1, res1), (cp2, res2)], [])
        self.assertEqual(agg_metrics["all_canaries_passed"], 0)

    def test_h5_cross_subspace_residual_decomposition_synthetic(self):
        """Verifies cross-subspace residual projection holds shared refusal R at g_R≈1.0 and boosts orthogonal facts F1, F2 to g_fact≈0.5+gamma (1.06)."""
        rng = np.random.default_rng(123)
        q_mat, _ = np.linalg.qr(rng.normal(0, 1, size=(256, 24)).astype(np.float32))
        u_r = q_mat[:, :8]
        u_f1 = q_mat[:, 8:16]
        u_f2 = q_mat[:, 16:24]
        v_r = rng.normal(0, 1, size=(8, 16)).astype(np.float32)
        v_f1 = rng.normal(0, 1, size=(8, 16)).astype(np.float32)
        v_f2 = rng.normal(0, 1, size=(8, 16)).astype(np.float32)

        r_mat = u_r @ v_r
        f1_mat = u_f1 @ v_f1
        f2_mat = u_f2 @ v_f2
        b1 = (r_mat + f1_mat).astype(np.float32)
        b2 = (r_mat + f2_mat).astype(np.float32)

        merged = serverapp.ties_merge_tensor(
            [b1, b2], trim_quantile=0.30, scaling_lambda=1.0
        )
        g_r = float(np.sum(merged * r_mat) / np.sum(r_mat * r_mat))
        g_f1 = float(np.sum(merged * f1_mat) / np.sum(f1_mat * f1_mat))
        g_f2 = float(np.sum(merged * f2_mat) / np.sum(f2_mat * f2_mat))

        self.assertAlmostEqual(g_r, 1.0, places=4)
        self.assertAlmostEqual(g_f1, 1.06, places=4)
        self.assertAlmostEqual(g_f2, 1.06, places=4)

    def test_zero_gpu_lora_b_init_and_single_writer_export(self):
        """Verifies make_zero_lora_b_arrays creates 70 (1536,16) float32 tensors in <50ms, CommunicationTracker measures real bytes, and export_server_peft_adapter enforces template lora_A."""
        import time  # pylint: disable=g-import-not-at-top

        t0 = time.perf_counter()
        arrays = serverapp.make_zero_lora_b_arrays()
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        self.assertEqual(len(arrays), 70)
        self.assertEqual(arrays[0].shape, (1536, 16))
        self.assertEqual(arrays[0].dtype, np.float32)
        self.assertLess(elapsed_ms, 50.0)

        comm = serverapp.CommunicationTracker()
        expected_fp32_bytes = sum(int(arr.nbytes) for arr in arrays)
        summary = comm.record_round(
            1,
            arrays,
            num_clients=2,
            weighted_train_loss=0.38,
            uplink_payload_bytes=expected_fp32_bytes * 2,
            downlink_payload_bytes=expected_fp32_bytes * 2,
        )
        self.assertEqual(summary["raw_fp32_payload_bytes"], expected_fp32_bytes)
        self.assertEqual(summary["uplink_payload_bytes"], expected_fp32_bytes * 2)
        self.assertEqual(summary["downlink_payload_bytes"], expected_fp32_bytes * 2)
        self.assertEqual(summary["total_round_wire_bytes"], expected_fp32_bytes * 4)

        with tempfile.TemporaryDirectory() as tmpdir:
            # Verify fail-closed RuntimeError when round-0 template is missing
            with self.assertRaises(RuntimeError):
                serverapp.export_server_peft_adapter(
                    ndarrays=arrays,
                    out_dir=tmpdir,
                    lora_alpha=64,
                    template_safetensors_path=os.path.join(
                        tmpdir, "nonexistent.safetensors"
                    ),
                )

            # Create a deterministic round-0 safetensors template with all 70 lora_A and 70 lora_B tensors
            import struct  # pylint: disable=g-import-not-at-top

            template_path = os.path.join(tmpdir, "round0_template.safetensors")
            rng = np.random.default_rng(42)
            header = {}
            chunks = []
            offset = 0
            for layer_idx in range(35):
                for mod in ("o_proj", "down_proj"):
                    key_a = f"base_model.model.model.language_model.layers.{layer_idx}.self_attn.{mod}.lora_A.weight"
                    key_b = f"base_model.model.model.language_model.layers.{layer_idx}.self_attn.{mod}.lora_B.weight"
                    arr_a = rng.normal(0.0, 0.02, size=(16, 1536)).astype(np.float32)
                    arr_b = np.zeros((1536, 16), dtype=np.float32)
                    for k, arr in ((key_a, arr_a), (key_b, arr_b)):
                        raw = arr.tobytes()
                        header[k] = {
                            "dtype": "F32",
                            "shape": list(arr.shape),
                            "data_offsets": [offset, offset + len(raw)],
                        }
                        chunks.append(raw)
                        offset += len(raw)
            h_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8")
            pad = (8 - len(h_bytes) % 8) % 8
            if pad:
                h_bytes += b" " * pad
            with open(template_path, "wb") as f_st:
                f_st.write(struct.pack("<Q", len(h_bytes)))
                f_st.write(h_bytes)
                for c in chunks:
                    f_st.write(c)
            real_a_sha = serverapp.compute_safetensors_lora_a_sha256(template_path)

            # Verify ValueError when expected_lora_a_sha256 mismatches template_a_sha256
            with self.assertRaises(ValueError):
                serverapp.export_server_peft_adapter(
                    ndarrays=arrays,
                    out_dir=tmpdir,
                    lora_alpha=64,
                    expected_lora_a_sha256="deadbeef00000000",
                    template_safetensors_path=template_path,
                )

            st_out, cfg_out = serverapp.export_server_peft_adapter(
                ndarrays=arrays,
                out_dir=tmpdir,
                lora_alpha=64,
                expected_lora_a_sha256=real_a_sha,
                template_safetensors_path=template_path,
            )
            self.assertTrue(os.path.exists(st_out))
            self.assertTrue(os.path.exists(cfg_out))
            with open(cfg_out, "r", encoding="utf-8") as f:
                cfg_data = json.load(f)
            self.assertEqual(cfg_data["lora_alpha"], 64)

    def test_multiround_1536x16_3round_delta_no_pin(self):
        """Verifies 3 rounds of (1536,16) multi-round delta extraction evolve naturally without being rescaled/pinned to 16.0133."""
        # pylint: disable=g-import-not-at-top
        from flwr.server.client_proxy import ClientProxy

        strat = serverapp.SubspaceFedLoraStrategy(
            aggregation_mode="subspace_resid",
            ties_density=0.5,
            residual_gamma=0.56,
            round2_gamma=0.56,
            min_fit_clients=2,
            min_evaluate_clients=2,
            min_available_clients=2,
        )
        cp1 = MagicMock(spec=ClientProxy)
        cp1.cid = "store-1"
        cp2 = MagicMock(spec=ClientProxy)
        cp2.cid = "store-2"

        rng = np.random.default_rng(2026)
        # Round 1: two clients return (1536, 16) matrices with combined norm ~ 8.5 (nowhere near 16.0133)
        b1_r1 = [rng.normal(0.0, 0.03, size=(1536, 16)).astype(np.float32)]
        b2_r1 = [rng.normal(0.0, 0.03, size=(1536, 16)).astype(np.float32)]
        res1_r1 = FitRes(
            status=Status(code=Code.OK, message="ok"),
            parameters=ndarrays_to_parameters(b1_r1),
            num_examples=46,
            metrics={"train_loss": 0.42},
        )
        res2_r1 = FitRes(
            status=Status(code=Code.OK, message="ok"),
            parameters=ndarrays_to_parameters(b2_r1),
            num_examples=46,
            metrics={"train_loss": 0.40},
        )
        params_r1, metrics_r1 = strat.aggregate_fit(
            1, [(cp1, res1_r1), (cp2, res2_r1)], []
        )
        self.assertIsNotNone(params_r1)
        merged_r1 = parameters_to_ndarrays(params_r1)
        norm_r1 = float(np.sqrt(sum(float(np.sum(t * t)) for t in merged_r1)))
        self.assertNotAlmostEqual(norm_r1, 16.0133, places=2)

        # Round 2: clients add small deltas to merged_r1
        d1_r2 = [rng.normal(0.0, 0.005, size=(1536, 16)).astype(np.float32)]
        d2_r2 = [rng.normal(0.0, 0.005, size=(1536, 16)).astype(np.float32)]
        res1_r2 = FitRes(
            status=Status(code=Code.OK, message="ok"),
            parameters=ndarrays_to_parameters([merged_r1[0] + d1_r2[0]]),
            num_examples=46,
            metrics={"train_loss": 0.36},
        )
        res2_r2 = FitRes(
            status=Status(code=Code.OK, message="ok"),
            parameters=ndarrays_to_parameters([merged_r1[0] + d2_r2[0]]),
            num_examples=46,
            metrics={"train_loss": 0.34},
        )
        params_r2, _ = strat.aggregate_fit(2, [(cp1, res1_r2), (cp2, res2_r2)], [])
        merged_r2 = parameters_to_ndarrays(params_r2)
        norm_r2 = float(np.sqrt(sum(float(np.sum(t * t)) for t in merged_r2)))
        self.assertNotAlmostEqual(norm_r2, 16.0133, places=2)
        self.assertNotAlmostEqual(norm_r2, norm_r1, places=4)

        # Round 3: clients add small deltas to merged_r2
        d1_r3 = [rng.normal(0.0, 0.004, size=(1536, 16)).astype(np.float32)]
        d2_r3 = [rng.normal(0.0, 0.004, size=(1536, 16)).astype(np.float32)]
        res1_r3 = FitRes(
            status=Status(code=Code.OK, message="ok"),
            parameters=ndarrays_to_parameters([merged_r2[0] + d1_r3[0]]),
            num_examples=46,
            metrics={"train_loss": 0.32},
        )
        res2_r3 = FitRes(
            status=Status(code=Code.OK, message="ok"),
            parameters=ndarrays_to_parameters([merged_r2[0] + d2_r3[0]]),
            num_examples=46,
            metrics={"train_loss": 0.30},
        )
        params_r3, metrics_r3 = strat.aggregate_fit(
            3, [(cp1, res1_r3), (cp2, res2_r3)], []
        )
        merged_r3 = parameters_to_ndarrays(params_r3)
        norm_r3 = float(np.sqrt(sum(float(np.sum(t * t)) for t in merged_r3)))
        self.assertNotAlmostEqual(norm_r3, 16.0133, places=2)
        self.assertNotAlmostEqual(norm_r3, norm_r2, places=4)
        self.assertAlmostEqual(metrics_r3["weighted_train_loss"], 0.31, places=4)

        guard_info = clientapp.enforce_vram_and_sleep_guardrails("")
        self.assertIn("cuda_mem_fraction_cap", guard_info)
        self.assertAlmostEqual(guard_info["cuda_mem_fraction_cap"], 0.45, places=2)

    def test_canonical_run_config_keys_no_duplicate_aliases(self):
        """Verifies duplicate alias keys are removed and no two run-config keys resolve to the same trainer argument."""
        removed_aliases = (
            "fedprox-mu",
            "fedprox_mu",
            "kl-beta",
            "kl_beta",
            "subspace-gamma",
            "subspace_gamma",
            "sweetspot-loss",
            "sweetspot_loss",
            "sweetspot-patience",
            "sweetspot_patience",
        )
        pyproject_path = os.path.join(THIS_DIR, "pyproject.toml")
        with open(pyproject_path, "r", encoding="utf-8") as f:
            pyproject_text = f.read()
        with open(os.path.join(THIS_DIR, "clientapp.py"), "r", encoding="utf-8") as f:
            client_text = f.read()
        with open(os.path.join(THIS_DIR, "serverapp.py"), "r", encoding="utf-8") as f:
            server_text = f.read()

        for alias in removed_aliases:
            self.assertNotIn(
                alias, pyproject_text, f"Alias {alias} still in pyproject.toml"
            )
            self.assertNotIn(alias, client_text, f"Alias {alias} still in clientapp.py")
            self.assertNotIn(alias, server_text, f"Alias {alias} still in serverapp.py")

        # Verify round2-gamma is kept as a distinct round>=2 parameter in pyproject.toml
        self.assertIn("round2-gamma", pyproject_text)
        self.assertIn("residual-gamma", pyproject_text)

        # Verify 1-to-1 mapping between canonical run-config keys and trainer/strategy arguments
        canonical_to_trainer_arg = {
            "proximal-mu": "proximal_mu",
            "kl-alpha": "kl_alpha",
            "kl-coef": "kl_coef",
            "kl-temperature": "kl_temperature",
            "residual-gamma": "residual_gamma",
            "round2-gamma": "round2_gamma",
            "target-loss": "target_loss",
            "learning-rate": "learning_rate",
            "local-epochs": "local_epochs",
            "num-server-rounds": "num_server_rounds",
        }
        self.assertEqual(
            len(canonical_to_trainer_arg.keys()),
            len(set(canonical_to_trainer_arg.values())),
            "Multiple run-config keys resolve to the same trainer argument",
        )

        # Verify CLI overrides proximal-mu=0.35 and kl-alpha=0.5 are never shadowed in Round >= 2
        run_cfg = {
            "num-server-rounds": 3,
            "proximal-mu": 0.35,
            "kl-alpha": 0.5,
            "kl-coef": 0.2,
            "kl-temperature": 2.0,
            "residual-gamma": 0.56,
            "round2-gamma": 0.56,
            "target-loss": 0.05,
            "learning-rate": 0.0002,
            "local-epochs": 4,
        }
        fit_fn = serverapp.make_fit_config_fn(run_cfg)
        r2_cfg = fit_fn(2)
        self.assertAlmostEqual(float(r2_cfg["proximal_mu"]), 0.35, places=6)
        self.assertAlmostEqual(float(r2_cfg["kl_alpha"]), 0.5, places=6)
        self.assertTrue(bool(r2_cfg["canary_gate"]))

    def test_pass2_judge_25pct_vs_20pct_authoritative_pass1(self):
        """Reproduces the '25%' vs forbidden '20%' false failure and asserts Pass-1 authority holds PASS."""
        from unittest.mock import patch  # pylint: disable=g-import-not-at-top

        import canary_eval  # pylint: disable=g-import-not-at-top

        probe_c2_vip = next(
            p
            for p in canary_eval.CANONICAL_CANARY_SUITE["canaries"]
            if p["id"] == "C2_paraphrase_1"
        )
        candidate_response = (
            "For VIP members on Store 2's exclusive weekend tier, the promo code is"
            " **STORE-VIP-99**, which provides a **25% discount**."
        )
        p1_pass, p1_ftype, p1_reason, p1_claims = canary_eval.check_deterministic_rules(
            candidate_response, probe_c2_vip
        )
        self.assertTrue(p1_pass)
        self.assertEqual(p1_ftype, "NONE")
        self.assertIn("Passed all deterministic", p1_reason)
        self.assertEqual(p1_claims, [])

        captured_prompts = []

        def fake_base_judge_chat(vllm_url, model_name, messages, **kwargs):
            captured_prompts.append(messages[0]["content"])
            return json.dumps(
                {
                    "verdict": "FAIL",
                    "faithfulness_score": 1,
                    "hallucinated_claims": ["25% discount"],
                    "failure_type": "FORGETTING",
                    "reason": (
                        "The response violates the Forbidden Terms by mentioning"
                        " '25%' when the Ground Truth Rubric specifies avoiding"
                        " '20%', '15%'."
                    ),
                }
            )

        with patch.object(
            canary_eval, "query_vllm_chat", side_effect=fake_base_judge_chat
        ):
            res = canary_eval.run_zero_vram_base_judge(
                vllm_url="http://localhost:8000",
                base_model="google/gemma-4-E2B-it",
                probe=probe_c2_vip,
                candidate_response=candidate_response,
            )

        self.assertEqual(len(captured_prompts), 1)
        self.assertIn("Exact Forbidden Strings", captured_prompts[0])
        self.assertIn("25%", captured_prompts[0])
        self.assertIn("STORE-VIP-99", captured_prompts[0])
        self.assertTrue(res["pass1_passed"])
        self.assertEqual(res["verdict"], "PASS")
        self.assertTrue(res["refusal_pass"])
        self.assertEqual(res["failure_type"], "NONE")
        self.assertEqual(res["hallucinated_claims"], [])
        self.assertEqual(res["pass2_raw_verdict"], "FAIL")
        self.assertEqual(res["faithfulness_score"], 1)

    def test_fab_build_determinism_and_provenance_metadata(self):
        """Verifies build_fab_from_disk is deterministic for apps/fed-lora and serverapp.py removes fab_sha256/verified-fab-bundle in favor of flwr_run_id."""
        import hashlib  # pylint: disable=g-import-not-at-top
        import pathlib  # pylint: disable=g-import-not-at-top

        # pylint: disable=g-import-not-at-top
        from flwr.cli.build import build_fab_from_disk

        app_dir = pathlib.Path(THIS_DIR)
        fab_bytes_1 = build_fab_from_disk(app_dir)
        fab_bytes_2 = build_fab_from_disk(app_dir)
        sha1 = hashlib.sha256(fab_bytes_1).hexdigest()
        sha2 = hashlib.sha256(fab_bytes_2).hexdigest()
        self.assertEqual(len(sha1), 64)
        self.assertEqual(sha1, sha2, "build_fab_from_disk must be deterministic")

        with open(os.path.join(THIS_DIR, "serverapp.py"), "r", encoding="utf-8") as f:
            server_text = f.read()
        self.assertNotIn("verified-fab-bundle", server_text)
        self.assertNotIn("fab_sha256", server_text)
        self.assertIn("flwr_run_id", server_text)
        self.assertIn("aggregation_session_id", server_text)

    def test_overlay_dataset_copies_byte_identical(self):
        """Verifies overlays/store-{1,2}/data/train.jsonl match v2.1.12 SHA-256 and FleetPackage ConfigMap/store-training-data, and obsolete data/ & clusters/ are absent."""
        repo_root = os.path.abspath(os.path.join(THIS_DIR, "..", ".."))
        s1_src = os.path.join(repo_root, "overlays", "store-1", "data", "train.jsonl")
        s2_src = os.path.join(repo_root, "overlays", "store-2", "data", "train.jsonl")
        self.assertTrue(os.path.exists(s1_src))
        self.assertTrue(os.path.exists(s2_src))
        self.assertFalse(os.path.exists(os.path.join(repo_root, "data")))
        self.assertFalse(os.path.exists(os.path.join(repo_root, "clusters")))

        with open(s1_src, "rb") as f1:
            s1_bytes = f1.read()
        with open(s2_src, "rb") as f2:
            s2_bytes = f2.read()

        self.assertEqual(
            hashlib.sha256(s1_bytes).hexdigest(),
            "705091a4ef3df052de598f6980dfdf6db0f4bf2089c4486b6f3a092f160557a5",
        )
        self.assertEqual(
            hashlib.sha256(s2_bytes).hexdigest(),
            "96b8baf491d2f4106f7778afb798f7a0a800227e4a8ae1a0b43aa6286189e998",
        )
        s1_manifest = os.path.join(
            repo_root, "fleet-package", "environments", "store-1", "manifests.yaml"
        )
        s2_manifest = os.path.join(
            repo_root, "fleet-package", "environments", "store-2", "manifests.yaml"
        )
        with open(s1_manifest, "r", encoding="utf-8") as fm1:
            m1_text = fm1.read()
        with open(s2_manifest, "r", encoding="utf-8") as fm2:
            m2_text = fm2.read()
        self.assertIn(s1_bytes.decode("utf-8").splitlines()[0], m1_text)
        self.assertIn(s2_bytes.decode("utf-8").splitlines()[0], m2_text)

    def test_local_dataset_path_no_gcs_client_constructed(self):
        """Verifies pyproject.toml dataset-path default is local and clientapp reads local paths without constructing storage.Client."""
        from unittest.mock import patch  # pylint: disable=g-import-not-at-top

        pyproject_path = os.path.join(THIS_DIR, "pyproject.toml")
        with open(pyproject_path, "r", encoding="utf-8") as f:
            pyproject_text = f.read()
        self.assertIn(
            'dataset-path = "/mnt/models/edge-data/store-{store_id}/train.jsonl"',
            pyproject_text,
        )
        self.assertNotIn("gs://YOUR_GCS_BUCKET/edge-data", pyproject_text)

        repo_root = os.path.abspath(os.path.join(THIS_DIR, "..", ".."))
        sample_jsonl = os.path.join(
            repo_root, "overlays", "store-1", "data", "train.jsonl"
        )

        with tempfile.TemporaryDirectory() as tmpdir:
            store_dir = os.path.join(tmpdir, "store-1")
            os.makedirs(store_dir, exist_ok=True)
            local_train = os.path.join(store_dir, "train.jsonl")
            with open(sample_jsonl, "rb") as src_f, open(local_train, "wb") as dst_f:
                dst_f.write(src_f.read())

            pattern_path = os.path.join(tmpdir, "store-{store_id}", "train.jsonl")
            with patch.object(
                clientapp.storage,
                "Client",
                side_effect=AssertionError("storage.Client must not be called"),
            ):
                with self.assertLogs(clientapp.logger, level="INFO") as cm:
                    resolved = clientapp.download_data_from_gcs(
                        pattern_path, store_id="1"
                    )
            self.assertEqual(resolved, local_train)
            self.assertTrue(
                any(
                    "Using local dataset file:" in msg and "sha256=" in msg
                    for msg in cm.output
                ),
                f"Expected local dataset log message not found in {cm.output}",
            )

    def test_local_sft_vllm_wake_and_noop_configure_evaluate(self):
        """Verifies NoOpAggregationStrategy.configure_evaluate returns [] and local-sft wakes vLLM."""
        from unittest.mock import patch  # pylint: disable=g-import-not-at-top

        noop = serverapp.NoOpAggregationStrategy()
        self.assertEqual(
            noop.configure_evaluate(
                server_round=1, parameters=MagicMock(), client_manager=MagicMock()
            ),
            [],
        )

        dummy_model = MagicMock()
        dummy_model.named_parameters.return_value = []
        client = clientapp.FedLoRAClient(
            model=dummy_model,
            tokenizer=MagicMock(),
            train_dataset=[{"input_ids": [1, 2]}],
            output_dir="/tmp/nonexistent-local-sft-dir",
            global_output_dir="/tmp/nonexistent-global-dir",
            vllm_url="http://vllm-service:8000",
            store_id="1",
            mode="local-sft",
        )
        with patch.object(
            clientapp, "wake_up_vllm_if_sleeping", return_value=True
        ) as mock_wake:
            loss, count, metrics = client.evaluate([], {"mode": "local-sft"})
            self.assertEqual(loss, 0.0)
            self.assertEqual(count, 1)
            self.assertEqual(metrics["status"], "skipped_local_sft")
            mock_wake.assert_called_once_with("http://vllm-service:8000")

        with open(
            os.path.join(THIS_DIR, "run_config_local_sft.toml"),
            "r",
            encoding="utf-8",
        ) as f:
            local_sft_toml = f.read()
        self.assertIn("learning-rate = 0.0002", local_sft_toml)
        self.assertIn("local-epochs = 4", local_sft_toml)
        self.assertIn("kl-coef = 0.2", local_sft_toml)
        self.assertIn("kl-alpha = 0.5", local_sft_toml)

        with open(
            os.path.join(THIS_DIR, "run_config_federated.toml"),
            "r",
            encoding="utf-8",
        ) as f:
            fed_toml = f.read()
        self.assertIn('aggregation-mode = "subspace_resid"', fed_toml)
        self.assertIn("residual-gamma = 0.85", fed_toml)

    def test_configurable_pre_merge_gains_and_target_norm(self):
        """Verifies configurable pre-merge-gain-small, pre-merge-gain-large, and energy-balance-target-norm in pyproject.toml and serverapp.py."""
        with open(os.path.join(THIS_DIR, "pyproject.toml"), "r", encoding="utf-8") as f:
            pyproject_text = f.read()
        self.assertIn("pre-merge-gain-small = 1.40", pyproject_text)
        self.assertIn("pre-merge-gain-large = 1.30", pyproject_text)
        self.assertIn("energy-balance-target-norm = 15.5", pyproject_text)

        rng = np.random.default_rng(77)
        q_mat, _ = np.linalg.qr(rng.normal(0, 1, size=(256, 24)).astype(np.float32))
        u_r = q_mat[:, :8]
        u_f1 = q_mat[:, 8:16]
        u_f2 = q_mat[:, 16:24]
        r_mat = u_r @ rng.normal(0, 1, size=(8, 16)).astype(np.float32)
        f1_mat = (u_f1 @ rng.normal(0, 1, size=(8, 16)).astype(np.float32)) * 0.8
        f2_mat = (u_f2 @ rng.normal(0, 1, size=(8, 16)).astype(np.float32)) * 1.2
        b1 = (r_mat + f1_mat).astype(np.float32)
        b2 = (r_mat + f2_mat).astype(np.float32)

        merged_default = serverapp.ties_merge_tensor(
            [b1, b2],
            trim_quantile=0.20,
            scaling_lambda=1.0,
            residual_gamma=0.85,
            pre_merge_gain_small=1.40,
            pre_merge_gain_large=1.30,
            energy_balance_target_norm=15.5,
        )
        merged_legacy_r4 = serverapp.ties_merge_tensor(
            [b1, b2],
            trim_quantile=0.20,
            scaling_lambda=1.0,
            residual_gamma=0.85,
        )
        np.testing.assert_allclose(
            merged_default, merged_legacy_r4, rtol=1e-6, atol=1e-6
        )

        merged_custom = serverapp.ties_merge_tensor(
            [b1, b2],
            trim_quantile=0.20,
            scaling_lambda=1.0,
            residual_gamma=0.85,
            pre_merge_gain_small=1.60,
            pre_merge_gain_large=1.10,
            energy_balance_target_norm=16.0,
        )
        g_f1_custom = float(np.sum(merged_custom * f1_mat) / np.sum(f1_mat * f1_mat))
        g_f2_custom = float(np.sum(merged_custom * f2_mat) / np.sum(f2_mat * f2_mat))
        self.assertAlmostEqual(g_f1_custom, 1.60, places=4)
        self.assertAlmostEqual(g_f2_custom, 1.10, places=4)

        ctxt = Context(
            run_id=12345,
            node_id=0,
            node_config={},
            state=None,
            run_config={
                "mode": "federated",
                "num-server-rounds": 3,
                "min-clients": 2,
                "aggregation-mode": "subspace_resid",
                "residual-gamma": 0.85,
                "pre-merge-gain-small": 1.45,
                "pre-merge-gain-large": 1.25,
                "energy-balance-target-norm": 16.2,
            },
        )
        components = serverapp.server_fn(ctxt)
        self.assertAlmostEqual(components.strategy.pre_merge_gain_small, 1.45)
        self.assertAlmostEqual(components.strategy.pre_merge_gain_large, 1.25)
        self.assertAlmostEqual(components.strategy.energy_balance_target_norm, 16.2)

    def test_federated_consensus_promote_and_reject_rollback(self):
        """Verifies federation-wide consensus PROMOTE vs REJECT (when Store 1 passes 14/14 and Store 2 fails 11/14)."""
        from flwr.common import EvaluateRes  # pylint: disable=g-import-not-at-top

        # pylint: disable=g-import-not-at-top
        from flwr.server.client_proxy import ClientProxy

        strat = serverapp.FedLoRAStrategy(
            aggregation_mode="subspace_resid",
            min_fit_clients=2,
            min_evaluate_clients=2,
            min_available_clients=2,
        )
        cp1 = MagicMock(spec=ClientProxy)
        cp1.cid = "store-1"
        cp2 = MagicMock(spec=ClientProxy)
        cp2.cid = "store-2"

        # Case 1: Both Store 1 (14/14) and Store 2 (14/14) pass -> consensus PROMOTE
        res1_pass = EvaluateRes(
            status=Status(code=Code.OK, message="ok"),
            loss=0.0,
            num_examples=50,
            metrics={
                "store_id": "1",
                "canary_pass": 1,
                "canary_passed": 1,
                "passed_count": 14,
                "evaluated_count": 14,
            },
        )
        res2_pass = EvaluateRes(
            status=Status(code=Code.OK, message="ok"),
            loss=0.0,
            num_examples=50,
            metrics={
                "store_id": "2",
                "canary_pass": 1,
                "canary_passed": 1,
                "passed_count": 14,
                "evaluated_count": 14,
            },
        )
        _, agg_promote = strat.aggregate_evaluate(
            1, [(cp1, res1_pass), (cp2, res2_pass)], []
        )
        self.assertEqual(agg_promote["verdict"], "PROMOTE")
        self.assertEqual(agg_promote["all_canaries_passed"], 1)
        self.assertEqual(strat.last_global_verdict, "PROMOTE")
        consensus_file_r1 = agg_promote["consensus_verdict_path"]
        self.assertTrue(os.path.exists(consensus_file_r1))
        with open(consensus_file_r1, "r", encoding="utf-8") as f:
            c_doc_r1 = json.load(f)
        self.assertEqual(c_doc_r1["verdict"], "PROMOTE")
        self.assertEqual(sorted(c_doc_r1["stores_passed"]), ["1", "2"])

        # Verify Store 1 promotes locally when consensus_verdict.json is PROMOTE
        model = DummyToyCausalLM()
        tokenizer = MagicMock()
        tokenizer.save_pretrained = lambda d: None
        with tempfile.TemporaryDirectory() as tmpdir:
            global_dir = os.path.join(tmpdir, "store-fed-lora-round-1")
            promoted_dir = os.path.join(tmpdir, "store-fed-lora-promoted")
            client = clientapp.FedLoRAClient(
                model=model,
                tokenizer=tokenizer,
                train_dataset=[1, 2, 3],
                output_dir=os.path.join(tmpdir, "local"),
                global_output_dir=global_dir,
                vllm_url="",
                store_id="1",
                mode="federated",
            )
            loss_p, _, metrics_p = client.evaluate(
                [np.ones((4, 4), dtype=np.float32)],
                {
                    "aggregation_mode": "subspace_resid",
                    "lora_alpha": 64,
                    "canary_gate": False,
                    "consensus_verdict_path": consensus_file_r1,
                },
            )
            self.assertEqual(loss_p, 0.0)
            self.assertEqual(metrics_p["consensus_verdict"], "PROMOTE")
            self.assertTrue(
                os.path.exists(os.path.join(promoted_dir, "adapter_config.json"))
            )
            self.assertTrue(
                os.path.exists(os.path.join(global_dir, "adapter_config.json"))
            )

            # Case 2: Store 1 passes 14/14, Store 2 fails 11/14 -> consensus REJECT
            res2_fail = EvaluateRes(
                status=Status(code=Code.OK, message="ok"),
                loss=1.0,
                num_examples=50,
                metrics={
                    "store_id": "2",
                    "canary_pass": 0,
                    "canary_passed": 0,
                    "passed_count": 11,
                    "evaluated_count": 14,
                },
            )
            _, agg_reject = strat.aggregate_evaluate(
                2, [(cp1, res1_pass), (cp2, res2_fail)], []
            )
            self.assertEqual(agg_reject["verdict"], "REJECT")
            self.assertEqual(agg_reject["all_canaries_passed"], 0)
            self.assertEqual(strat.last_global_verdict, "REJECT")
            consensus_file_r2 = agg_reject["consensus_verdict_path"]
            with open(consensus_file_r2, "r", encoding="utf-8") as f:
                c_doc_r2 = json.load(f)
            self.assertEqual(c_doc_r2["verdict"], "REJECT")
            self.assertEqual(c_doc_r2["stores_passed"], ["1"])
            self.assertEqual(c_doc_r2["stores_rejected"], ["2"])

            # Store 1 passes locally, but consensus_verdict.json says REJECT -> Store 1 blocks & rolls back promoted_dir and global_dir!
            loss_r, _, metrics_r = client.evaluate(
                [np.ones((4, 4), dtype=np.float32)],
                {
                    "server_round": 2,
                    "aggregation_mode": "subspace_resid",
                    "lora_alpha": 64,
                    "canary_gate": False,
                    "consensus_verdict_path": consensus_file_r2,
                },
            )
            self.assertEqual(loss_r, 1.0)
            self.assertEqual(metrics_r["consensus_verdict"], "REJECT")
            self.assertEqual(metrics_r["canary_pass"], 0)
            self.assertFalse(os.path.exists(promoted_dir))
            self.assertFalse(os.path.exists(global_dir))

    def test_lazy_eval_zero_pytorch_model_load(self):
        """Verifies evaluate() exports 140-key safetensors + adapter_config.json with 0 calls to initialize_model_and_tokenizer."""
        import struct
        from unittest.mock import patch

        from flwr.common import Context, RecordDict

        with tempfile.TemporaryDirectory() as tmpdir:
            local_dir = os.path.join(tmpdir, "store1-local-adapter")
            global_dir = os.path.join(tmpdir, "store-fed-lora-round-1")
            promoted_dir = os.path.join(tmpdir, "store-fed-lora-promoted")
            candidate_dir = os.path.join(tmpdir, "store-fed-lora-candidate")
            jsonl_path = os.path.join(tmpdir, "train.jsonl")
            with open(jsonl_path, "w", encoding="utf-8") as f:
                f.write(json.dumps({"text": "q -> a"}) + "\n")

            with patch.object(
                clientapp, "initialize_model_and_tokenizer"
            ) as mock_init_model:
                ctx = Context(
                    run_id=1,
                    node_id=1,
                    node_config={"store-id": "1", "vllm-url": ""},
                    state=RecordDict(),
                    run_config={
                        "mode": "federated",
                        "base-model": "google/gemma-4-E2B-it",
                        "lora-r": 16,
                        "lora-alpha": 64,
                        "lora-dropout": 0.1,
                        "dataset-path": jsonl_path,
                    },
                )
                _ = clientapp.client_fn(ctx)
                mock_init_model.assert_not_called()

                lazy_client = clientapp.FedLoraClient(
                    model=None,
                    tokenizer=None,
                    train_dataset=[{"text": "sample"}],
                    output_dir=local_dir,
                    global_output_dir=global_dir,
                    vllm_url="",
                    store_id="1",
                    model_init_kwargs={
                        "model_name": "google/gemma-4-E2B-it",
                        "lora_r": 16,
                        "lora_alpha": 64,
                        "lora_dropout": 0.1,
                    },
                )
                params_70 = [
                    np.full((1536, 16), 0.125, dtype=np.float32) for _ in range(70)
                ]
                loss, num_ex, metrics = lazy_client.evaluate(
                    params_70,
                    {
                        "server_round": 1,
                        "aggregation_mode": "subspace_resid",
                        "lora_alpha": 64,
                        "canary_gate": False,
                        "require_global_consensus": False,
                    },
                )
                mock_init_model.assert_not_called()
                self.assertEqual(loss, 0.0)
                self.assertEqual(num_ex, 1)
                self.assertEqual(metrics["consensus_verdict"], "PROMOTE")

                for target_d in (candidate_dir, global_dir, promoted_dir):
                    st_path = os.path.join(target_d, "adapter_model.safetensors")
                    cfg_path = os.path.join(target_d, "adapter_config.json")
                    self.assertTrue(os.path.exists(st_path))
                    self.assertTrue(os.path.exists(cfg_path))
                    with open(st_path, "rb") as f_st:
                        h_len = struct.unpack("<Q", f_st.read(8))[0]
                        header = json.loads(f_st.read(h_len).decode("utf-8"))
                    tensor_keys = [k for k in header if k != "__metadata__"]
                    lora_a_keys = [k for k in tensor_keys if "lora_A" in k]
                    lora_b_keys = [k for k in tensor_keys if "lora_B" in k]
                    self.assertEqual(len(tensor_keys), 140)
                    self.assertEqual(len(lora_a_keys), 70)
                    self.assertEqual(len(lora_b_keys), 70)
                    with open(cfg_path, "r", encoding="utf-8") as f_cfg:
                        cfg_obj = json.load(f_cfg)
                    self.assertEqual(cfg_obj["target_modules"], ["o_proj", "down_proj"])
                    self.assertEqual(cfg_obj["lora_alpha"], 64)
                    self.assertEqual(cfg_obj["r"], 16)

    def test_b3_openmetrics_exporter_and_structured_logging(self):
        """Verifies v2.1.13 OpenMetrics exporter, cluster_name/scope normalization, zero round label, --reset, and single-line GDC fluent-bit JSON logs."""
        import io

        import observability as obs  # pylint: disable=g-import-not-at-top

        with tempfile.TemporaryDirectory() as tmpdir:
            state_file = os.path.join(tmpdir, "fed_lora_metrics.json")
            prom_file = os.path.join(tmpdir, "fed_lora_metrics.prom")
            log_buf = io.StringIO()

            # 1. Verify update_metrics_state writes valid OpenMetrics with normalized cluster_name & strict scope
            obs.update_metrics_state(
                updates={
                    "current_round": 3,
                    "worker_active": {"fit": 1},
                    "round_loss": {"kl_prox_total": 4.0113, "sft_ce": 3.8501},
                    "lora_b_frobenius_norm": {
                        "local_store": 11.2134,
                        "global_merged": 19.4412,
                    },
                    "canary_pass_ratio": {cat: 1.0 for cat in obs.CANARY_CATEGORIES},
                    "canary_faithfulness_score": 4.86,
                    "canary_promotions_total": {"PROMOTE": 3, "REJECT": 0},
                    "gpu_vram_used_mib": {"0": 83558.4},
                    "vllm_is_sleeping": 0,
                    "supernode_up": 1,
                    "vllm_up": 1,
                },
                store_id="1",
                state_file=state_file,
                prom_file=prom_file,
            )
            self.assertTrue(os.path.exists(prom_file))
            with open(prom_file, "r", encoding="utf-8") as pf:
                prom_txt = pf.read()

            self.assertIn(
                'fed_lora_current_round{scope="store-1",store_id="store-1",cluster_name="YOUR_STORE_1_CLUSTER"} 3',
                prom_txt,
            )
            self.assertIn(
                'fed_lora_round_loss{store_id="store-1",cluster_name="YOUR_STORE_1_CLUSTER",loss_type="kl_prox_total"}'
                " 4.011300",
                prom_txt,
            )
            self.assertIn(
                'fed_lora_lora_b_frobenius_norm{scope="local_store",store_id="store-1",cluster_name="YOUR_STORE_1_CLUSTER"}'
                " 11.213400",
                prom_txt,
            )
            self.assertIn(
                'fed_lora_lora_b_frobenius_norm{scope="global_merged",store_id="store-1",cluster_name="YOUR_STORE_1_CLUSTER"}'
                " 19.441200",
                prom_txt,
            )
            self.assertIn(
                'fed_lora_canary_pass_ratio{scope="store-1",store_id="store-1",cluster_name="YOUR_STORE_1_CLUSTER",category="overall"}'
                " 1.0000",
                prom_txt,
            )
            # Verify ZERO `round="..."` label on continuous time-series gauges (B3-GATE-4)
            self.assertNotIn('round="', prom_txt)
            self.assertNotIn('cluster="', prom_txt)

            # 2. Verify emit_cloud_log produces single-line GDC fluent-bit JSON with string-only labels
            log_line = obs.emit_cloud_log(
                event_type="CLIENT_EVALUATE_COMPLETE",
                message="Store 1 promoted Round 3 global adapter",
                severity="INFO",
                component="flwr-trainer",
                server_round=3,
                store_id="1",
                metrics={"canary_pass_ratio": 1.0, "lora_b_frobenius_norm": 19.4412},
                stream=log_buf,
            )
            self.assertTrue(log_line.endswith("\n"))
            self.assertEqual(len(log_line.strip().splitlines()), 1)
            parsed_log = json.loads(log_line)
            self.assertEqual(parsed_log["severity"], "INFO")
            self.assertEqual(parsed_log["cluster_name"], "YOUR_STORE_1_CLUSTER")
            self.assertEqual(parsed_log["store_id"], "store-1")
            self.assertEqual(parsed_log["scope"], "store-1")
            gcp_labels = parsed_log["logging.googleapis.com/labels"]
            for lk, lv in gcp_labels.items():
                self.assertIsInstance(lk, str)
                self.assertIsInstance(lv, str)
            self.assertEqual(gcp_labels["cluster_name"], "YOUR_STORE_1_CLUSTER")
            self.assertEqual(gcp_labels["server_round"], "3")

            # 3. Verify Stage 1 reset_stage1_metrics zeroes all gauges and logs STAGE1_BASELINE_RESET
            reset_buf = io.StringIO()
            obs.reset_stage1_metrics(
                store_id="global",
                state_file=state_file,
                prom_file=prom_file,
                stream=reset_buf,
            )
            with open(prom_file, "r", encoding="utf-8") as pf:
                reset_prom = pf.read()
            self.assertIn(
                'fed_lora_current_round{scope="fleet-consensus",store_id="global",cluster_name="YOUR_AGGREGATOR_CLUSTER"} 0',
                reset_prom,
            )
            self.assertIn(
                'fed_lora_round_loss{store_id="global",cluster_name="YOUR_AGGREGATOR_CLUSTER",loss_type="kl_prox_total"}'
                " 0.000000",
                reset_prom,
            )
            self.assertIn(
                'fed_lora_canary_pass_ratio{scope="fleet-consensus",store_id="global",cluster_name="YOUR_AGGREGATOR_CLUSTER",category="overall"}'
                " 0.0000",
                reset_prom,
            )
            reset_log = json.loads(reset_buf.getvalue().strip())
            self.assertEqual(reset_log["event_type"], "STAGE1_BASELINE_RESET")
            self.assertEqual(reset_log["cluster_name"], "YOUR_AGGREGATOR_CLUSTER")


if __name__ == "__main__":
    unittest.main()
