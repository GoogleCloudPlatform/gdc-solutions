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
#
# cspell:words genai httpx jsonrpc opentelemetry pydantic streamable subcall subcalls tokenquota toolsets tracecontext traceparent vllm vertexai

"""Hardened Google ADK Operations Orchestrator Agent for Distributed Cloud software only (v0.3.0).

Security and architectural invariants:
  1. Zero code execution or shell tools: `code_executor=None`, no subprocess/exec/skill-script tools.
  2. Strict proxy mediation: all outbound LLM (`ApigeeLlm` OpenAI `/v1/chat/completions` facade and native `Gemini` `/v1beta` facade),
     MCP (`/mcp-bigquery`, `/mcp-storage`, `/mcp`), and peer A2A JSON-RPC (`message/send`) calls target ONLY
     the local Envoy egress proxy (`http://ops-egress-envoy.agent-workloads.svc.cluster.local:15001`),
     injecting `adk-ops-orchestrator`'s projected KSA JWT (`x-agent-ksa-token`) and W3C `traceparent`.
  3. Deploy-time target resolution: resolves `adk-sovereign-agent`'s A2A URL from a read-only
     ConfigMap (`/etc/adk-config/peer-agents.json`) seeded from Agent Registry metadata at deploy time,
     requiring zero pod egress to `agentregistry.googleapis.com`.
  4. Sovereign telemetry hygiene: extracts incoming W3C `traceparent` headers and
     propagates them across A2A and MCP subcalls while disabling GenAI and ADK message/tool content capture
     (`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false` and `ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=false`).
  5. AI Gateway capabilities: virtual model aliases (`CLOUD_MODEL_ALIAS=enterprise-flash`,
     `SOVEREIGN_MODEL_ALIAS=enterprise-sovereign`), first-party ADK dual SDK facade (`ADK_CLIENT_MODE=apigee_openai|google_genai`
     with zero `litellm` dependency), ADK `McpToolset` integration for Google-managed BigQuery/Cloud Storage MCPs and Apigee `/mcp`, and real-time
     SSE streaming (`/invoke-stream`).
"""

from __future__ import annotations

import contextvars
import functools
import json
import os
import uuid
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import AsyncIterator

os.environ.setdefault("ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS", "false")
os.environ.setdefault("OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT", "false")

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse
from google import genai
from google.adk.agents import Agent
from google.adk.agents.run_config import RunConfig, StreamingMode
from google.adk.models.apigee_llm import ApigeeLlm
from google.adk.models.google_llm import Gemini
from google.adk.runners import Runner
from google.adk.sessions import InMemorySessionService
from google.adk.tools.mcp_tool import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import StreamableHTTPConnectionParams
from google.genai import types as genai_types
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from pydantic import PrivateAttr

APP_NAME = "adk-ops-orchestrator"
AGENT_CARD_PATH = Path(os.getenv("AGENT_CARD_PATH", "/app/agent-card.json"))
PEER_CONFIG_PATH = Path(
    os.getenv("PEER_CONFIG_PATH", "/etc/adk-config/peer-agents.json")
)
KSA_TOKEN_PATH = Path(
    os.getenv("KSA_TOKEN_PATH", "/var/run/secrets/tokens/apigee-ksa/token")
)
EGRESS_PROXY_BASE = os.getenv(
    "EGRESS_PROXY_BASE",
    "http://ops-egress-envoy.agent-workloads.svc.cluster.local:15001",
).rstrip("/")
OTLP_TRACES_ENDPOINT = os.getenv(
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "http://otel-collector.otel-system.svc.cluster.local:4318/v1/traces",
)
CLOUD_MODEL_ALIAS = os.getenv("CLOUD_MODEL_ALIAS", "enterprise-flash")
SOVEREIGN_MODEL_ALIAS = os.getenv("SOVEREIGN_MODEL_ALIAS", "enterprise-sovereign")
SOVEREIGN_MODEL_NAME = os.getenv("SOVEREIGN_MODEL_NAME", "google/gemma-4-31B-it")
ADK_CLIENT_MODE = os.getenv("ADK_CLIENT_MODE", "apigee_openai")

AGENT_CARD = json.loads(AGENT_CARD_PATH.read_text(encoding="utf-8"))
PROPAGATOR = TraceContextTextMapPropagator()
REQUEST_COUNTERS: Counter[tuple[str, str]] = Counter()


@dataclass
class _TurnTelemetry:
    llm_backend: str = "unknown"
    routed_tier: str = ""
    resolved_model: str = ""
    quota_headers: dict[str, str] = field(default_factory=dict)
    tools_invoked: list[str] = field(default_factory=list)


TURN_TELEMETRY: contextvars.ContextVar[_TurnTelemetry | None] = contextvars.ContextVar(
    "turn_telemetry", default=None
)
LAST_A2A_META: contextvars.ContextVar[dict | None] = contextvars.ContextVar(
    "last_a2a_meta", default=None
)
CURRENT_TURN_PROMPT: contextvars.ContextVar[str] = contextvars.ContextVar(
    "current_turn_prompt", default=""
)

QUOTA_HEADER_NAMES = (
    "x-tokenquota-limit",
    "x-tokenquota-used",
    "x-tokenquota-remaining",
    "x-tokenquota-reset",
    "retry-after",
)


class UpstreamA2AGatewayError(RuntimeError):
    """Raised when Apigee rejects or rate-limits an A2A subcall (401/403/429)."""

    def __init__(self, status_code: int, meta: dict):
        super().__init__(f"Apigee A2A subcall returned HTTP {status_code}")
        self.status_code = status_code
        self.meta = meta


def _record_gateway_headers(headers: dict[str, str]) -> None:
    state = TURN_TELEMETRY.get()
    if state is None:
        return
    lowered = {
        str(k).lower().removeprefix("llm_provider-"): str(v)
        for k, v in headers.items()
        if v is not None
    }
    if lowered.get("x-llm-backend"):
        state.llm_backend = lowered["x-llm-backend"]
    elif lowered.get("llm-backend"):
        state.llm_backend = lowered["llm-backend"]
    if lowered.get("x-hca-routed-tier"):
        state.routed_tier = lowered["x-hca-routed-tier"]
    if lowered.get("x-hca-resolved-model"):
        state.resolved_model = lowered["x-hca-resolved-model"]
    for qh in QUOTA_HEADER_NAMES:
        if lowered.get(qh):
            state.quota_headers[qh] = lowered[qh]


async def _on_httpx_response(response: httpx.Response) -> None:
    _record_gateway_headers(dict(response.headers))


class GatewayGemini(Gemini):
    """ADK native `google-genai` model wrapper routed strictly through Envoy -> Apigee `/v1beta`."""

    _base_url: str = PrivateAttr(default="")
    _api_key: str = PrivateAttr(default="")
    _headers: dict[str, str] = PrivateAttr(default_factory=dict)
    _httpx_async_client: httpx.AsyncClient | None = PrivateAttr(default=None)

    def __init__(
        self,
        *,
        model: str,
        base_url: str,
        api_key: str,
        headers: dict[str, str],
        httpx_async_client: httpx.AsyncClient | None = None,
    ):
        super().__init__(model=model)
        self._base_url = base_url
        self._api_key = api_key
        self._headers = headers
        self._httpx_async_client = httpx_async_client

    @functools.cached_property
    def api_client(self) -> genai.Client:
        opts_kwargs: dict[str, object] = {
            "base_url": self._base_url,
            "api_version": "v1beta",
            "headers": self._headers,
        }
        if self._httpx_async_client is not None:
            opts_kwargs["httpx_async_client"] = self._httpx_async_client
        return genai.Client(
            api_key=self._api_key,
            vertexai=False,
            http_options=genai_types.HttpOptions(**opts_kwargs),
        )


resource = Resource.create(
    {
        "service.name": APP_NAME,
        "service.version": AGENT_CARD.get("version", "0.2.0"),
        "gen_ai.agent.id": APP_NAME,
        "gen_ai.agent.name": APP_NAME,
    }
)
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_TRACES_ENDPOINT, timeout=5))
)
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer("hybrid_cloud_agents.adk", AGENT_CARD.get("version", "0.2.0"))

session_service = InMemorySessionService()


def _load_peer_registry_config() -> dict:
    if PEER_CONFIG_PATH.exists():
        return json.loads(PEER_CONFIG_PATH.read_text(encoding="utf-8"))
    return {
        "discovery_source": "default-fallback",
        "peers": {
            "adk-sovereign-agent": {
                "a2a_egress_url": f"{EGRESS_PROXY_BASE}/a2a/sovereign",
                "canonical_gateway_url": "https://api.hybrid-agents.internal/a2a/sovereign",
                "required_skill": "sovereign-policy-assessment",
            }
        },
    }


def _read_projected_ksa_token() -> str:
    if KSA_TOKEN_PATH.exists():
        return KSA_TOKEN_PATH.read_text(encoding="utf-8").strip()
    return "missing-ksa-token"


def _format_traceparent() -> str:
    ctx = trace.get_current_span().get_span_context()
    if ctx and ctx.is_valid:
        return f"00-{ctx.trace_id:032x}-{ctx.span_id:016x}-{int(ctx.trace_flags):02x}"
    return f"00-{uuid.uuid4().hex}-{uuid.uuid4().hex[:16]}-01"


def _extract_upstream_status(exc: BaseException) -> int | None:
    if isinstance(exc, httpx.HTTPStatusError) and exc.response is not None:
        if exc.response.status_code in (400, 401, 403, 429):
            return exc.response.status_code
    for attr in ("status_code", "code"):
        val = getattr(exc, attr, None)
        if isinstance(val, int) and val in (400, 401, 403, 429):
            return val
    msg = str(exc)
    for code in (400, 401, 403, 429):
        if (
            f"Error code: {code}" in msg
            or f"HTTP {code}" in msg
            or f"Client error '{code} " in msg
            or f"{code} PERMISSION_DENIED" in msg
        ):
            return code
    return None


def _extract_upstream_detail(exc: BaseException) -> str:
    if isinstance(exc, httpx.HTTPStatusError) and exc.response is not None:
        body = exc.response.text.strip()
        if body:
            return f"{str(exc).splitlines()[0][:120]} | {body[:200]}"
    return str(exc).splitlines()[0][:280]


async def _close_agent_llm(agent: Agent | None) -> None:
    if agent is not None and isinstance(agent.model, ApigeeLlm):
        try:
            await agent.model._completions_http_client.aclose()
        except Exception:  # pylint: disable=broad-exception-caught
            pass


async def _send_a2a_sovereign_assessment(
    assessment_context: str, category: str, triggered_by: str
) -> dict:
    peer_cfg = _load_peer_registry_config()
    sovereign_peer = peer_cfg.get("peers", {}).get("adk-sovereign-agent", {})
    target_url = sovereign_peer.get(
        "a2a_egress_url", f"{EGRESS_PROXY_BASE}/a2a/sovereign"
    )
    discovery_source = peer_cfg.get("discovery_source", "configmap")

    with tracer.start_as_current_span(
        "a2a.client.message_send",
        kind=SpanKind.CLIENT,
        attributes={
            "a2a.discovery_source": discovery_source,
            "a2a.peer_agent": "adk-sovereign-agent",
            "a2a.skill_id": "sovereign-policy-assessment",
            "a2a.triggered_by": triggered_by,
            "data_classification": "sovereign",
            "peer.service": "apigee-a2a-dispatch",
            "rpc.method": "message/send",
            "rpc.system": "a2a_jsonrpc",
        },
    ) as a2a_span:
        ksa_jwt = _read_projected_ksa_token()
        outbound_traceparent = _format_traceparent()
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Bearer {ksa_jwt}",
            "x-agent-ksa-token": ksa_jwt,
            "x-data-classification": "sovereign",
            "traceparent": outbound_traceparent,
        }
        rpc_id = str(uuid.uuid4())
        rpc_body = {
            "jsonrpc": "2.0",
            "id": rpc_id,
            "method": "message/send",
            "params": {
                "message": {
                    "kind": "message",
                    "messageId": str(uuid.uuid4()),
                    "role": "user",
                    "parts": [
                        {
                            "kind": "text",
                            "text": (
                                f"Assess sovereign compliance policy for category "
                                f"'{category}'. Context: {assessment_context}"
                            ),
                        }
                    ],
                }
            },
        }
        async with httpx.AsyncClient(timeout=45.0) as client:
            resp = await client.post(target_url, headers=headers, json=rpc_body)
            a2a_span.set_attribute("http.response.status_code", resp.status_code)
            caller_app = resp.headers.get("x-a2a-caller-app", "")
            apigee_product = resp.headers.get("x-a2a-product", "")
            verified_sub = resp.headers.get("x-a2a-verified-sub", "")
            peer_llm_backend = resp.headers.get("x-agent-llm-backend", "")
            peer_trace_id = resp.headers.get("x-agent-trace-id", "")

            if caller_app:
                a2a_span.set_attribute("apigee.caller_app", caller_app)
            if apigee_product:
                a2a_span.set_attribute("apigee.product", apigee_product)
            if verified_sub:
                a2a_span.set_attribute("apigee.verified_sub", verified_sub)
            if peer_llm_backend:
                a2a_span.set_attribute("a2a.peer_llm_backend", peer_llm_backend)

            meta = {
                "apigee_caller_app": caller_app,
                "apigee_product": apigee_product,
                "apigee_verified_sub": verified_sub,
                "discovery_source": discovery_source,
                "http_status": resp.status_code,
                "peer_agent": "adk-sovereign-agent",
                "peer_llm_backend": peer_llm_backend,
                "peer_trace_id": peer_trace_id,
                "target_url": target_url,
                "triggered_by": triggered_by,
            }
            if resp.status_code != 200:
                a2a_span.set_status(
                    Status(StatusCode.ERROR, description=f"HTTP_{resp.status_code}")
                )
                LAST_A2A_META.set(meta)
                raise UpstreamA2AGatewayError(resp.status_code, meta)

            body_json = resp.json()
            result_meta = (
                body_json.get("result", {}).get("metadata", {})
                if isinstance(body_json, dict)
                else {}
            )
            if not meta["peer_llm_backend"] and result_meta.get("llm_backend"):
                meta["peer_llm_backend"] = result_meta["llm_backend"]
            if not meta["peer_trace_id"] and result_meta.get("trace_id"):
                meta["peer_trace_id"] = result_meta["trace_id"]
            LAST_A2A_META.set(meta)
            a2a_span.set_status(Status(StatusCode.OK))
            return body_json


async def delegate_sovereign_policy_assessment(category: str) -> dict:
    """Delegates sovereign compliance policy evaluation over Apigee-mediated A2A to adk-sovereign-agent.

    Args:
      category: Sovereign policy category to assess ('residency', 'identity', or 'telemetry').

    Returns:
      A2A JSON-RPC 2.0 response payload from adk-sovereign-agent.
    """
    state = TURN_TELEMETRY.get()
    if state is not None:
        state.tools_invoked.append("delegate_sovereign_policy_assessment")
    turn_prompt = CURRENT_TURN_PROMPT.get() or f"Policy assessment for {category}"
    return await _send_a2a_sovereign_assessment(
        turn_prompt, category, triggered_by="adk_tool_call"
    )


def _build_orchestrator_agent(
    data_classification: str,
    traceparent: str,
    requested_model: str,
    client_mode: str,
    httpx_client: httpx.AsyncClient | None,
    enforce_a2a: bool = True,
    enable_cloud_mcp: bool = False,
    cloud_mcp_targets: list[str] | None = None,
    enable_apigee_mcp: bool = False,
    model_tier_hint: str = "",
    streaming: bool = False,
) -> tuple[Agent, list[McpToolset]]:
    ksa_jwt = _read_projected_ksa_token()
    base_headers = {
        "Authorization": f"Bearer {ksa_jwt}",
        "x-agent-ksa-token": ksa_jwt,
        "x-data-classification": data_classification,
        "traceparent": traceparent,
    }
    if model_tier_hint:
        base_headers["x-model-tier"] = model_tier_hint

    if client_mode == "google_genai":
        llm: object = GatewayGemini(
            model=requested_model,
            base_url=EGRESS_PROXY_BASE,
            api_key=ksa_jwt,
            headers=base_headers,
            httpx_async_client=httpx_client,
        )
    else:
        apigee_model = (
            requested_model
            if requested_model.startswith("apigee/")
            else f"apigee/openai/{requested_model}"
        )
        apigee_llm = ApigeeLlm(
            model=apigee_model,
            proxy_url=f"{EGRESS_PROXY_BASE}/v1",
            custom_headers=base_headers,
        )
        apigee_llm._completions_http_client._client.event_hooks["response"].append(
            _on_httpx_response
        )
        orig_construct_payload = apigee_llm._completions_http_client._construct_payload

        def _construct_payload(llm_request: object, stream: bool) -> dict[str, object]:
            payload = orig_construct_payload(llm_request, stream)
            if stream:
                payload["stream_options"] = {"include_usage": True}
                if data_classification in ("cloud-eligible", "public"):
                    payload["reasoning_effort"] = "minimal"
            return payload

        apigee_llm._completions_http_client._construct_payload = _construct_payload
        llm = apigee_llm

    tools: list[object] = []
    mcp_toolsets: list[McpToolset] = []

    if enforce_a2a:
        tools.append(delegate_sovereign_policy_assessment)

    if enable_cloud_mcp and data_classification in ("cloud-eligible", "public"):
        targets = cloud_mcp_targets or ["bigquery", "storage"]
        if "bigquery" in targets:
            bq_mcp = McpToolset(
                connection_params=StreamableHTTPConnectionParams(
                    url=f"{EGRESS_PROXY_BASE}/mcp-bigquery",
                    headers=base_headers,
                    timeout=20.0,
                ),
                tool_name_prefix="bq_",
            )
            tools.append(bq_mcp)
            mcp_toolsets.append(bq_mcp)
        if "storage" in targets:
            gcs_mcp = McpToolset(
                connection_params=StreamableHTTPConnectionParams(
                    url=f"{EGRESS_PROXY_BASE}/mcp-storage",
                    headers=base_headers,
                    timeout=20.0,
                ),
                tool_name_prefix="gcs_",
            )
            tools.append(gcs_mcp)
            mcp_toolsets.append(gcs_mcp)

    if enable_apigee_mcp:
        apigee_mcp = McpToolset(
            connection_params=StreamableHTTPConnectionParams(
                url=f"{EGRESS_PROXY_BASE}/mcp",
                headers=base_headers,
                timeout=15.0,
            ),
            tool_name_prefix="apigee_catalog_",
        )
        tools.append(apigee_mcp)
        mcp_toolsets.append(apigee_mcp)

    if enforce_a2a:
        instruction = (
            "You are the Operations Incident Triage Orchestrator on Distributed Cloud "
            "software only. For every triage request, you MUST first invoke "
            "delegate_sovereign_policy_assessment with the most relevant category "
            "('residency', 'identity', or 'telemetry') to obtain an authoritative "
            "sovereign compliance assessment from adk-sovereign-agent, and then "
            "synthesize a concise operational recommendation."
        )
    elif enable_cloud_mcp or enable_apigee_mcp:
        instruction = (
            "You are the Hybrid Cloud Operations Assistant on Distributed Cloud "
            "software only. Use the available MCP tools (`bq_*`, `gcs_*`, or "
            "`apigee_catalog_*`) to inspect the requested datasets, Cloud Storage "
            "buckets, or gateway catalog resources, and synthesize a concise answer."
        )
    else:
        instruction = (
            "You are the Hybrid Cloud Operations Assistant on Distributed Cloud "
            "software only. Provide concise, accurate operational responses."
        )

    agent = Agent(
        name="adk_ops_orchestrator",
        model=llm,
        description=AGENT_CARD["description"],
        instruction=instruction,
        tools=tools,
        code_executor=None,
    )
    return agent, mcp_toolsets


app = FastAPI(title=APP_NAME, version=AGENT_CARD.get("version", "0.2.0"))


@app.get("/healthz")
async def healthz() -> dict:
    peer_cfg = _load_peer_registry_config()
    return {
        "status": "ok",
        "agent": APP_NAME,
        "version": AGENT_CARD.get("version", "0.2.0"),
        "cloud_model_alias": CLOUD_MODEL_ALIAS,
        "code_executor_enabled": False,
        "default_client_mode": ADK_CLIENT_MODE,
        "discovery_source": peer_cfg.get("discovery_source", "unknown"),
        "egress_proxy_base": EGRESS_PROXY_BASE,
        "ksa_token_mounted": KSA_TOKEN_PATH.exists(),
        "sovereign_model_alias": SOVEREIGN_MODEL_ALIAS,
        "streaming_supported": True,
    }


@app.get("/metrics")
async def metrics() -> PlainTextResponse:
    lines = [
        "# HELP adk_agent_requests_total Total agent invocation requests.",
        "# TYPE adk_agent_requests_total counter",
    ]
    if not REQUEST_COUNTERS:
        lines.append(
            f'adk_agent_requests_total{{agent="{APP_NAME}",classification="sovereign",status="init"}} 0'
        )
    for (cls_label, status_label), count in sorted(REQUEST_COUNTERS.items()):
        lines.append(
            f'adk_agent_requests_total{{agent="{APP_NAME}",classification="{cls_label}",status="{status_label}"}} {count}'
        )
    return PlainTextResponse("\n".join(lines) + "\n")


@app.get("/.well-known/agent-card.json")
@app.get("/.well-known/agent.json")
async def get_agent_card() -> dict:
    return AGENT_CARD


def _parse_ops_request(request: Request, payload: dict) -> dict[str, object]:
    header_cls = request.headers.get("x-data-classification", "").strip().lower()
    body_cls = str(payload.get("data_classification", "")).strip().lower()
    classification = header_cls or body_cls or "sovereign"
    if classification not in (
        "sovereign",
        "confidential",
        "restricted",
        "cloud-eligible",
        "public",
    ):
        classification = "sovereign"

    prompt_text = payload.get("prompt")
    if not prompt_text and isinstance(payload.get("params"), dict):
        parts = payload["params"].get("message", {}).get("parts", [])
        prompt_text = " ".join(
            p.get("text", "") for p in parts if isinstance(p, dict)
        ).strip()
    if not prompt_text:
        prompt_text = (
            "Triage cluster residency posture and delegate sovereign policy check."
        )

    default_alias = (
        CLOUD_MODEL_ALIAS
        if classification in ("cloud-eligible", "public")
        else SOVEREIGN_MODEL_ALIAS
    )
    requested_model = str(
        payload.get("model_alias") or payload.get("model") or default_alias
    ).strip()
    client_mode = str(payload.get("client_mode") or ADK_CLIENT_MODE).strip().lower()
    if client_mode not in ("apigee_openai", "google_genai"):
        client_mode = "apigee_openai"

    model_tier_hint = (
        request.headers.get("x-model-tier", "").strip()
        or str(payload.get("model_tier", "")).strip()
    )
    raw_targets = payload.get("cloud_mcp_targets")
    cloud_mcp_targets = (
        [str(t).strip().lower() for t in raw_targets]
        if isinstance(raw_targets, list)
        else ["bigquery", "storage"]
    )

    return {
        "prompt_text": prompt_text,
        "classification": classification,
        "user_id": str(payload.get("user_id", "apigee-northbound-ops-caller")),
        "enforce_a2a": bool(payload.get("enforce_a2a_delegation", True)),
        "default_category": str(payload.get("policy_category", "residency")),
        "requested_model": requested_model,
        "client_mode": client_mode,
        "enable_cloud_mcp": bool(payload.get("enable_cloud_mcp", False)),
        "cloud_mcp_targets": cloud_mcp_targets,
        "enable_apigee_mcp": bool(payload.get("enable_apigee_mcp", False)),
        "model_tier_hint": model_tier_hint,
    }


@app.post("/invoke")
@app.post("/")
async def invoke(request: Request) -> JSONResponse:
    carrier = {k.lower(): v for k, v in request.headers.items()}
    parent_ctx = PROPAGATOR.extract(carrier=carrier)
    payload = await request.json()
    parsed = _parse_ops_request(request, payload)

    prompt_text = str(parsed["prompt_text"])
    classification = str(parsed["classification"])
    user_id = str(parsed["user_id"])
    enforce_a2a = bool(parsed["enforce_a2a"])
    default_category = str(parsed["default_category"])
    requested_model = str(parsed["requested_model"])
    client_mode = str(parsed["client_mode"])
    enable_cloud_mcp = bool(parsed["enable_cloud_mcp"])
    cloud_mcp_targets = list(parsed["cloud_mcp_targets"])  # type: ignore[arg-type]
    enable_apigee_mcp = bool(parsed["enable_apigee_mcp"])
    model_tier_hint = str(parsed["model_tier_hint"])

    turn_state = _TurnTelemetry()
    tok_state = TURN_TELEMETRY.set(turn_state)
    tok_a2a = LAST_A2A_META.set(None)
    tok_prompt = CURRENT_TURN_PROMPT.set(prompt_text)
    mcp_toolsets: list[McpToolset] = []
    httpx_client = httpx.AsyncClient(
        timeout=60.0, event_hooks={"response": [_on_httpx_response]}
    )
    try:
        with tracer.start_as_current_span(
            "gen_ai.agent.invoke",
            context=parent_ctx,
            kind=SpanKind.SERVER,
            attributes={
                "data_classification": classification,
                "gen_ai.system": "google_adk",
                "gen_ai.agent.id": APP_NAME,
                "gen_ai.agent.name": APP_NAME,
                "gen_ai.request.model": requested_model,
                "adk.client_mode": client_mode,
                "agent.egress_proxy": EGRESS_PROXY_BASE,
                "agent.code_executor_enabled": False,
            },
        ) as span:
            span_ctx = span.get_span_context()
            trace_id_hex = f"{span_ctx.trace_id:032x}"
            traceparent = _format_traceparent()

            agent, mcp_toolsets = _build_orchestrator_agent(
                classification,
                traceparent,
                requested_model,
                client_mode,
                httpx_client,
                enforce_a2a=enforce_a2a,
                enable_cloud_mcp=enable_cloud_mcp,
                cloud_mcp_targets=cloud_mcp_targets,
                enable_apigee_mcp=enable_apigee_mcp,
                model_tier_hint=model_tier_hint,
                streaming=False,
            )
            runner = Runner(
                agent=agent,
                app_name=APP_NAME,
                session_service=session_service,
            )
            session = await session_service.create_session(
                app_name=APP_NAME, user_id=user_id
            )
            content = genai_types.Content(
                role="user",
                parts=[genai_types.Part.from_text(text=prompt_text)],
            )

            try:
                final_chunks: list[str] = []
                async for event in runner.run_async(
                    user_id=user_id,
                    session_id=session.id,
                    new_message=content,
                ):
                    if event.content and event.content.parts:
                        for part in event.content.parts:
                            fn_call = getattr(part, "function_call", None)
                            if fn_call and getattr(fn_call, "name", None):
                                turn_state.tools_invoked.append(str(fn_call.name))
                    if (
                        event.is_final_response()
                        and event.content
                        and event.content.parts
                    ):
                        for part in event.content.parts:
                            if getattr(part, "text", None):
                                final_chunks.append(part.text)

                if LAST_A2A_META.get() is None and enforce_a2a:
                    a2a_resp = await _send_a2a_sovereign_assessment(
                        prompt_text,
                        default_category,
                        triggered_by="deterministic_guard",
                    )
                    sovereign_parts = (
                        a2a_resp.get("result", {}).get("parts", [])
                        if isinstance(a2a_resp, dict)
                        else []
                    )
                    sovereign_text = " ".join(
                        p.get("text", "")
                        for p in sovereign_parts
                        if isinstance(p, dict)
                    ).strip()
                    if sovereign_text:
                        final_chunks.append(
                            f"[Sovereign A2A Assessment]: {sovereign_text}"
                        )

                routed_backend = turn_state.llm_backend
                if routed_backend == "unknown":
                    routed_backend = (
                        "vertex-gemini-3.5-flash"
                        if classification in ("cloud-eligible", "public")
                        else "local-vllm"
                    )
                resolved_model = turn_state.resolved_model or (
                    "google/gemini-3.5-flash"
                    if classification in ("cloud-eligible", "public")
                    else SOVEREIGN_MODEL_NAME
                )
                routed_tier = turn_state.routed_tier or (
                    "cloud-burst-gemini"
                    if classification in ("cloud-eligible", "public")
                    else "local-vllm"
                )
                a2a_meta = LAST_A2A_META.get() or {}
                span.set_attribute("llm.routed_backend", routed_backend)
                span.set_attribute("llm.resolved_model", resolved_model)
                span.set_attribute("http.response.status_code", 200)
                span.set_status(Status(StatusCode.OK))
                REQUEST_COUNTERS[(classification, "200")] += 1
                tracer_provider.force_flush(timeout_millis=3000)

                resp_headers = {
                    "X-Agent-Trace-Id": trace_id_hex,
                    "X-Agent-LLM-Backend": routed_backend,
                    "X-HCA-Resolved-Model": resolved_model,
                    "X-HCA-Routed-Tier": routed_tier,
                }
                for qk, qv in turn_state.quota_headers.items():
                    resp_headers[qk] = qv

                return JSONResponse(
                    status_code=200,
                    headers=resp_headers,
                    content={
                        "status": "ok",
                        "agent": APP_NAME,
                        "client_mode": client_mode,
                        "data_classification": classification,
                        "model_alias": requested_model,
                        "model": resolved_model,
                        "llm_backend": routed_backend,
                        "routed_tier": routed_tier,
                        "tools_invoked": turn_state.tools_invoked,
                        "trace_id": trace_id_hex,
                        "a2a_subcall": a2a_meta,
                        "response": "\n".join(final_chunks),
                    },
                )
            except UpstreamA2AGatewayError as a2a_err:
                span.set_attribute("http.response.status_code", a2a_err.status_code)
                span.set_attribute("error.type", "UpstreamA2AGatewayError")
                span.set_status(
                    Status(
                        StatusCode.ERROR,
                        description=f"A2A_HTTP_{a2a_err.status_code}",
                    )
                )
                REQUEST_COUNTERS[(classification, str(a2a_err.status_code))] += 1
                tracer_provider.force_flush(timeout_millis=3000)
                return JSONResponse(
                    status_code=a2a_err.status_code,
                    headers={"X-Agent-Trace-Id": trace_id_hex},
                    content={
                        "status": "a2a_gateway_rejected",
                        "agent": APP_NAME,
                        "data_classification": classification,
                        "trace_id": trace_id_hex,
                        "a2a_subcall": a2a_err.meta,
                    },
                )
            except Exception as exc:  # pylint: disable=broad-exception-caught
                a2a_meta = LAST_A2A_META.get()
                if isinstance(a2a_meta, dict) and a2a_meta.get("http_status") in (
                    401,
                    403,
                    429,
                ):
                    code = int(a2a_meta["http_status"])
                    span.set_attribute("http.response.status_code", code)
                    span.set_status(
                        Status(StatusCode.ERROR, description=f"A2A_HTTP_{code}")
                    )
                    REQUEST_COUNTERS[(classification, str(code))] += 1
                    tracer_provider.force_flush(timeout_millis=3000)
                    return JSONResponse(
                        status_code=code,
                        headers={"X-Agent-Trace-Id": trace_id_hex},
                        content={
                            "status": "a2a_gateway_rejected",
                            "agent": APP_NAME,
                            "data_classification": classification,
                            "trace_id": trace_id_hex,
                            "a2a_subcall": a2a_meta,
                        },
                    )
                err_type = type(exc).__name__
                err_summary = _extract_upstream_detail(exc)
                upstream_code = _extract_upstream_status(exc)
                status_code = upstream_code if upstream_code is not None else 503
                span.set_attribute("http.response.status_code", status_code)
                span.set_attribute("error.type", err_type)
                span.set_status(Status(StatusCode.ERROR, description=err_type))
                REQUEST_COUNTERS[(classification, str(status_code))] += 1
                tracer_provider.force_flush(timeout_millis=3000)
                err_headers = {"X-Agent-Trace-Id": trace_id_hex}
                for qk, qv in turn_state.quota_headers.items():
                    err_headers[qk] = qv
                return JSONResponse(
                    status_code=status_code,
                    headers=err_headers,
                    content={
                        "status": (
                            "gateway_policy_rejected"
                            if upstream_code is not None
                            else "upstream_gateway_unavailable"
                        ),
                        "agent": APP_NAME,
                        "client_mode": client_mode,
                        "data_classification": classification,
                        "model_alias": requested_model,
                        "trace_id": trace_id_hex,
                        "mediated_via": (
                            f"{EGRESS_PROXY_BASE}/v1beta"
                            if client_mode == "google_genai"
                            else f"{EGRESS_PROXY_BASE}/v1"
                        ),
                        "zero_bypass_enforced": True,
                        "upstream_http_status": status_code,
                        "error_type": err_type,
                        "detail": err_summary,
                    },
                )
    finally:
        await _close_agent_llm(locals().get("agent"))
        for ts in mcp_toolsets:
            try:
                await ts.close()
            except Exception:  # pylint: disable=broad-exception-caught
                pass
        await httpx_client.aclose()
        TURN_TELEMETRY.reset(tok_state)
        LAST_A2A_META.reset(tok_a2a)
        CURRENT_TURN_PROMPT.reset(tok_prompt)


@app.post("/invoke-stream")
@app.post("/invoke/stream")
async def invoke_stream(request: Request) -> StreamingResponse:
    carrier = {k.lower(): v for k, v in request.headers.items()}
    parent_ctx = PROPAGATOR.extract(carrier=carrier)
    payload = await request.json()
    parsed = _parse_ops_request(request, payload)

    prompt_text = str(parsed["prompt_text"])
    classification = str(parsed["classification"])
    user_id = str(parsed["user_id"])
    requested_model = str(parsed["requested_model"])
    client_mode = str(parsed["client_mode"])
    model_tier_hint = str(parsed["model_tier_hint"])
    trace_seed_hex = uuid.uuid4().hex

    async def _sse_generator() -> AsyncIterator[str]:
        turn_state = _TurnTelemetry()
        tok_state = TURN_TELEMETRY.set(turn_state)
        httpx_client = httpx.AsyncClient(
            timeout=120.0, event_hooks={"response": [_on_httpx_response]}
        )
        mcp_toolsets: list[McpToolset] = []
        agent: Agent | None = None
        try:
            with tracer.start_as_current_span(
                "gen_ai.agent.invoke_stream",
                context=parent_ctx,
                kind=SpanKind.SERVER,
                attributes={
                    "data_classification": classification,
                    "gen_ai.system": "google_adk",
                    "gen_ai.agent.id": APP_NAME,
                    "gen_ai.request.model": requested_model,
                    "adk.client_mode": client_mode,
                    "adk.streaming": True,
                },
            ) as span:
                trace_id_hex = f"{span.get_span_context().trace_id:032x}"
                traceparent = _format_traceparent()
                agent, mcp_toolsets = _build_orchestrator_agent(
                    classification,
                    traceparent,
                    requested_model,
                    client_mode,
                    httpx_client,
                    enforce_a2a=False,
                    enable_cloud_mcp=False,
                    enable_apigee_mcp=False,
                    model_tier_hint=model_tier_hint,
                    streaming=True,
                )
                runner = Runner(
                    agent=agent,
                    app_name=APP_NAME,
                    session_service=session_service,
                )
                session = await session_service.create_session(
                    app_name=APP_NAME, user_id=user_id
                )
                content = genai_types.Content(
                    role="user",
                    parts=[genai_types.Part.from_text(text=prompt_text)],
                )
                seq = 0
                emitted_partials = False
                async for event in runner.run_async(
                    user_id=user_id,
                    session_id=session.id,
                    new_message=content,
                    run_config=RunConfig(streaming_mode=StreamingMode.SSE),
                ):
                    is_partial = bool(getattr(event, "partial", False))
                    if event.content and event.content.parts:
                        for part in event.content.parts:
                            txt = getattr(part, "text", None)
                            if txt:
                                if is_partial:
                                    emitted_partials = True
                                    seq += 1
                                    yield f"data: {json.dumps({'seq': seq, 'partial': True, 'chunk': txt})}\n\n"
                                elif not emitted_partials and event.is_final_response():
                                    seq += 1
                                    yield f"data: {json.dumps({'seq': seq, 'partial': False, 'chunk': txt})}\n\n"

                routed_backend = (
                    turn_state.llm_backend
                    if turn_state.llm_backend != "unknown"
                    else (
                        "vertex-gemini-3.5-flash"
                        if classification in ("cloud-eligible", "public")
                        else "local-vllm"
                    )
                )
                resolved_model = turn_state.resolved_model or (
                    "google/gemini-3.5-flash"
                    if classification in ("cloud-eligible", "public")
                    else SOVEREIGN_MODEL_NAME
                )
                routed_tier = turn_state.routed_tier or (
                    "cloud-burst-gemini"
                    if classification in ("cloud-eligible", "public")
                    else "local-vllm"
                )
                REQUEST_COUNTERS[(classification, "200")] += 1
                span.set_status(Status(StatusCode.OK))
                summary = {
                    "done": True,
                    "agent": APP_NAME,
                    "client_mode": client_mode,
                    "data_classification": classification,
                    "model_alias": requested_model,
                    "resolved_model": resolved_model,
                    "llm_backend": routed_backend,
                    "routed_tier": routed_tier,
                    "chunk_count": seq,
                    "trace_id": trace_id_hex,
                }
                yield f"data: {json.dumps(summary)}\n\n"
                yield "data: [DONE]\n\n"
        except Exception as exc:  # pylint: disable=broad-exception-caught
            err_payload = {
                "error": True,
                "agent": APP_NAME,
                "error_type": type(exc).__name__,
                "upstream_http_status": _extract_upstream_status(exc) or 503,
                "detail": _extract_upstream_detail(exc),
            }
            yield f"data: {json.dumps(err_payload)}\n\n"
            yield "data: [DONE]\n\n"
        finally:
            await _close_agent_llm(agent)
            for ts in mcp_toolsets:
                try:
                    await ts.close()
                except Exception:  # pylint: disable=broad-exception-caught
                    pass
            await httpx_client.aclose()
            TURN_TELEMETRY.reset(tok_state)

    return StreamingResponse(
        _sse_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "X-Agent-Stream-Seed": trace_seed_hex,
        },
    )
