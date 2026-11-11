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

# Zero-VRAM Edge LLM-as-a-Judge & Deterministic Canary Gate CLI
# Delegates all evaluation and Pass-1/Pass-2 logic to the canonical shared module
# apps/fed-lora/canary_eval.py ("One gate, one rule").

import argparse
import json
import logging
import os
import sys

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
APP_DIR = os.path.abspath(os.path.join(THIS_DIR, "../apps/fed-lora"))
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

import canary_eval as _canary_eval  # pylint: disable=g-import-not-at-top

CANONICAL_CANARY_SUITE = _canary_eval.CANONICAL_CANARY_SUITE
JUDGE_SYSTEM_PROMPT = _canary_eval.JUDGE_SYSTEM_PROMPT
check_deterministic_rules = _canary_eval.check_deterministic_rules
evaluate_canary_probe = _canary_eval.evaluate_canary_probe
evaluate_suite = _canary_eval.evaluate_suite
extract_json_verdict = _canary_eval.extract_json_verdict
generate_dry_run_response = _canary_eval.generate_dry_run_response
load_canary_suite = _canary_eval.load_canary_suite
query_vllm_chat = _canary_eval.query_vllm_chat
run_zero_vram_base_judge = _canary_eval.run_zero_vram_base_judge

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("eval_local_gemma_judge")

__all__ = [
    "CANONICAL_CANARY_SUITE",
    "JUDGE_SYSTEM_PROMPT",
    "check_deterministic_rules",
    "evaluate_canary_probe",
    "evaluate_suite",
    "extract_json_verdict",
    "generate_dry_run_response",
    "load_canary_suite",
    "query_vllm_chat",
    "run_zero_vram_base_judge",
]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Zero-VRAM Edge LLM-as-a-Judge & Canary Gate"
    )
    parser.add_argument(
        "--vllm-url",
        type=str,
        default=os.environ.get("VLLM_SERVER_URL", "http://localhost:8000"),
        help="vLLM OpenAI-compatible server base URL.",
    )
    parser.add_argument(
        "--adapter-name",
        type=str,
        default="store-fed-lora-round-1",
        help="LoRA adapter name registered in vLLM.",
    )
    parser.add_argument(
        "--base-model",
        type=str,
        default=os.environ.get("BASE_MODEL_NAME", "google/gemma-4-E2B-it"),
        help="Base unadapted model name in vLLM for Pass-2 Zero-VRAM judging.",
    )
    parser.add_argument(
        "--store-id",
        type=str,
        default=os.environ.get("STORE_ID", "1"),
        help="Store ID ('1' or '2').",
    )
    parser.add_argument(
        "--stage",
        type=str,
        choices=["stage3", "stage5"],
        default="stage5",
        help="Verification stage ('stage3' local-sft or 'stage5' federated).",
    )
    parser.add_argument(
        "--canary-suite",
        type=str,
        default="",
        help="Path to canary_suite.json.",
    )
    parser.add_argument(
        "--output-json",
        type=str,
        default="",
        help="Optional file path to save the JSON evaluation report.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Run synthetic validation across all canary categories without live vLLM.",
    )
    parser.add_argument(
        "--store-scope",
        type=str,
        default="external-demo",
        choices=["store1", "store2", "external-demo"],
        help=(
            "Authorized rubric scope: 'store1' (C1+C4+C5), 'store2'"
            " (C2+C6+C4+C5), or 'external-demo' (all probes including C3)."
        ),
    )
    parser.add_argument(
        "--canary-fact-min",
        type=float,
        default=1.0,
        help="Minimum fact recall threshold (default: 1.0).",
    )
    parser.add_argument(
        "--canary-safety-min",
        type=float,
        default=1.0,
        help="Minimum safety/abstention rate threshold (default: 1.0).",
    )
    args = parser.parse_args()

    canary_path = args.canary_suite
    if not canary_path:
        candidates = [
            os.path.join(THIS_DIR, "../apps/fed-lora/canary_suite.json"),
        ]
        canary_path = next((p for p in candidates if os.path.exists(p)), "")

    report = evaluate_suite(
        vllm_url=args.vllm_url,
        adapter_name=args.adapter_name,
        base_model=args.base_model,
        store_id=args.store_id,
        stage=args.stage,
        canary_suite_path=canary_path or None,
        dry_run=args.dry_run,
        store_scope=args.store_scope,
        canary_fact_min=args.canary_fact_min,
        canary_safety_min=args.canary_safety_min,
    )

    if args.output_json:
        os.makedirs(os.path.dirname(os.path.abspath(args.output_json)), exist_ok=True)
        with open(args.output_json, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=2)
        logger.info("Saved canary evaluation report to %s", args.output_json)

    print(
        json.dumps(
            {
                "evaluated_count": report["evaluated_count"],
                "passed_count": report["passed_count"],
                "pass1_passed_count": report["pass1_passed_count"],
                "pass2_passed_count": report["pass2_passed_count"],
                "faithfulness_score": report["faithfulness_score"],
                "canary_eval_duration_sec": report["canary_eval_duration_sec"],
                "verdict": report["verdict"],
                "rates": report["rates"],
            },
            indent=2,
        )
    )
    if report["canary_passed"]:
        logger.info(
            "CANARY GATE PASSED (%d/%d probes, Pass-1=%d/%d, Pass-2=%d/%d,"
            " faithfulness_score=%.2f/5.0, duration=%.2fs, verdict=%s)",
            report["passed_count"],
            report["evaluated_count"],
            report["pass1_passed_count"],
            report["evaluated_count"],
            report["pass2_passed_count"],
            report["evaluated_count"],
            report["faithfulness_score"],
            report["canary_eval_duration_sec"],
            report["verdict"],
        )
        return 0
    else:
        logger.error(
            "CANARY GATE FAILED (overall_pass_rate=%.2f%%, Pass-1=%d/%d,"
            " Pass-2=%d/%d, verdict=%s)",
            100.0 * report["overall_canary_pass_rate"],
            report["pass1_passed_count"],
            report["evaluated_count"],
            report["pass2_passed_count"],
            report["evaluated_count"],
            report["verdict"],
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
