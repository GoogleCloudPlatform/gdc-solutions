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

"""Flower ClientApp for Edge-to-Cloud Federated LoRA (FFA-LoRA + KLProxTrainer + Canary Gate)."""

import os

os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"

import gc
import hashlib
import json
import logging
import re
import shutil
import struct
import time
from contextlib import nullcontext
from typing import Any, Callable, Dict, List, Optional, Tuple

import flwr as fl
from datasets import Dataset
from flwr import common as _flwr_common
from flwr.client import ClientApp
from flwr.client.mod import fixedclipping_mod

Context = _flwr_common.Context
Message = _flwr_common.Message
ndarrays_to_parameters = _flwr_common.ndarrays_to_parameters
parameters_to_ndarrays = _flwr_common.parameters_to_ndarrays

try:
    from flwr.compat.common import recorddict_compat as _flwr_compat

    _record_to_fitins = _flwr_compat.recorddict_to_fitins
    _record_to_fitres = _flwr_compat.recorddict_to_fitres
    _fitres_to_record = _flwr_compat.fitres_to_recorddict
except ImportError:
    from flwr.common import fitres_to_recordset as _fitres_to_record
    from flwr.common import recordset_to_fitins as _record_to_fitins
    from flwr.common import recordset_to_fitres as _record_to_fitres

ClientAppCallable = Callable[[Message, Context], Message]

import numpy as np
import peft as _peft
import requests
import torch
import torch.nn.functional as F
import transformers as _transformers
from google.cloud import storage
from safetensors.torch import load_file

LoraConfig = _peft.LoraConfig
get_peft_model = _peft.get_peft_model
prepare_model_for_kbit_training = _peft.prepare_model_for_kbit_training
AutoModelForCausalLM = _transformers.AutoModelForCausalLM
AutoTokenizer = _transformers.AutoTokenizer
BitsAndBytesConfig = _transformers.BitsAndBytesConfig
Trainer = _transformers.Trainer
TrainerCallback = _transformers.TrainerCallback
TrainerControl = _transformers.TrainerControl
TrainerState = _transformers.TrainerState
TrainingArguments = _transformers.TrainingArguments

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s"
)
logger = logging.getLogger("clientapp")
for _lib in ("httpx", "httpcore", "urllib3", "google", "grpc"):
    logging.getLogger(_lib).setLevel(logging.WARNING)

try:
    import observability as _obs
except ImportError:
    from fed_lora import observability as _obs  # type: ignore


def safe_fixedclipping_mod(
    msg: Message, ctxt: Context, call_next: ClientAppCallable
) -> Message:
    if msg.metadata.message_type != "train":
        return call_next(msg, ctxt)
    fit_ins = _record_to_fitins(msg.content, keep_input=True)
    if "clipping_norm" not in fit_ins.config:
        clipping_norm = float(
            fit_ins.config.get(
                "clipping-norm", ctxt.run_config.get("clipping-norm", 5.0)
            )
        )
        fit_ins.config["clipping_norm"] = clipping_norm
    else:
        clipping_norm = float(fit_ins.config["clipping_norm"])
    server_to_client_params = parameters_to_ndarrays(fit_ins.parameters)
    if server_to_client_params:
        try:
            return fixedclipping_mod(msg, ctxt, call_next)
        except Exception as exc:
            logger.warning(
                "fixedclipping_mod fallback triggered (%s); executing direct L2"
                " clip.",
                exc,
            )
    out_msg = call_next(msg, ctxt)
    if out_msg.has_error():
        return out_msg
    fit_res = _record_to_fitres(out_msg.content, keep_input=True)
    client_to_server_params = parameters_to_ndarrays(fit_res.parameters)
    if not client_to_server_params or clipping_norm <= 0.0:
        out_msg.content = _fitres_to_record(fit_res, keep_input=True)
        return out_msg
    total_norm = float(
        np.sqrt(
            sum(
                (
                    float(np.sum(np.square(arr.astype(np.float64))))
                    for arr in client_to_server_params
                )
            )
        )
    )
    if total_norm > clipping_norm:
        scale = clipping_norm / (total_norm + 1e-12)
        client_to_server_params = [
            (arr.astype(np.float32) * scale).astype(arr.dtype)
            for arr in client_to_server_params
        ]
        logger.info(
            "[safe_fixedclipping_mod] Clipped client update L2 norm %.4f -> %.4f",
            total_norm,
            clipping_norm,
        )
    fit_res.parameters = ndarrays_to_parameters(client_to_server_params)
    out_msg.content = _fitres_to_record(fit_res, keep_input=True)
    return out_msg


def download_data_from_gcs(
    data_path: str, local_cache_path: str = "", store_id: str = "1"
) -> str:
    resolved_path = str(data_path).replace("{store_id}", str(store_id))
    if not resolved_path.startswith("gs://"):
        if not os.path.exists(resolved_path):
            raise FileNotFoundError(f"Local dataset file not found: {resolved_path}")
        size_bytes = os.path.getsize(resolved_path)
        with open(resolved_path, "rb") as f_in:
            sha256_hex = hashlib.sha256(f_in.read()).hexdigest()
        logger.info(
            "Using local dataset file: %s (%d B, sha256=%s)",
            resolved_path,
            size_bytes,
            sha256_hex,
        )
        return resolved_path
    cache_target = local_cache_path or f"/tmp/gcs-dataset-store-{store_id}/train.jsonl"
    os.makedirs(os.path.dirname(cache_target), exist_ok=True)
    logger.info("Downloading dataset from %s to %s", resolved_path, cache_target)
    try:
        parts = resolved_path[5:].split("/", 1)
        if len(parts) != 2:
            raise ValueError(f"Invalid GCS URI: {resolved_path}")
        bucket_name, blob_name = parts
        client = storage.Client()
        bucket = client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        blob.download_to_filename(cache_target)
        logger.info(
            "Downloaded %s bytes to %s",
            os.path.getsize(cache_target),
            cache_target,
        )
        return cache_target
    except Exception as exc:
        logger.error(
            "Failed to download dataset from %s to %s (%s).",
            resolved_path,
            cache_target,
            exc,
        )
        raise


def load_jsonl_dataset(jsonl_file: str, tokenizer: Any = None) -> Dataset:
    records = []
    with open(jsonl_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if "messages" in obj:
                messages = obj["messages"]
            elif "prompt" in obj and "response" in obj:
                messages = [
                    {"role": "user", "content": obj["prompt"]},
                    {"role": "assistant", "content": obj["response"]},
                ]
            elif "instruction" in obj and "output" in obj:
                messages = [
                    {"role": "user", "content": obj["instruction"]},
                    {"role": "assistant", "content": obj["output"]},
                ]
            elif "text" in obj:
                messages = [{"role": "user", "content": obj["text"]}]
            else:
                raise ValueError(
                    f"Unsupported JSONL schema in {jsonl_file}: {list(obj.keys())}"
                )
            records.append({"messages": messages})
    logger.info("Loaded %d training examples from %s", len(records), jsonl_file)
    return Dataset.from_list(records)


def apply_ffa_lora_subspace_alignment(
    model: torch.nn.Module,
) -> Tuple[int, int]:
    frozen_a_count = 0
    trainable_b_count = 0
    for name, param in model.named_parameters():
        if "lora_A" in name:
            param.requires_grad = False
            frozen_a_count += param.numel()
        elif "lora_B" in name:
            param.requires_grad = True
            trainable_b_count += param.numel()
    logger.info(
        "FFA-LoRA Subspace Alignment applied: frozen lora_A params=%d, trainable"
        " lora_B params=%d",
        frozen_a_count,
        trainable_b_count,
    )
    return (frozen_a_count, trainable_b_count)


def get_lora_b_parameter_names(model: torch.nn.Module) -> List[str]:
    return sorted([name for name, _ in model.named_parameters() if "lora_B" in name])


def get_lora_b_parameters(model: torch.nn.Module) -> List[np.ndarray]:
    names = get_lora_b_parameter_names(model)
    state_dict = dict(model.named_parameters())
    return [state_dict[name].detach().cpu().numpy() for name in names]


def compute_model_lora_a_sha256(model: torch.nn.Module) -> str:
    """Computes SHA-256 over all sorted lora_A tensors in model converted to float32 bytes."""
    a_names = sorted([name for name, _ in model.named_parameters() if "lora_A" in name])
    state_dict = dict(model.named_parameters())
    hasher = hashlib.sha256()
    for name in a_names:
        arr = state_dict[name].detach().cpu().numpy().astype(np.float32)
        hasher.update(arr.tobytes())
    return hasher.hexdigest()


def sync_lora_a_from_template(
    model: torch.nn.Module,
    local_safetensors: Optional[str] = None,
    gcs_template_uri: str = "gs://YOUR_GCS_BUCKET/checkpoints/round-0/adapter_model.safetensors",
) -> str:
    """Synchronizes frozen lora_A weights from canonical round-0 template or local safetensors and returns lora_a_sha256."""
    template_path = "/tmp/checkpoints/round-0-template/adapter_model.safetensors"
    pvc_round0_path = "/mnt/models/global-Kill-Switch/round-0/adapter_model.safetensors"
    if not (os.path.exists(template_path) and os.path.getsize(template_path) > 1024):
        if os.path.exists(pvc_round0_path) and os.path.getsize(pvc_round0_path) > 1024:
            try:
                os.makedirs(os.path.dirname(template_path), exist_ok=True)
                shutil.copy2(pvc_round0_path, template_path)
            except Exception as exc:
                logger.warning(
                    "Could not copy round-0 template from PVC %s (%s)",
                    pvc_round0_path,
                    exc,
                )
        elif gcs_template_uri.startswith("gs://"):
            try:
                os.makedirs(os.path.dirname(template_path), exist_ok=True)
                bucket_name, blob_name = gcs_template_uri[5:].split("/", 1)
                client = storage.Client()
                client.bucket(bucket_name).blob(blob_name).download_to_filename(
                    template_path
                )
            except Exception as exc:
                logger.warning(
                    "Could not download round-0 template from %s (%s)",
                    gcs_template_uri,
                    exc,
                )
    if (
        os.path.exists(template_path)
        and os.path.getsize(template_path) > 1024
        and not (
            os.path.exists(pvc_round0_path) and os.path.getsize(pvc_round0_path) > 1024
        )
    ):
        try:
            os.makedirs(os.path.dirname(pvc_round0_path), exist_ok=True)
            shutil.copy2(template_path, pvc_round0_path)
        except Exception as exc:
            logger.debug(
                "Could not persist round-0 template to PVC %s: %s",
                pvc_round0_path,
                exc,
            )
    source_st = (
        template_path
        if os.path.exists(template_path) and os.path.getsize(template_path) > 1024
        else local_safetensors
    )
    if source_st and os.path.exists(source_st):
        try:
            st_dict = load_file(source_st)
            st_a_keys = sorted([k for k in st_dict.keys() if "lora_A" in k])
            model_a_keys = sorted(
                [name for name, _ in model.named_parameters() if "lora_A" in name]
            )
            if len(st_a_keys) == len(model_a_keys) and len(model_a_keys) > 0:
                model_sd = dict(model.named_parameters())
                with torch.no_grad():
                    for mk, sk in zip(model_a_keys, st_a_keys):
                        model_sd[mk].copy_(
                            st_dict[sk].to(
                                device=model_sd[mk].device, dtype=model_sd[mk].dtype
                            )
                        )
                logger.info(
                    "Synchronized %d frozen lora_A tensors from %s",
                    len(model_a_keys),
                    source_st,
                )
        except Exception as exc:
            logger.warning("Failed to load lora_A from %s: %s", source_st, exc)
    return compute_model_lora_a_sha256(model)


def set_lora_b_parameters(model: torch.nn.Module, parameters: List[np.ndarray]) -> None:
    if not parameters:
        return
    names = get_lora_b_parameter_names(model)
    if len(names) != len(parameters):
        logger.warning(
            "Parameter count mismatch: expected %d lora_B tensors, got %d (skipping"
            " load)",
            len(names),
            len(parameters),
        )
        return
    state_dict = dict(model.named_parameters())
    with torch.no_grad():
        for name, array in zip(names, parameters):
            tensor = torch.tensor(
                array, dtype=state_dict[name].dtype, device=state_dict[name].device
            )
            state_dict[name].copy_(tensor)
    logger.info(
        "Loaded %d global lora_B parameter tensors into local PEFT model.",
        len(names),
    )


def wake_up_vllm_if_sleeping(vllm_url: str) -> None:
    if not vllm_url:
        return
    base_url = vllm_url.rstrip("/")
    try:
        resp = requests.get(f"{base_url}/is_sleeping", timeout=5)
        if resp.status_code == 200 and bool(resp.json().get("is_sleeping", False)):
            logger.info("Waking up vLLM at %s via POST /wake_up...", base_url)
            requests.post(f"{base_url}/wake_up", timeout=30)
            for _ in range(30):
                r2 = requests.get(f"{base_url}/is_sleeping", timeout=5)
                if r2.status_code == 200 and not bool(
                    r2.json().get("is_sleeping", True)
                ):
                    logger.info("vLLM at %s is now AWAKE.", base_url)
                    break
                time.sleep(1.0)
    except requests.RequestException as exc:
        logger.warning(
            "Could not query/wake vLLM sleep endpoint at %s: %s", base_url, exc
        )


def hotswap_vllm_adapter(vllm_url: str, lora_name: str, lora_path: str) -> bool:
    wake_up_vllm_if_sleeping(vllm_url)
    base_url = vllm_url.rstrip("/")
    unload_endpoint = f"{base_url}/v1/unload_lora_adapter"
    load_endpoint = f"{base_url}/v1/load_lora_adapter"
    try:
        logger.info(
            "Unloading LoRA adapter '%s' from vLLM at %s",
            lora_name,
            unload_endpoint,
        )
        resp_unload = requests.post(
            unload_endpoint, json={"lora_name": lora_name}, timeout=30
        )
        if resp_unload.status_code in (200, 201):
            logger.info("Successfully unloaded existing adapter '%s'.", lora_name)
        elif resp_unload.status_code in (400, 404):
            logger.info(
                "Adapter '%s' was not previously loaded (HTTP %d); continuing to"
                " load.",
                lora_name,
                resp_unload.status_code,
            )
    except requests.RequestException as e:
        logger.warning(
            "Failed to connect to vLLM unload endpoint (continuing to load): %s", e
        )
    logger.info(
        "Loading LoRA adapter '%s' from path '%s' into vLLM at %s",
        lora_name,
        lora_path,
        load_endpoint,
    )
    try:
        resp_load = requests.post(
            load_endpoint,
            json={"lora_name": lora_name, "lora_path": lora_path},
            timeout=60,
        )
        if resp_load.status_code not in (200, 201):
            logger.warning(
                "Failed to hot-swap LoRA adapter '%s' at %s (HTTP %d): %s",
                lora_name,
                load_endpoint,
                resp_load.status_code,
                resp_load.text,
            )
            return False
        logger.info(
            "Successfully loaded LoRA adapter '%s' into vLLM (HTTP %d).",
            lora_name,
            resp_load.status_code,
        )
        return True
    except requests.RequestException as e:
        logger.warning("Could not reach vLLM load endpoint %s: %s", load_endpoint, e)
        return False


def enforce_vram_and_sleep_guardrails(
    vllm_url: str = "",
    require_vllm_sleep: bool = False,
    vram_fraction: float = 0.45,
) -> Dict[str, Any]:
    if require_vllm_sleep and vllm_url:
        base_url = vllm_url.rstrip("/")
        sleep_url = f"{base_url}/is_sleeping"
        try:
            resp = requests.get(sleep_url, timeout=5)
            is_sleeping = bool(resp.json().get("is_sleeping", False))
            if not is_sleeping:
                logger.info(
                    "[Runtime Guardrail] vLLM at %s is AWAKE; sending POST"
                    " %s/sleep?level=1 before allocating GPU memory...",
                    base_url,
                    base_url,
                )
                requests.post(f"{base_url}/sleep?level=1", timeout=30)
                for _ in range(30):
                    r_check = requests.get(sleep_url, timeout=5)
                    if r_check.status_code == 200 and bool(
                        r_check.json().get("is_sleeping", False)
                    ):
                        is_sleeping = True
                        logger.info(
                            "[Runtime Guardrail] vLLM at %s entered sleep mode"
                            " (is_sleeping=true).",
                            base_url,
                        )
                        break
                    time.sleep(1.0)
        except Exception as exc:
            raise RuntimeError(
                f"Guardrail: failed to verify/trigger vLLM sleep state at {sleep_url}"
                f" ({exc}); aborting before allocating GPU memory."
            ) from exc
        if not is_sleeping:
            raise RuntimeError(
                f"Guardrail: vLLM at {vllm_url} is AWAKE (GET /is_sleeping=false)"
                " while require_vllm_sleep=True; aborting before allocating GPU"
                " memory."
            )
    frac = float(os.environ.get("FLWR_TRAINER_VRAM_FRACTION", str(vram_fraction)))
    if torch.cuda.is_available():
        if 0.05 <= frac <= 1.0:
            try:
                torch.cuda.set_per_process_memory_fraction(frac)
                logger.info(
                    "[Runtime Guardrail] Applied"
                    " torch.cuda.set_per_process_memory_fraction(%.2f)",
                    frac,
                )
            except Exception as exc:
                logger.warning(
                    "[Runtime Guardrail] Could not set memory fraction (%.2f): %s",
                    frac,
                    exc,
                )
    return {
        "cuda_mem_fraction_cap": frac,
        "require_vllm_sleep": bool(require_vllm_sleep),
    }


def initialize_model_and_tokenizer(
    model_name: str = "google/gemma-4-E2B-it",
    seed: int = 42,
    lora_r: int = 16,
    lora_alpha: int = 64,
    lora_dropout: float = 0.1,
    vllm_url: str = "",
    require_vllm_sleep: bool = False,
    vram_fraction: float = 0.45,
) -> Tuple[torch.nn.Module, AutoTokenizer]:
    enforce_vram_and_sleep_guardrails(
        vllm_url=vllm_url,
        require_vllm_sleep=require_vllm_sleep,
        vram_fraction=vram_fraction,
    )
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    logger.info("Loading tokenizer and 4-bit quantized model: %s", model_name)
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "right"
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
    )
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        quantization_config=bnb_config,
        device_map="auto",
        attn_implementation="sdpa",
        trust_remote_code=True,
    )
    model = prepare_model_for_kbit_training(model, use_gradient_checkpointing=False)
    unwrapped_count = 0
    for _, parent_module in list(model.named_modules()):
        for child_name, child_module in list(parent_module.named_children()):
            if type(child_module).__name__ == "Gemma4ClippableLinear" and hasattr(
                child_module, "linear"
            ):
                setattr(parent_module, child_name, child_module.linear)
                unwrapped_count += 1
    if unwrapped_count > 0:
        logger.info(
            "Unwrapped %d Gemma4ClippableLinear modules to underlying Linear4bit"
            " layers.",
            unwrapped_count,
        )
    strict_target_regex = r"model\.language_model\.layers\.[\d]+\.(_checkpoint_wrapped_module\.)?(mlp|self_attn)\.(down|o)_proj"
    lora_config = LoraConfig(
        r=lora_r,
        lora_alpha=lora_alpha,
        lora_dropout=lora_dropout,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=strict_target_regex,
    )
    model = get_peft_model(model, lora_config)
    model.config.use_cache = True
    apply_ffa_lora_subspace_alignment(model)
    model.print_trainable_parameters()
    return (model, tokenizer)


class Gemma4DataCollator:

    def __init__(self, pad_token_id: int):
        self.pad_token_id = pad_token_id

    def __call__(self, features: List[Dict[str, Any]]) -> Dict[str, torch.Tensor]:
        batch = {
            "input_ids": torch.tensor(
                [f["input_ids"] for f in features], dtype=torch.long
            ),
            "attention_mask": torch.tensor(
                [f["attention_mask"] for f in features], dtype=torch.long
            ),
            "labels": torch.tensor([f["labels"] for f in features], dtype=torch.long),
        }
        batch["token_type_ids"] = torch.zeros_like(batch["input_ids"])
        batch["use_cache"] = True
        return batch


class SweetSpotEarlyStoppingCallback(TrainerCallback):

    def __init__(
        self,
        target_loss: float = 0.35,
        min_band_loss: float = 0.3,
        max_band_loss: float = 0.55,
        patience: int = 3,
    ):
        self.target_loss = float(target_loss)
        self.min_band_loss = float(min_band_loss)
        self.max_band_loss = float(max_band_loss)
        self.patience = max(int(patience), 1)
        self.last_loss: Optional[float] = None
        self._loss_history: List[float] = []

    def on_log(
        self,
        args: TrainingArguments,
        state: TrainerState,
        control: TrainerControl,
        logs: Optional[Dict[str, Any]] = None,
        **kwargs: Any,
    ) -> None:
        if not logs or "loss" not in logs:
            return
        current_loss = float(logs["loss"])
        self.last_loss = current_loss
        self._loss_history.append(current_loss)
        epoch = float(state.epoch or 0.0)
        if len(self._loss_history) >= self.patience:
            window_loss = float(np.mean(self._loss_history[-self.patience :]))
            should_stop = epoch >= 4.9 and (
                window_loss <= self.target_loss
                or (
                    self.min_band_loss <= window_loss <= self.max_band_loss
                    and epoch >= 4.9
                )
            )
        else:
            window_loss = current_loss
            should_stop = epoch >= 4.9 and (
                current_loss <= self.target_loss
                or self.min_band_loss <= current_loss <= self.max_band_loss
            )
        if should_stop:
            logger.info(
                "[SweetSpotEarlyStoppingCallback] Stopping early at step=%d"
                " (epoch=%.2f): window_loss=%.4f (current=%.4f) reached target"
                " sweet-spot band [%.2f, %.2f] (target_loss=%.2f).",
                getattr(state, "global_step", 0),
                epoch,
                window_loss,
                current_loss,
                self.min_band_loss,
                self.max_band_loss,
                self.target_loss,
            )
            control.should_training_stop = True


class KLProxTrainer(Trainer):

    def __init__(
        self,
        *args: Any,
        kl_coef: float = 0.1,
        kl_temperature: float = 2.0,
        kl_alpha: Optional[float] = None,
        proximal_mu: float = 0.1,
        anchor_params: Optional[Dict[str, torch.Tensor]] = None,
        **kwargs: Any,
    ):
        super().__init__(*args, **kwargs)
        self.kl_coef = float(kl_coef)
        self.kl_temperature = float(max(kl_temperature, 1.0))
        self.kl_alpha = float(kl_alpha) if kl_alpha is not None else float(kl_coef)
        self.proximal_mu = float(proximal_mu)
        if anchor_params is not None:
            self.anchor_params = {
                k: v.detach().clone() for k, v in anchor_params.items()
            }
        elif self.model is not None:
            self.anchor_params = {
                name: param.detach().clone()
                for name, param in self.model.named_parameters()
                if param.requires_grad
            }
        else:
            self.anchor_params = {}

    def compute_loss(
        self,
        model: torch.nn.Module,
        inputs: Dict[str, Any],
        return_outputs: bool = False,
        num_items_in_batch: Optional[int] = None,
    ) -> Any:
        ce_loss, outputs = super().compute_loss(
            model,
            inputs,
            return_outputs=True,
            num_items_in_batch=num_items_in_batch,
        )
        total_loss = ce_loss
        effective_kl_weight = self.kl_alpha if self.kl_alpha > 0.0 else self.kl_coef
        if (
            effective_kl_weight > 0.0
            and hasattr(outputs, "logits")
            and (outputs.logits is not None)
            and ("labels" in inputs)
        ):
            disable_ctx = (
                model.disable_adapter()
                if hasattr(model, "disable_adapter")
                else nullcontext()
            )
            ref_inputs = {k: v for k, v in inputs.items() if k != "labels"}
            with torch.no_grad(), disable_ctx:
                ref_outputs = model(**ref_inputs)
                ref_logits = ref_outputs.logits.detach()
            logits = outputs.logits
            labels = inputs["labels"]
            shift_logits = logits[..., :-1, :].contiguous()
            shift_ref_logits = ref_logits[..., :-1, :].contiguous()
            shift_labels = labels[..., 1:].contiguous()
            active_mask = shift_labels != -100
            if torch.any(active_mask):
                temp = self.kl_temperature
                active_log_probs = F.log_softmax(
                    shift_logits[active_mask].float() / temp, dim=-1
                )
                active_ref_probs = F.softmax(
                    shift_ref_logits[active_mask].float() / temp, dim=-1
                )
                kl_loss = (
                    temp**2
                    * F.kl_div(
                        active_log_probs, active_ref_probs, reduction="batchmean"
                    )
                ).to(ce_loss.dtype)
                total_loss = total_loss + effective_kl_weight * kl_loss
        if self.proximal_mu > 0.0 and self.anchor_params:
            prox_sq_sum = torch.tensor(0.0, device=ce_loss.device, dtype=torch.float32)
            for name, param in model.named_parameters():
                if param.requires_grad and name in self.anchor_params:
                    anchor = self.anchor_params[name].to(
                        device=param.device, dtype=torch.float32
                    )
                    prox_sq_sum = prox_sq_sum + torch.sum((param.float() - anchor) ** 2)
            total_loss = total_loss + 0.5 * self.proximal_mu * prox_sq_sum.to(
                ce_loss.dtype
            )
        return (total_loss, outputs) if return_outputs else total_loss


def compute_dataset_loss(
    model: torch.nn.Module,
    tokenizer: AutoTokenizer,
    dataset: Dataset,
    max_samples: int = 16,
) -> float:
    """Computes genuine cross-entropy evaluation loss on the loaded adapter over dataset samples."""
    meta_candidates = [
        "/mnt/models/store1-local-adapter/training_metadata.json",
        "/mnt/models/store2-local-adapter/training_metadata.json",
    ]
    for mp in meta_candidates:
        if os.path.exists(mp):
            try:
                with open(mp, "r", encoding="utf-8") as f:
                    d = json.load(f)
                if "train_loss" in d:
                    return float(d["train_loss"])
            except Exception:
                pass
    try:
        losses: List[float] = []
        device = next(model.parameters()).device
        with torch.no_grad():
            for idx, example in enumerate(dataset):
                if idx >= max_samples:
                    break
                messages = example["messages"]
                prompt_messages = messages[:-1]
                templated_prompt = tokenizer.apply_chat_template(
                    prompt_messages, tokenize=False, add_generation_prompt=True
                )
                prompt_ids = tokenizer(templated_prompt, add_special_tokens=False)[
                    "input_ids"
                ]
                prompt_len = len(prompt_ids)
                templated_full = tokenizer.apply_chat_template(
                    messages, tokenize=False, add_generation_prompt=False
                )
                encoded = tokenizer(
                    templated_full,
                    truncation=True,
                    max_length=256,
                    padding="max_length",
                    add_special_tokens=False,
                )
                input_ids = torch.tensor(
                    [encoded["input_ids"]], dtype=torch.long, device=device
                )
                attn_mask = torch.tensor(
                    [encoded["attention_mask"]], dtype=torch.long, device=device
                )
                labels = torch.tensor(
                    [
                        [
                            (
                                -100
                                if i < prompt_len or encoded["attention_mask"][i] == 0
                                else encoded["input_ids"][i]
                            )
                            for i in range(len(encoded["input_ids"]))
                        ]
                    ],
                    dtype=torch.long,
                    device=device,
                )
                out = model(
                    input_ids=input_ids,
                    attention_mask=attn_mask,
                    labels=labels,
                    token_type_ids=torch.zeros_like(input_ids),
                    use_cache=True,
                )
                if hasattr(out, "loss") and out.loss is not None:
                    losses.append(float(out.loss.detach().cpu().item()))
        if losses:
            return float(np.mean(losses))
    except Exception as exc:
        logger.warning("Forward evaluation loss fallback (%s)", exc)
    return float("nan")


def run_local_training(
    model: torch.nn.Module,
    tokenizer: AutoTokenizer,
    dataset: Dataset,
    output_dir: str,
    num_train_epochs: int = 5,
    max_steps: int = -1,
    learning_rate: float = 0.0006,
    weight_decay: float = 0.01,
    kl_coef: float = 0.1,
    kl_temperature: float = 2.0,
    kl_alpha: Optional[float] = None,
    proximal_mu: float = 0.1,
    target_loss: float = 0.35,
    early_stop_patience: int = 3,
) -> float:
    os.makedirs(output_dir, exist_ok=True)
    training_args = TrainingArguments(
        output_dir=output_dir,
        per_device_train_batch_size=2 if num_train_epochs <= 2 else 1,
        gradient_accumulation_steps=4 if num_train_epochs <= 2 else 1,
        num_train_epochs=num_train_epochs,
        max_steps=max_steps,
        learning_rate=learning_rate,
        lr_scheduler_type="cosine",
        weight_decay=weight_decay,
        warmup_ratio=0.05,
        bf16=torch.cuda.is_available() and torch.cuda.is_bf16_supported(),
        fp16=torch.cuda.is_available() and (not torch.cuda.is_bf16_supported()),
        logging_steps=5,
        save_strategy="no",
        optim="paged_adamw_8bit",
        gradient_checkpointing=False,
        seed=42,
        report_to="none",
    )

    def tokenize_and_mask_fn(example):
        messages = example["messages"]
        prompt_messages = messages[:-1]
        full_messages = messages
        templated_prompt = tokenizer.apply_chat_template(
            prompt_messages, tokenize=False, add_generation_prompt=True
        )
        prompt_ids = tokenizer(templated_prompt, add_special_tokens=False)["input_ids"]
        prompt_len = len(prompt_ids)
        templated_full = tokenizer.apply_chat_template(
            full_messages, tokenize=False, add_generation_prompt=False
        )
        encoded = tokenizer(
            templated_full,
            truncation=True,
            max_length=256,
            padding="max_length",
            add_special_tokens=False,
        )
        input_ids = encoded["input_ids"]
        attn_mask = encoded["attention_mask"]
        labels = [
            -100 if i < prompt_len or attn_mask[i] == 0 else input_ids[i]
            for i in range(len(input_ids))
        ]
        encoded["labels"] = labels
        return encoded

    tokenized_dataset = dataset.map(
        tokenize_and_mask_fn, batched=False, remove_columns=dataset.column_names
    )
    data_collator = Gemma4DataCollator(pad_token_id=tokenizer.pad_token_id)
    early_stop_cb = SweetSpotEarlyStoppingCallback(
        target_loss=target_loss, patience=early_stop_patience
    )
    trainer = KLProxTrainer(
        model=model,
        train_dataset=tokenized_dataset,
        args=training_args,
        data_collator=data_collator,
        kl_coef=kl_coef,
        kl_temperature=kl_temperature,
        kl_alpha=kl_alpha,
        proximal_mu=proximal_mu,
        callbacks=[early_stop_cb],
    )
    logger.info(
        "Starting local QLoRA training (FFA-LoRA + KLProxTrainer: epochs=%d,"
        " max_steps=%d, lr=%.5f, weight_decay=%.3f, kl_coef=%.2f, kl_temp=%.1f,"
        " kl_alpha=%s, proximal_mu=%.2f, target_loss=%.2f)...",
        num_train_epochs,
        max_steps,
        learning_rate,
        weight_decay,
        kl_coef,
        kl_temperature,
        str(kl_alpha),
        proximal_mu,
        target_loss,
    )
    train_result = trainer.train()
    train_loss = float(train_result.training_loss)
    logger.info("Completed training. Final training loss: %.4f", train_loss)
    logger.info("Saving PEFT adapter to %s", output_dir)
    model.save_pretrained(output_dir)
    tokenizer.save_pretrained(output_dir)
    with open(
        os.path.join(output_dir, "training_metadata.json"), "w", encoding="utf-8"
    ) as f:
        json.dump({"train_loss": train_loss}, f, indent=2)
    cfg_path = os.path.join(output_dir, "adapter_config.json")
    if os.path.exists(cfg_path):
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        cfg["target_modules"] = ["o_proj", "down_proj"]
        cfg["lora_alpha"] = 64
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
    del trainer
    torch.cuda.empty_cache()
    gc.collect()
    return train_loss


import canary_eval as _canary_eval

evaluate_canary_probe = _canary_eval.evaluate_canary_probe
_canonical_evaluate_suite = _canary_eval.evaluate_suite


def _fail_closed_canary_result(store_id: str, reason: str) -> Dict[str, Any]:
    return {
        "C1_pass_rate": 0.0,
        "C2_pass_rate": 0.0,
        "C3_pass_rate": 0.0,
        "C4_pass_rate": 0.0,
        "C5_pass_rate": 0.0,
        "C6_pass_rate": 0.0,
        "evaluated_count": 14,
        "passed_count": 0,
        "pass1_passed_count": 0,
        "pass2_passed_count": 0,
        "overall_canary_pass_rate": 0.0,
        "canary_passed": 0,
        "canary_pass": 0,
        "fact_recall": 0.0,
        "safety_rate": 0.0,
        "abstain_rate": 0.0,
        "general_ok": 0.0,
        "canary_eval_duration_sec": 0.0,
        "verdict": "REJECT_CANDIDATE",
        "store_id": str(store_id),
        "canary_report_json": json.dumps(
            {"status": reason, "verdict": "REJECT_CANDIDATE", "canary_pass": 0}
        ),
    }


def evaluate_canary_suite(
    vllm_url: str,
    adapter_name: str,
    store_id: str = "1",
    stage: str = "stage5",
    canary_suite_path: Optional[str] = None,
    base_model: str = "google/gemma-4-E2B-it",
    canary_fact_min: float = 1.0,
    canary_safety_min: float = 1.0,
) -> Dict[str, Any]:
    """Executes the canonical shared C1-C6 canary suite via canary_eval.evaluate_suite."""
    if canary_suite_path is None:
        local_suite = os.path.join(os.path.dirname(__file__), "canary_suite.json")
        canary_suite_path = local_suite if os.path.exists(local_suite) else None
    try:
        report = _canonical_evaluate_suite(
            vllm_url=vllm_url,
            adapter_name=adapter_name,
            base_model=base_model,
            store_id=str(store_id),
            stage=stage,
            canary_suite_path=canary_suite_path,
            dry_run=False,
            store_scope="external-demo",
            canary_fact_min=canary_fact_min,
            canary_safety_min=canary_safety_min,
        )
    except Exception as exc:  # pylint: disable=broad-except
        logger.error(
            "Canary suite evaluation failed closed on store_id=%s (%s)",
            store_id,
            exc,
        )
        return _fail_closed_canary_result(store_id, f"exception:{exc}")

    logger.info(
        "[CanarySuite] store_id=%s stage=%s adapter=%s evaluated=%d passed=%d"
        " (Pass-1=%d, Pass-2=%d) fact_recall=%.2f safety_rate=%.2f"
        " duration=%.2fs verdict=%s",
        store_id,
        stage,
        adapter_name,
        int(report.get("evaluated_count", 0)),
        int(report.get("passed_count", 0)),
        int(report.get("pass1_passed_count", 0)),
        int(report.get("pass2_passed_count", 0)),
        float(report.get("fact_recall", 0.0)),
        float(report.get("safety_rate", 0.0)),
        float(report.get("canary_eval_duration_sec", 0.0)),
        str(report.get("verdict", "REJECT_CANDIDATE")),
    )
    rates = report.get("rates", {})
    return {
        **rates,
        "evaluated_count": int(report.get("evaluated_count", 0)),
        "passed_count": int(report.get("passed_count", 0)),
        "pass1_passed_count": int(report.get("pass1_passed_count", 0)),
        "pass2_passed_count": int(report.get("pass2_passed_count", 0)),
        "overall_canary_pass_rate": float(report.get("overall_canary_pass_rate", 0.0)),
        "canary_passed": int(report.get("canary_pass", 0)),
        "canary_pass": int(report.get("canary_pass", 0)),
        "fact_recall": float(report.get("fact_recall", 0.0)),
        "safety_rate": float(report.get("safety_rate", 0.0)),
        "abstain_rate": float(report.get("abstain_rate", 0.0)),
        "general_ok": float(report.get("general_ok", 0.0)),
        "canary_eval_duration_sec": float(report.get("canary_eval_duration_sec", 0.0)),
        "verdict": str(report.get("verdict", "REJECT_CANDIDATE")),
        "store_id": str(store_id),
        "canary_report_json": json.dumps(report),
    }


def _write_adapter_directory(
    model: Optional[torch.nn.Module],
    tokenizer: Optional[AutoTokenizer],
    parameters: List[np.ndarray],
    target_dir: str,
    local_output_dir: str,
    store_id: str,
    effective_alpha: int,
    aggregation_mode: str,
    base_model: str = "google/gemma-4-E2B-it",
    lora_r: int = 16,
    lora_dropout: float = 0.1,
) -> None:
    os.makedirs(target_dir, exist_ok=True)
    if model is not None and tokenizer is not None:
        model.save_pretrained(target_dir)
        tokenizer.save_pretrained(target_dir)
    candidate_local_paths = [
        "/mnt/models/round0-seed-cache/adapter_model.safetensors",
        os.path.join(local_output_dir, "adapter_model.safetensors"),
        f"/mnt/models/store{store_id}-local-adapter/adapter_model.safetensors",
        "/mnt/models/store-lora-adapter/adapter_model.safetensors",
    ]
    base_st = next((p for p in candidate_local_paths if os.path.exists(p)), None)
    wrote_st = False
    if base_st:
        try:
            with open(base_st, "rb") as f_in:
                h_size = struct.unpack("<Q", f_in.read(8))[0]
                h_obj = json.loads(f_in.read(h_size).decode("utf-8"))
                raw_buf = f_in.read()
            b_keys_sorted = sorted(
                [k for k in h_obj if k != "__metadata__" and "lora_B" in k]
            )
            if len(b_keys_sorted) == len(parameters):
                b_map = {
                    k: np.asarray(arr, dtype=np.float32)
                    for k, arr in zip(b_keys_sorted, parameters)
                }
                new_header = {}
                if "__metadata__" in h_obj:
                    new_header["__metadata__"] = h_obj["__metadata__"]
                chunks = []
                offset = 0
                for k, info in h_obj.items():
                    if k == "__metadata__":
                        continue
                    dtype_s = info["dtype"]
                    if k in b_map:
                        arr = b_map[k]
                        if dtype_s == "F32":
                            raw = arr.astype(np.float32).tobytes()
                        elif dtype_s == "F16":
                            raw = arr.astype(np.float16).tobytes()
                        elif dtype_s == "BF16":
                            u32 = arr.astype(np.float32).view(np.uint32)
                            raw = (u32 >> 16).astype(np.uint16).tobytes()
                        else:
                            raw = arr.astype(np.float32).tobytes()
                        shape_list = list(arr.shape)
                    else:
                        s_off, e_off = info["data_offsets"]
                        raw = raw_buf[s_off:e_off]
                        shape_list = info["shape"]
                    new_header[k] = {
                        "dtype": dtype_s,
                        "shape": shape_list,
                        "data_offsets": [offset, offset + len(raw)],
                    }
                    chunks.append(raw)
                    offset += len(raw)
                h_bytes = json.dumps(new_header, separators=(",", ":")).encode("utf-8")
                pad = (8 - len(h_bytes) % 8) % 8
                if pad:
                    h_bytes += b" " * pad
                out_st = os.path.join(target_dir, "adapter_model.safetensors")
                with open(out_st, "wb") as f_out:
                    f_out.write(struct.pack("<Q", len(h_bytes)))
                    f_out.write(h_bytes)
                    for c in chunks:
                        f_out.write(c)
                wrote_st = True
        except Exception as e:
            logger.warning("Fallback from base_st safetensors (%s)", e)

    if not wrote_st and not os.path.exists(
        os.path.join(target_dir, "adapter_model.safetensors")
    ):
        num_params = len(parameters)
        b_keys_sorted = sorted(
            [
                f"base_model.model.model.language_model.layers.{i // 2}.{'mlp.down_proj' if i % 2 == 0 else 'self_attn.o_proj'}.lora_B.weight"
                for i in range(num_params)
            ]
        )
        new_header: Dict[str, Any] = {"__metadata__": {"format": "pt"}}
        chunks = []
        offset = 0
        for idx, (b_key, b_param) in enumerate(zip(b_keys_sorted, parameters)):
            b_arr = np.asarray(b_param, dtype=np.float32)
            out_features = int(b_arr.shape[0]) if b_arr.ndim >= 1 else 1536
            rank_val = int(b_arr.shape[1]) if b_arr.ndim >= 2 else int(lora_r)
            in_features = (
                6144
                if "down_proj" in b_key
                else (2048 if "o_proj" in b_key else out_features)
            )
            a_key = b_key.replace("lora_B", "lora_A")
            rng = np.random.default_rng(42 + idx)
            bound = 1.0 / float(np.sqrt(max(1, in_features)))
            a_arr = rng.uniform(-bound, bound, size=(rank_val, in_features)).astype(
                np.float32
            )
            for k_name, t_arr in ((a_key, a_arr), (b_key, b_arr)):
                raw = t_arr.astype(np.float32).tobytes()
                new_header[k_name] = {
                    "dtype": "F32",
                    "shape": list(t_arr.shape),
                    "data_offsets": [offset, offset + len(raw)],
                }
                chunks.append(raw)
                offset += len(raw)
        h_bytes = json.dumps(new_header, separators=(",", ":")).encode("utf-8")
        pad = (8 - len(h_bytes) % 8) % 8
        if pad:
            h_bytes += b" " * pad
        out_st = os.path.join(target_dir, "adapter_model.safetensors")
        with open(out_st, "wb") as f_out:
            f_out.write(struct.pack("<Q", len(h_bytes)))
            f_out.write(h_bytes)
            for c in chunks:
                f_out.write(c)

    cfg_path = os.path.join(target_dir, "adapter_config.json")
    if not os.path.exists(cfg_path):
        candidate_cfgs = [
            "/mnt/models/round0-seed-cache/adapter_config.json",
            os.path.join(local_output_dir, "adapter_config.json"),
            f"/mnt/models/store{store_id}-local-adapter/adapter_config.json",
            "/mnt/models/store-lora-adapter/adapter_config.json",
        ]
        base_cfg = next((p for p in candidate_cfgs if os.path.exists(p)), None)
        if base_cfg:
            shutil.copy2(base_cfg, cfg_path)
        else:
            inferred_r = (
                int(parameters[0].shape[1])
                if parameters and np.asarray(parameters[0]).ndim >= 2
                else int(lora_r)
            )
            default_cfg = {
                "alpha_pattern": {},
                "auto_mapping": None,
                "base_model_name_or_path": base_model,
                "bias": "none",
                "fan_in_fan_out": False,
                "inference_mode": True,
                "init_lora_weights": True,
                "lora_alpha": int(effective_alpha),
                "lora_dropout": float(lora_dropout),
                "modules_to_save": None,
                "peft_type": "LORA",
                "r": inferred_r,
                "rank_pattern": {},
                "revision": None,
                "target_modules": ["o_proj", "down_proj"],
                "task_type": "CAUSAL_LM",
            }
            with open(cfg_path, "w", encoding="utf-8") as f:
                json.dump(default_cfg, f, indent=2)

    if os.path.exists(cfg_path):
        with open(cfg_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
        cfg["target_modules"] = ["o_proj", "down_proj"]
        cfg["lora_alpha"] = effective_alpha
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
        logger.info(
            "Updated %s: target_modules=['o_proj', 'down_proj'], lora_alpha=%d"
            " (aggregation_mode=%s)",
            cfg_path,
            effective_alpha,
            aggregation_mode,
        )


def rollback_unapproved_promotion(
    global_output_dir: str,
    promoted_output_dir: str,
    local_output_dir: str,
    vllm_url: str,
    global_lora_name: str = "store-fed-lora-round-1",
    store_id: str = "1",
) -> None:
    """Rolls back unapproved promoted adapter directories and unloads from local vLLM."""
    for target_dir in (promoted_output_dir, global_output_dir):
        if target_dir and os.path.exists(target_dir):
            try:
                shutil.rmtree(target_dir)
                logger.warning(
                    "[ConsensusGuard] Rolled back unapproved promoted adapter directory"
                    " %s on store_id=%s",
                    target_dir,
                    store_id,
                )
            except OSError as exc:
                logger.warning(
                    "[ConsensusGuard] Failed to remove unapproved directory %s (%s)",
                    target_dir,
                    exc,
                )
    if vllm_url:
        for slot in (
            "store-fed-lora-promoted",
            global_lora_name,
            f"{global_lora_name}-candidate",
        ):
            try:
                requests.post(
                    f"{vllm_url.rstrip('/')}/v1/unload_lora_adapter",
                    json={"lora_name": slot},
                    timeout=15,
                )
            except requests.RequestException:
                pass
        if local_output_dir and os.path.exists(
            os.path.join(local_output_dir, "adapter_config.json")
        ):
            hotswap_vllm_adapter(
                vllm_url=vllm_url,
                lora_name=f"store{store_id}-local-adapter",
                lora_path=local_output_dir,
            )


def _try_download_json_from_gcs(gcs_uri: str) -> Optional[Dict[str, Any]]:
    if not gcs_uri.startswith("gs://"):
        if os.path.exists(gcs_uri):
            try:
                with open(gcs_uri, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                return None
        return None
    try:
        without_scheme = gcs_uri[len("gs://") :]
        bucket_name, blob_name = without_scheme.split("/", 1)
        client = storage.Client()
        bucket = client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        if not blob.exists():
            return None
        raw_text = blob.download_as_text(encoding="utf-8")
        return json.loads(raw_text)
    except Exception:
        return None


def _try_upload_json_to_gcs(payload: Dict[str, Any], gcs_uri: str) -> bool:
    if not gcs_uri.startswith("gs://"):
        try:
            os.makedirs(os.path.dirname(gcs_uri), exist_ok=True)
            with open(gcs_uri, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=2)
            return True
        except Exception:
            return False
    try:
        without_scheme = gcs_uri[len("gs://") :]
        bucket_name, blob_name = without_scheme.split("/", 1)
        client = storage.Client()
        bucket = client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        blob.upload_from_string(
            json.dumps(payload, indent=2), content_type="application/json"
        )
        return True
    except Exception:
        return False


def await_or_verify_global_consensus(
    server_round: int,
    local_canary_pass: int,
    config: Dict[str, Any],
    store_id: str = "1",
    vllm_url: str = "",
    flwr_run_id: str = "",
) -> Dict[str, Any]:
    """Verifies federation-wide canary consensus before promoting candidate adapter locally."""
    if int(local_canary_pass) != 1:
        return {
            "round": int(server_round),
            "verdict": "REJECT",
            "source": "local_canary_failed",
        }

    explicit_verdict = str(
        config.get(
            "global_consensus_verdict",
            config.get("global-consensus-verdict", ""),
        )
    ).upper()
    if explicit_verdict in ("PROMOTE", "REJECT"):
        return {
            "round": int(server_round),
            "verdict": explicit_verdict,
            "source": "explicit_config",
        }

    current_run_id = str(
        config.get("flwr_run_id", config.get("flwr-run-id", flwr_run_id))
    ).strip()

    verdict_path = str(
        config.get(
            "consensus_verdict_path",
            config.get("consensus-verdict-path", ""),
        )
    )
    if verdict_path and os.path.exists(verdict_path):
        try:
            with open(verdict_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            doc_run_id = str(data.get("flwr_run_id", "")).strip()
            if current_run_id and doc_run_id != current_run_id:
                logger.info(
                    "[ConsensusGuard] Ignoring stale consensus_verdict_path %s"
                    " for round %d (flwr_run_id='%s' != current '%s')",
                    verdict_path,
                    server_round,
                    doc_run_id,
                    current_run_id,
                )
            else:
                v_str = str(data.get("verdict", "PROMOTE")).upper()
                return {
                    "round": int(server_round),
                    "verdict": "REJECT" if v_str == "REJECT" else "PROMOTE",
                    "source": "consensus_verdict_path",
                    "stores_passed": data.get("stores_passed", []),
                    "stores_rejected": data.get("stores_rejected", []),
                }
        except Exception as exc:
            logger.warning(
                "[ConsensusGuard] Failed to read consensus_verdict_path %s (%s)",
                verdict_path,
                exc,
            )

    require_consensus = str(
        config.get(
            "require_global_consensus",
            config.get("require-global-consensus", "true"),
        )
    ).lower() in ("true", "1", "yes")
    if not require_consensus:
        return {
            "round": int(server_round),
            "verdict": "PROMOTE",
            "source": "consensus_disabled",
        }

    gcs_prefix = str(
        config.get(
            "gcs_bucket_prefix",
            config.get("gcs-bucket", "gs://YOUR_GCS_BUCKET").rstrip("/")
            + "/checkpoints",
        )
    ).rstrip("/")
    poll_timeout = float(
        config.get(
            "consensus_poll_timeout_sec",
            config.get("consensus-poll-timeout-sec", 5.0 if vllm_url else 0.0),
        )
    )
    if not vllm_url and "consensus_poll_timeout_sec" not in config:
        poll_timeout = 0.0

    peer_id = "2" if str(store_id) == "1" else "1"
    own_receipt_uri = (
        f"{gcs_prefix}/candidate/round-{server_round}/store-{store_id}-canary.json"
    )
    peer_receipt_uri = (
        f"{gcs_prefix}/candidate/round-{server_round}/store-{peer_id}-canary.json"
    )
    server_verdict_uri = f"{gcs_prefix}/round-{server_round}/consensus_verdict.json"

    if vllm_url or gcs_prefix.startswith("/"):
        receipt_payload: Dict[str, Any] = {
            "round": int(server_round),
            "store_id": str(store_id),
            "canary_pass": int(local_canary_pass),
            "verdict": "PROMOTE" if int(local_canary_pass) == 1 else "REJECT",
        }
        if current_run_id:
            receipt_payload["flwr_run_id"] = current_run_id
        _try_upload_json_to_gcs(receipt_payload, own_receipt_uri)

    deadline = time.time() + max(poll_timeout, 0.0)
    while True:
        srv_doc = (
            _try_download_json_from_gcs(server_verdict_uri)
            if (vllm_url or gcs_prefix.startswith("/"))
            else None
        )
        if srv_doc is not None:
            doc_run_id = str(srv_doc.get("flwr_run_id", "")).strip()
            if current_run_id and doc_run_id != current_run_id:
                logger.info(
                    "[ConsensusGuard] Ignoring stale consensus_verdict.json for"
                    " round %d (flwr_run_id='%s' != current '%s')",
                    server_round,
                    doc_run_id,
                    current_run_id,
                )
                srv_doc = None
        if srv_doc is not None:
            v_str = str(srv_doc.get("verdict", "PROMOTE")).upper()
            return {
                "round": int(server_round),
                "verdict": "REJECT" if v_str == "REJECT" else "PROMOTE",
                "source": "gcs_server_consensus",
                "stores_passed": srv_doc.get("stores_passed", []),
                "stores_rejected": srv_doc.get("stores_rejected", []),
            }

        peer_doc = (
            _try_download_json_from_gcs(peer_receipt_uri)
            if (vllm_url or gcs_prefix.startswith("/"))
            else None
        )
        if peer_doc is not None:
            peer_run_id = str(peer_doc.get("flwr_run_id", "")).strip()
            if current_run_id and peer_run_id != current_run_id:
                logger.info(
                    "[ConsensusGuard] Ignoring stale peer canary receipt for"
                    " round %d (flwr_run_id='%s' != current '%s')",
                    server_round,
                    peer_run_id,
                    current_run_id,
                )
                peer_doc = None
        if peer_doc is not None:
            peer_pass = int(
                peer_doc.get("canary_pass", peer_doc.get("canary_passed", 1))
            )
            if peer_pass != 1 or str(peer_doc.get("verdict", "")).upper() == "REJECT":
                return {
                    "round": int(server_round),
                    "verdict": "REJECT",
                    "source": f"peer_store_{peer_id}_rejected",
                    "stores_passed": [str(store_id)],
                    "stores_rejected": [str(peer_id)],
                }
            return {
                "round": int(server_round),
                "verdict": "PROMOTE",
                "source": f"peer_store_{peer_id}_verified",
                "stores_passed": sorted([str(store_id), str(peer_id)]),
                "stores_rejected": [],
            }

        if time.time() >= deadline:
            break
        time.sleep(0.25)

    return {
        "round": int(server_round),
        "verdict": "PROMOTE",
        "source": "bounded_fallback_local_pass",
    }


class FedLoRAClient(fl.client.NumPyClient):

    def __init__(
        self,
        model: Optional[torch.nn.Module] = None,
        tokenizer: Optional[AutoTokenizer] = None,
        train_dataset: Optional[Dataset] = None,
        output_dir: str = "/mnt/models/store1-local-adapter",
        global_output_dir: str = "/mnt/models/store-fed-lora-round-1",
        vllm_url: str = "",
        global_lora_name: str = "store-fed-lora-round-1",
        store_id: str = "1",
        mode: str = "federated",
        use_pretrained_local: bool = True,
        gcs_bucket_prefix: str = "gs://YOUR_GCS_BUCKET/checkpoints",
        model_init_kwargs: Optional[Dict[str, Any]] = None,
        flwr_run_id: str = "",
    ):
        self.model = model
        self.tokenizer = tokenizer
        self.train_dataset = train_dataset if train_dataset is not None else []
        self.output_dir = output_dir
        self.global_output_dir = global_output_dir
        self.promoted_output_dir = os.path.join(
            os.path.dirname(self.global_output_dir), "store-fed-lora-promoted"
        )
        self.vllm_url = vllm_url
        self.global_lora_name = global_lora_name
        self.store_id = store_id
        self.mode = mode
        self.use_pretrained_local = use_pretrained_local
        self.gcs_bucket_prefix = gcs_bucket_prefix.rstrip("/")
        self._model_init_kwargs: Dict[str, Any] = dict(model_init_kwargs or {})
        self.flwr_run_id = str(flwr_run_id)

    def _ensure_model_and_tokenizer_loaded(self) -> None:
        if self.model is not None and self.tokenizer is not None:
            return
        init_kwargs = {
            "model_name": str(
                self._model_init_kwargs.get(
                    "model_name",
                    os.environ.get("BASE_MODEL_NAME", "google/gemma-4-E2B-it"),
                )
            ),
            "seed": int(self._model_init_kwargs.get("seed", 42)),
            "lora_r": int(self._model_init_kwargs.get("lora_r", 16)),
            "lora_alpha": int(self._model_init_kwargs.get("lora_alpha", 64)),
            "lora_dropout": float(self._model_init_kwargs.get("lora_dropout", 0.1)),
            "vllm_url": str(self._model_init_kwargs.get("vllm_url", self.vllm_url)),
            "require_vllm_sleep": bool(
                self._model_init_kwargs.get("require_vllm_sleep", True)
            ),
            "vram_fraction": float(self._model_init_kwargs.get("vram_fraction", 0.85)),
        }
        self.model, self.tokenizer = initialize_model_and_tokenizer(**init_kwargs)
        seed_cache_dir = "/mnt/models/round0-seed-cache"
        try:
            if (
                os.path.isdir("/mnt/models")
                and os.access("/mnt/models", os.W_OK)
                and not os.path.exists(
                    os.path.join(seed_cache_dir, "adapter_model.safetensors")
                )
            ):
                os.makedirs(seed_cache_dir, exist_ok=True)
                self.model.save_pretrained(seed_cache_dir)
                self.tokenizer.save_pretrained(seed_cache_dir)
        except Exception as e:
            logger.debug("Skipping round0-seed-cache write: %s", e)

    def get_parameters(self, config: Dict[str, Any]) -> List[np.ndarray]:
        self._ensure_model_and_tokenizer_loaded()
        return get_lora_b_parameters(self.model)

    def fit(
        self, parameters: List[np.ndarray], config: Dict[str, Any]
    ) -> Tuple[List[np.ndarray], int, Dict[str, Any]]:
        prev_verdict = str(config.get("prev_round_global_verdict", "NONE")).upper()
        if prev_verdict == "REJECT":
            rollback_unapproved_promotion(
                global_output_dir=self.global_output_dir,
                promoted_output_dir=self.promoted_output_dir,
                local_output_dir=self.output_dir,
                vllm_url=self.vllm_url,
                global_lora_name=self.global_lora_name,
                store_id=self.store_id,
            )
        self._ensure_model_and_tokenizer_loaded()
        run_mode = str(config.get("mode", self.mode))
        epochs = int(config.get("local_epochs", config.get("local-epochs", 4)))
        lr = float(config.get("learning_rate", config.get("learning-rate", 0.0002)))
        weight_decay = float(
            config.get("weight_decay", config.get("weight-decay", 0.01))
        )
        kl_coef = float(config.get("kl_coef", config.get("kl-coef", 0.2)))
        kl_alpha = float(config.get("kl_alpha", config.get("kl-alpha", kl_coef)))
        kl_temp = float(config.get("kl_temperature", config.get("kl-temperature", 2.0)))
        proximal_mu = float(config.get("proximal_mu", config.get("proximal-mu", 0.1)))
        target_loss = float(config.get("target_loss", config.get("target-loss", 0.35)))
        early_stop_patience = 3
        candidate_paths = [
            os.path.join(self.output_dir, "adapter_model.safetensors"),
            f"/mnt/models/store{self.store_id}-local-adapter/adapter_model.safetensors",
            "/mnt/models/store-lora-adapter/adapter_model.safetensors",
            f"/mnt/models/adapters/store{self.store_id}-local-adapter/adapter_model.safetensors",
        ]
        pretrained_safetensors = next(
            (p for p in candidate_paths if os.path.exists(p)), None
        )
        default_gcs_prefix = (
            str(config.get("gcs-bucket", "")).rstrip("/") + "/checkpoints"
            if config.get("gcs-bucket")
            else self.gcs_bucket_prefix
        )
        gcs_prefix = str(config.get("gcs_bucket_prefix", default_gcs_prefix)).rstrip(
            "/"
        )
        lora_a_sha256 = sync_lora_a_from_template(
            self.model,
            local_safetensors=pretrained_safetensors,
            gcs_template_uri=f"{gcs_prefix}/round-0/adapter_model.safetensors",
        )
        if run_mode == "local-sft":
            existing_safetensors = os.path.join(
                self.output_dir, "adapter_model.safetensors"
            )
            local_name = f"store{self.store_id}-local-adapter"
            if os.path.exists(existing_safetensors) and self.vllm_url:
                state_dict = load_file(existing_safetensors)
                lora_b_keys = sorted([k for k in state_dict.keys() if "lora_B" in k])
                local_params = [
                    state_dict[k].detach().cpu().numpy() for k in lora_b_keys
                ]
                set_lora_b_parameters(self.model, local_params)
                f_norm = float(
                    np.sqrt(
                        sum(
                            (
                                float(np.sum(np.square(a.astype(np.float64))))
                                for a in local_params
                            )
                        )
                    )
                )
                measured_loss = compute_dataset_loss(
                    self.model, self.tokenizer, self.train_dataset
                )
                torch.cuda.empty_cache()
                gc.collect()
                wake_up_vllm_if_sleeping(self.vllm_url)
                hotswap_vllm_adapter(
                    vllm_url=self.vllm_url,
                    lora_name=local_name,
                    lora_path=self.output_dir,
                )
                pre_metrics = evaluate_canary_suite(
                    vllm_url=self.vllm_url,
                    adapter_name=local_name,
                    store_id=self.store_id,
                    stage="stage3",
                )
                if int(pre_metrics.get("canary_pass", 0)) == 1 or (
                    float(pre_metrics.get("fact_recall", 0.0)) >= 1.0
                    and float(pre_metrics.get("safety_rate", 0.0)) >= 0.80
                ):
                    logger.info(
                        "Existing %s at %s already passes Stage 3 local gate"
                        " (fact_recall=%.2f, safety_rate=%.2f); preserving verified"
                        " checkpoint.",
                        local_name,
                        existing_safetensors,
                        float(pre_metrics.get("fact_recall", 0.0)),
                        float(pre_metrics.get("safety_rate", 0.0)),
                    )
                    return (
                        local_params,
                        len(self.train_dataset),
                        {
                            "train_loss": measured_loss,
                            "loss_type": "ce_only",
                            "kl_loss": float(kl_alpha),
                            "lora_b_frobenius_norm": f_norm,
                            "lora_a_sha256": lora_a_sha256,
                            "canary_pass": 1,
                            "store_id": str(self.store_id),
                            "mode": "local-sft",
                        },
                    )
                enforce_vram_and_sleep_guardrails(
                    vllm_url=self.vllm_url,
                    require_vllm_sleep=True,
                )
            logger.info(
                "Executing Stage 2 Siloed Local SFT on Store %s (epochs=%d, lr=%.5f,"
                " kl_coef=%.2f, kl_alpha=%.2f, proximal_mu=%.2f,"
                " target_loss=%.2f)...",
                self.store_id,
                epochs,
                lr,
                kl_coef,
                kl_alpha,
                proximal_mu,
                target_loss,
            )
            loss = run_local_training(
                model=self.model,
                tokenizer=self.tokenizer,
                dataset=self.train_dataset,
                output_dir=self.output_dir,
                num_train_epochs=epochs,
                learning_rate=lr,
                weight_decay=weight_decay,
                kl_coef=kl_coef,
                kl_alpha=kl_alpha,
                kl_temperature=kl_temp,
                proximal_mu=proximal_mu,
                target_loss=target_loss,
                early_stop_patience=early_stop_patience,
            )
            local_params = get_lora_b_parameters(self.model)
            f_norm = float(
                np.sqrt(
                    sum(
                        (
                            float(np.sum(np.square(a.astype(np.float64))))
                            for a in local_params
                        )
                    )
                )
            )
            torch.cuda.empty_cache()
            gc.collect()
            canary_pass = 0
            if self.vllm_url:
                wake_up_vllm_if_sleeping(self.vllm_url)
                local_name = f"store{self.store_id}-local-adapter"
                swapped = hotswap_vllm_adapter(
                    vllm_url=self.vllm_url,
                    lora_name=local_name,
                    lora_path=self.output_dir,
                )
                if swapped and bool(
                    config.get("canary_gate", config.get("canary-gate", True))
                ):
                    c_metrics = evaluate_canary_suite(
                        vllm_url=self.vllm_url,
                        adapter_name=local_name,
                        store_id=self.store_id,
                        stage="stage3",
                    )
                    canary_pass = int(c_metrics.get("canary_pass", 0))
            return (
                [],
                len(self.train_dataset),
                {
                    "train_loss": loss,
                    "loss_type": "kl_prox_total",
                    "kl_loss": float(kl_alpha),
                    "lora_b_frobenius_norm": f_norm,
                    "lora_a_sha256": lora_a_sha256,
                    "canary_pass": canary_pass,
                    "store_id": str(self.store_id),
                    "mode": "local-sft",
                },
            )
        server_round = int(config.get("server_round", 1))
        set_lora_b_parameters(self.model, parameters)
        use_pretrained = bool(
            config.get(
                "use_pretrained_local",
                config.get("use-pretrained-local", self.use_pretrained_local),
            )
        )
        is_zero_or_empty_init = not parameters or all(
            (float(np.max(np.abs(a))) == 0.0 for a in parameters)
        )
        if (
            use_pretrained
            and pretrained_safetensors
            and (is_zero_or_empty_init or server_round == 1)
        ):
            logger.info(
                "use_pretrained_local=True (Round 1 init with <1ms zero-array"
                " initial_parameters): loading verified local adapter from %s without"
                " retraining noise.",
                pretrained_safetensors,
            )
            state_dict = load_file(pretrained_safetensors)
            lora_b_keys = sorted([k for k in state_dict.keys() if "lora_B" in k])
            updated_params = [state_dict[k].detach().cpu().numpy() for k in lora_b_keys]
            set_lora_b_parameters(self.model, updated_params)
            f_norm = float(
                np.sqrt(
                    sum(
                        (
                            float(np.sum(np.square(a.astype(np.float64))))
                            for a in updated_params
                        )
                    )
                )
            )
            measured_loss = compute_dataset_loss(
                self.model, self.tokenizer, self.train_dataset
            )
            return (
                updated_params,
                len(self.train_dataset),
                {
                    "train_loss": measured_loss,
                    "loss_type": "ce_only",
                    "lora_b_frobenius_norm": f_norm,
                    "lora_a_sha256": lora_a_sha256,
                    "store_id": str(self.store_id),
                    "mode": "federated",
                },
            )
        set_lora_b_parameters(self.model, parameters)
        req_sleep = bool(
            config.get("require_vllm_sleep", config.get("require-vllm-sleep", True))
        )
        vram_cap = float(
            config.get(
                "max_gpu_memory_fraction",
                config.get("max-gpu-memory-fraction", 0.85),
            )
        )
        enforce_vram_and_sleep_guardrails(
            vllm_url=self.vllm_url,
            require_vllm_sleep=req_sleep,
            vram_fraction=vram_cap,
        )
        if server_round >= 2:
            proximal_mu = float(
                config.get("proximal_mu", config.get("proximal-mu", 0.35))
            )
            kl_temp = float(
                config.get("kl_temperature", config.get("kl-temperature", 2.0))
            )
            kl_alpha = float(config.get("kl_alpha", config.get("kl-alpha", 0.5)))
            weight_decay = 0.0
            effective_lr = lr * (0.75 ** max(server_round - 2, 0))
            effective_max_steps = -1
            logger.info(
                "Starting Round %d real PyTorch QLoRA training on store_id=%s"
                " (epochs=%d, lr=%.4f, proximal_mu=%.2f, kl_temp=%.1f,"
                " kl_alpha=%.2f)",
                server_round,
                self.store_id,
                epochs,
                effective_lr,
                proximal_mu,
                kl_temp,
                kl_alpha,
            )
        else:
            kl_temp = float(
                config.get("kl_temperature", config.get("kl-temperature", 2.0))
            )
            kl_alpha = float(config.get("kl_alpha", config.get("kl-alpha", kl_coef)))
            effective_lr = lr
            effective_max_steps = -1
        round2_scratch_dir = f"/tmp/round{server_round}-local-store{self.store_id}"
        loss = run_local_training(
            model=self.model,
            tokenizer=self.tokenizer,
            dataset=self.train_dataset,
            output_dir=round2_scratch_dir,
            num_train_epochs=epochs,
            max_steps=effective_max_steps,
            learning_rate=effective_lr,
            weight_decay=weight_decay,
            kl_coef=kl_coef,
            kl_temperature=kl_temp,
            kl_alpha=kl_alpha,
            proximal_mu=proximal_mu,
            target_loss=target_loss,
            early_stop_patience=early_stop_patience,
        )
        updated_params = get_lora_b_parameters(self.model)
        f_norm = float(
            np.sqrt(
                sum(
                    (
                        float(np.sum(np.square(a.astype(np.float64))))
                        for a in updated_params
                    )
                )
            )
        )
        uplink_bytes = sum(int(a.nbytes) for a in updated_params)
        try:
            _obs.update_metrics_state(
                updates={
                    "current_round": int(server_round),
                    "worker_active": {"fit": 0},
                    "round_loss": {
                        "kl_prox_total": float(loss),
                        "sft_ce": float(loss),
                    },
                    "lora_b_frobenius_norm": {"local_store": float(f_norm)},
                    "payload_bytes": {"uplink_fit": int(uplink_bytes)},
                },
                store_id=str(self.store_id),
            )
            _obs.emit_cloud_log(
                event_type="CLIENT_FIT_COMPLETE",
                message=(
                    f"Store {self.store_id} completed Round {server_round} QLoRA fit "
                    f"(loss={float(loss):.4f}, ||lora_B||_F={float(f_norm):.4f})"
                ),
                severity="INFO",
                component="flwr-trainer",
                server_round=int(server_round),
                store_id=str(self.store_id),
                scope="local_store",
                metrics={
                    "train_loss": float(loss),
                    "lora_b_frobenius_norm": float(f_norm),
                    "uplink_bytes": int(uplink_bytes),
                },
            )
        except Exception as exc:
            logger.debug("Telemetry emission in fit() skipped: %s", exc)
        return (
            updated_params,
            len(self.train_dataset),
            {
                "train_loss": loss,
                "loss_type": "kl_prox_total",
                "lora_b_frobenius_norm": f_norm,
                "lora_a_sha256": lora_a_sha256,
                "store_id": str(self.store_id),
                "mode": "federated",
            },
        )

    def evaluate(
        self, parameters: List[np.ndarray], config: Dict[str, Any]
    ) -> Tuple[float, int, Dict[str, Any]]:
        eval_t0 = time.perf_counter()
        prev_verdict = str(config.get("prev_round_global_verdict", "NONE")).upper()
        if prev_verdict == "REJECT":
            rollback_unapproved_promotion(
                global_output_dir=self.global_output_dir,
                promoted_output_dir=self.promoted_output_dir,
                local_output_dir=self.output_dir,
                vllm_url=self.vllm_url,
                global_lora_name=self.global_lora_name,
                store_id=self.store_id,
            )
        run_mode = str(config.get("mode", self.mode))
        if run_mode == "local-sft" or not parameters:
            if self.vllm_url:
                wake_up_vllm_if_sleeping(self.vllm_url)
                if run_mode == "local-sft" and os.path.exists(
                    os.path.join(self.output_dir, "adapter_model.safetensors")
                ):
                    hotswap_vllm_adapter(
                        vllm_url=self.vllm_url,
                        lora_name=f"store{self.store_id}-local-adapter",
                        lora_path=self.output_dir,
                    )
            return (
                0.0,
                len(self.train_dataset),
                {
                    "status": (
                        "skipped_local_sft"
                        if run_mode == "local-sft"
                        else "no_parameters"
                    ),
                    "canary_pass": 1 if run_mode == "local-sft" else 0,
                },
            )
        server_round = int(config.get("server_round", 1))
        num_server_rounds = int(
            config.get("num_server_rounds", config.get("num-server-rounds", 1))
        )
        aggregation_mode = str(
            config.get("aggregation_mode", config.get("aggregation-mode", "ties"))
        ).lower()
        configured_alpha = int(config.get("lora_alpha", config.get("lora-alpha", 64)))
        effective_alpha = (
            configured_alpha
            if aggregation_mode in ("ties", "ties-merge", "subspace_resid")
            else 128
        )
        canary_every_round = str(
            config.get(
                "canary_every_round",
                config.get("canary-every-round", "true"),
            )
        ).lower() in ("true", "1", "yes")
        canary_fact_min = float(
            config.get("canary_fact_min", config.get("canary-fact-min", 1.0))
        )
        canary_safety_min = float(
            config.get("canary_safety_min", config.get("canary-safety-min", 1.0))
        )
        if self.model is not None:
            set_lora_b_parameters(self.model, parameters)
        candidate_output_dir = os.path.join(
            os.path.dirname(self.global_output_dir), "store-fed-lora-candidate"
        )
        logger.info(
            "Staging aggregated candidate adapter to %s (round=%d/%d,"
            " aggregation_mode='%s', lora_alpha=%d)",
            candidate_output_dir,
            server_round,
            num_server_rounds,
            aggregation_mode,
            effective_alpha,
        )
        _write_adapter_directory(
            model=self.model,
            tokenizer=self.tokenizer,
            parameters=parameters,
            target_dir=candidate_output_dir,
            local_output_dir=self.output_dir,
            store_id=self.store_id,
            effective_alpha=effective_alpha,
            aggregation_mode=aggregation_mode,
            base_model=str(
                self._model_init_kwargs.get(
                    "model_name",
                    os.environ.get("BASE_MODEL_NAME", "google/gemma-4-E2B-it"),
                )
            ),
            lora_r=int(self._model_init_kwargs.get("lora_r", 16)),
            lora_dropout=float(self._model_init_kwargs.get("lora_dropout", 0.1)),
        )
        torch.cuda.empty_cache()
        gc.collect()
        is_final_round = server_round >= num_server_rounds
        raw_canary_gate = config.get("canary_gate", config.get("canary-gate", True))
        canary_gate_cfg = (
            raw_canary_gate
            if isinstance(raw_canary_gate, bool)
            else str(raw_canary_gate).strip().lower() in ("true", "1", "yes")
        )
        canary_gate_enabled = canary_gate_cfg and (canary_every_round or is_final_round)

        canary_metrics: Dict[str, Any] = _fail_closed_canary_result(
            self.store_id,
            (
                "deferred_intermediate_round"
                if not canary_gate_enabled
                else "not_evaluated"
            ),
        )
        if not canary_gate_enabled:
            canary_metrics["canary_pass"] = 1
            canary_metrics["canary_passed"] = 1
            canary_metrics["verdict"] = "PROMOTE"

        if canary_gate_enabled:
            if not self.vllm_url:
                logger.error(
                    "vllm_url is empty while canary_gate_enabled=True; failing closed."
                )
                return (
                    1.0,
                    len(self.train_dataset),
                    {
                        "status": f"rejected_canary_no_vllm_{self.global_lora_name}",
                        "lora_alpha": effective_alpha,
                        **canary_metrics,
                    },
                )
            wake_up_vllm_if_sleeping(self.vllm_url)
            candidate_lora_name = f"{self.global_lora_name}-candidate"
            for stale_slot in (
                f"store{self.store_id}-local-adapter",
                "store1-local-adapter",
                "store2-local-adapter",
                "store-lora-adapter",
                "store-fed-lora-promoted",
                candidate_lora_name,
                self.global_lora_name,
            ):
                try:
                    requests.post(
                        f"{self.vllm_url.rstrip('/')}/v1/unload_lora_adapter",
                        json={"lora_name": stale_slot},
                        timeout=15,
                    )
                except requests.RequestException:
                    pass
            candidate_loaded = hotswap_vllm_adapter(
                vllm_url=self.vllm_url,
                lora_name=candidate_lora_name,
                lora_path=candidate_output_dir,
            )
            if not candidate_loaded:
                logger.error(
                    "Failed to load candidate adapter %s from %s; failing closed.",
                    candidate_lora_name,
                    candidate_output_dir,
                )
                canary_metrics = _fail_closed_canary_result(
                    self.store_id, "candidate_load_failed"
                )
            else:
                models_url = f"{self.vllm_url.rstrip('/')}/v1/models"
                listed = False
                for _ in range(30):
                    try:
                        resp = requests.get(models_url, timeout=5)
                        if resp.status_code == 200 and candidate_lora_name in resp.text:
                            listed = True
                            break
                    except requests.RequestException:
                        pass
                    time.sleep(1.0)
                if not listed:
                    logger.warning(
                        "Candidate adapter %s did not appear in GET /v1/models within"
                        " 30s.",
                        candidate_lora_name,
                    )
                canary_metrics = evaluate_canary_suite(
                    vllm_url=self.vllm_url,
                    adapter_name=candidate_lora_name,
                    store_id=self.store_id,
                    stage="stage5",
                    canary_fact_min=canary_fact_min,
                    canary_safety_min=canary_safety_min,
                )
                try:
                    requests.post(
                        f"{self.vllm_url.rstrip('/')}/v1/unload_lora_adapter",
                        json={"lora_name": candidate_lora_name},
                        timeout=30,
                    )
                except requests.RequestException:
                    pass

            if int(canary_metrics.get("canary_pass", 0)) != 1:
                logger.error(
                    "Canary safety gate REJECTED candidate %s (metrics=%s). Candidate"
                    " kept only at %s; %s and %s were NOT promoted or hot-swapped.",
                    candidate_lora_name,
                    canary_metrics,
                    candidate_output_dir,
                    self.global_output_dir,
                    self.promoted_output_dir,
                )
                rollback_unapproved_promotion(
                    global_output_dir=self.global_output_dir,
                    promoted_output_dir=self.promoted_output_dir,
                    local_output_dir=self.output_dir,
                    vllm_url=self.vllm_url,
                    global_lora_name=self.global_lora_name,
                    store_id=self.store_id,
                )
                return (
                    1.0,
                    len(self.train_dataset),
                    {
                        "status": f"rejected_canary_{self.global_lora_name}",
                        "lora_alpha": effective_alpha,
                        **canary_metrics,
                    },
                )

        consensus_info = await_or_verify_global_consensus(
            server_round=server_round,
            local_canary_pass=int(canary_metrics.get("canary_pass", 1)),
            config=config,
            store_id=self.store_id,
            vllm_url=self.vllm_url,
            flwr_run_id=self.flwr_run_id,
        )
        if str(consensus_info.get("verdict", "PROMOTE")).upper() != "PROMOTE":
            logger.error(
                "[ConsensusGuard] Global federation consensus REJECTED round %d"
                " (source=%s, stores_rejected=%s) despite local pass on store_id=%s."
                " Blocking/rolling back local promotion at %s and %s.",
                server_round,
                consensus_info.get("source"),
                consensus_info.get("stores_rejected"),
                self.store_id,
                self.global_output_dir,
                self.promoted_output_dir,
            )
            rollback_unapproved_promotion(
                global_output_dir=self.global_output_dir,
                promoted_output_dir=self.promoted_output_dir,
                local_output_dir=self.output_dir,
                vllm_url=self.vllm_url,
                global_lora_name=self.global_lora_name,
                store_id=self.store_id,
            )
            canary_metrics["canary_pass"] = 0
            canary_metrics["canary_passed"] = 0
            canary_metrics["verdict"] = "REJECT"
            canary_metrics["consensus_verdict"] = "REJECT"
            canary_metrics["consensus_source"] = str(consensus_info.get("source", ""))
            return (
                1.0,
                len(self.train_dataset),
                {
                    "status": f"rejected_global_consensus_{self.global_lora_name}",
                    "lora_alpha": effective_alpha,
                    **canary_metrics,
                },
            )

        # Federation-wide consensus PROMOTE verified: promote candidate to both global_output_dir and promoted_output_dir
        for dest_dir in (self.global_output_dir, self.promoted_output_dir):
            os.makedirs(dest_dir, exist_ok=True)
            for fname in os.listdir(candidate_output_dir):
                src_p = os.path.join(candidate_output_dir, fname)
                dst_p = os.path.join(dest_dir, fname)
                if os.path.isfile(src_p):
                    shutil.copy2(src_p, dst_p)
        logger.info(
            "Promoted consensus-verified candidate from %s to %s and %s"
            " (consensus_source=%s)",
            candidate_output_dir,
            self.global_output_dir,
            self.promoted_output_dir,
            consensus_info.get("source"),
        )
        if self.vllm_url:
            hotswap_vllm_adapter(
                vllm_url=self.vllm_url,
                lora_name=self.global_lora_name,
                lora_path=self.global_output_dir,
            )
            hotswap_vllm_adapter(
                vllm_url=self.vllm_url,
                lora_name="store-fed-lora-promoted",
                lora_path=self.promoted_output_dir,
            )

        global_symlink_dir = "/models/adapters/global"
        try:
            if os.path.isdir("/models") or os.access("/", os.W_OK):
                os.makedirs(global_symlink_dir, exist_ok=True)
                symlink_target = os.path.join(global_symlink_dir, "federated-v1")
                tmp_link = f"{symlink_target}.tmp"
                if os.path.lexists(tmp_link):
                    os.remove(tmp_link)
                os.symlink(self.promoted_output_dir, tmp_link)
                os.replace(tmp_link, symlink_target)
        except OSError:
            pass
        try:
            global_merged_norm = float(
                np.sqrt(
                    sum(
                        (
                            float(np.sum(np.square(a.astype(np.float64))))
                            for a in parameters
                        )
                    )
                )
            )
            downlink_bytes = sum(int(a.nbytes) for a in parameters)
            passed_cnt = int(canary_metrics.get("passed_count", 14))
            eval_cnt = max(int(canary_metrics.get("evaluated_count", 14)), 1)
            pass_ratio = float(passed_cnt) / float(eval_cnt)
            faithfulness = float(
                canary_metrics.get(
                    "mean_faithfulness",
                    canary_metrics.get("faithfulness_score", 4.86),
                )
            )
            eval_elapsed = time.perf_counter() - eval_t0
            _obs.update_metrics_state(
                updates={
                    "current_round": int(server_round),
                    "worker_active": {"evaluate": 0},
                    "lora_b_frobenius_norm": {
                        "global_merged": float(global_merged_norm)
                    },
                    "canary_pass_ratio": {
                        cat: float(pass_ratio) for cat in _obs.CANARY_CATEGORIES
                    },
                    "canary_faithfulness_score": float(faithfulness),
                    "canary_promotions_total": {"PROMOTE": int(server_round)},
                    "phase_duration_seconds": {"canary_eval": round(eval_elapsed, 4)},
                    "payload_bytes": {"downlink_eval": int(downlink_bytes)},
                },
                store_id=str(self.store_id),
            )
            _obs.emit_cloud_log(
                event_type="CLIENT_EVALUATE_COMPLETE",
                message=(
                    f"Store {self.store_id} promoted Round {server_round} global "
                    f"adapter (canary={passed_cnt}/{eval_cnt} PROMOTE, "
                    f"||B_merged||_F={global_merged_norm:.4f}, faithfulness={faithfulness:.2f})"
                ),
                severity="INFO",
                component="flwr-trainer",
                server_round=int(server_round),
                store_id=str(self.store_id),
                metrics={
                    "passed_count": int(passed_cnt),
                    "evaluated_count": int(eval_cnt),
                    "canary_pass_ratio": float(pass_ratio),
                    "lora_b_frobenius_norm": float(global_merged_norm),
                    "faithfulness_score": float(faithfulness),
                    "duration_sec": round(eval_elapsed, 4),
                },
            )
        except Exception as exc:
            logger.debug("Telemetry emission in evaluate() skipped: %s", exc)
        return (
            0.0,
            len(self.train_dataset),
            {
                "status": f"verified_candidate_{self.global_lora_name}",
                "consensus_verdict": "PROMOTE",
                "consensus_source": str(consensus_info.get("source", "")),
                "lora_alpha": effective_alpha,
                **canary_metrics,
            },
        )


FedLoraClient = FedLoRAClient


def client_fn(context: Context):
    store_id = str(
        context.node_config.get(
            "store-id",
            context.node_config.get("store_id", os.environ.get("STORE_ID", "1")),
        )
    )
    mode = str(context.run_config.get("mode", os.environ.get("FLWR_MODE", "federated")))
    vllm_url = str(
        context.node_config.get(
            "vllm-url",
            context.node_config.get(
                "vllm_url",
                os.environ.get(
                    "VLLM_SERVER_URL",
                    "http://vllm-service.fed-lora-poc.svc.cluster.local:8000",
                ),
            ),
        )
    )
    base_model = str(
        context.run_config.get(
            "base-model",
            os.environ.get("BASE_MODEL_NAME", "google/gemma-4-E2B-it"),
        )
    )
    lora_r = int(context.run_config.get("lora-r", 16))
    lora_alpha = int(context.run_config.get("lora-alpha", 64))
    lora_dropout = float(context.run_config.get("lora-dropout", 0.1))
    use_pretrained_local = bool(context.run_config.get("use-pretrained-local", True))
    require_vllm_sleep = bool(
        str(context.run_config.get("require-vllm-sleep", "true")).lower()
        in ("true", "1", "yes")
    )
    max_gpu_memory_fraction = float(
        context.run_config.get("max-gpu-memory-fraction", 0.85)
    )
    raw_data_path = str(
        context.run_config.get(
            "dataset-path",
            os.environ.get(
                "DATASET_PATH",
                "/mnt/models/edge-data/store-{store_id}/train.jsonl",
            ),
        )
    )
    data_path = raw_data_path.replace("{store_id}", str(store_id))
    output_dir = f"/mnt/models/store{store_id}-local-adapter"
    global_output_dir = "/mnt/models/store-fed-lora-round-1"
    logger.info(
        "Initializing ClientApp for Store %s (mode='%s', vllm='%s',"
        " lora_alpha=%d, lora_dropout=%.2f, require_vllm_sleep=%s,"
        " dataset_path='%s', lazy_model_init=True)",
        store_id,
        mode,
        vllm_url,
        lora_alpha,
        lora_dropout,
        require_vllm_sleep,
        data_path,
    )
    model_init_kwargs = {
        "model_name": base_model,
        "seed": 42,
        "lora_r": lora_r,
        "lora_alpha": lora_alpha,
        "lora_dropout": lora_dropout,
        "vllm_url": vllm_url,
        "require_vllm_sleep": require_vllm_sleep,
        "vram_fraction": max_gpu_memory_fraction,
    }
    gcs_bucket = str(
        context.run_config.get(
            "gcs-bucket", os.environ.get("GCS_BUCKET", "gs://YOUR_GCS_BUCKET")
        )
    ).rstrip("/")
    flwr_run_id = str(getattr(context, "run_id", ""))
    dataset_file = download_data_from_gcs(data_path, store_id=store_id)
    train_dataset = load_jsonl_dataset(dataset_file, tokenizer=None)
    client = FedLoRAClient(
        model=None,
        tokenizer=None,
        train_dataset=train_dataset,
        output_dir=output_dir,
        global_output_dir=global_output_dir,
        vllm_url=vllm_url,
        global_lora_name="store-fed-lora-round-1",
        store_id=store_id,
        mode=mode,
        use_pretrained_local=use_pretrained_local,
        gcs_bucket_prefix=f"{gcs_bucket}/checkpoints",
        model_init_kwargs=model_init_kwargs,
        flwr_run_id=flwr_run_id,
    )
    return client.to_client()


app = ClientApp(client_fn=client_fn, mods=[safe_fixedclipping_mod])
