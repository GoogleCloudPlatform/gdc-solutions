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

"""Hardened Google ADK Sovereign Policy Agent for Distributed Cloud software only (v0.2.0).

Security and architectural invariants:
  1. Zero code execution or shell tools: `code_executor=None`, no subprocess/exec/skill-script tools.
  2. Strict proxy mediation: all LLM (`ApigeeLlm` OpenAI `/v1/chat/completions` facade and native `Gemini` `/v1beta` facade) and MCP
     (`/mcp-toolbox` and Apigee built-in `/mcp`) HTTP calls target ONLY the local Envoy egress proxy
     (`http://agent-egress-envoy.agent-workloads.svc.cluster.local:15001`), injecting the kubelet-rotated
     projected KSA JWT (`x-agent-ksa-token`) and W3C `traceparent`.
  3. End-to-end distributed tracing and sovereign telemetry hygiene: extracts incoming W3C
     `traceparent` headers so A2A and northbound calls attach to the caller's `trace_id`, while disabling GenAI
     and ADK message/tool content capture (`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false` and
     `ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=false`).
  4. AI Gateway capabilities: decoupled virtual model aliases (`MODEL_ALIAS=enterprise-sovereign`),
     first-party ADK dual SDK facade (`ADK_CLIENT_MODE=apigee_openai|google_genai` with zero `litellm` dependency),
     ADK `McpToolset` discovery against Apigee `/mcp`, and real-time SSE streaming (`/invoke-stream`).
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

APP_NAME = "adk-sovereign-agent"
AGENT_CARD_PATH = Path(os.getenv("AGENT_CARD_PATH", "/app/agent-card.json"))
KSA_TOKEN_PATH = Path(
    os.getenv("KSA_TOKEN_PATH", "/var/run/secrets/tokens/apigee-ksa/token")
)
EGRESS_PROXY_BASE = os.getenv(
    "EGRESS_PROXY_BASE",
    "http://agent-egress-envoy.agent-workloads.svc.cluster.local:15001",
).rstrip("/")
OTLP_TRACES_ENDPOINT = os.getenv(
    "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
    "http://otel-collector.otel-system.svc.cluster.local:4318/v1/traces",
)
MODEL_ALIAS = os.getenv("MODEL_ALIAS", "enterprise-sovereign")
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

QUOTA_HEADER_NAMES = (
    "x-tokenquota-limit",
    "x-tokenquota-used",
    "x-tokenquota-remaining",
    "x-tokenquota-reset",
    "retry-after",
)


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
        "service.version": AGENT_CARD.get("version", "0.1.2"),
        "gen_ai.agent.id": APP_NAME,
        "gen_ai.agent.name": APP_NAME,
    }
)
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_TRACES_ENDPOINT, timeout=5))
)
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer("hybrid_cloud_agents.adk", AGENT_CARD.get("version", "0.1.2"))

session_service = InMemorySessionService()


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


async def lookup_sovereign_policy_via_gateway(category: str) -> dict:
    """Queries synthetic sovereign compliance policies strictly via Envoy -> Apigee `/mcp-toolbox`.

    Args:
      category: Policy category to filter on (for example, 'residency', 'identity', or 'telemetry').

    Returns:
      JSON result from MCP Toolbox mediated through Apigee hybrid.
    """
    state = TURN_TELEMETRY.get()
    if state is not None:
        state.tools_invoked.append("lookup_sovereign_policy_via_gateway")
    with tracer.start_as_current_span(
        "gen_ai.tool.mcp_lookup",
        kind=SpanKind.CLIENT,
        attributes={
            "data_classification": "sovereign",
            "mcp.tool.name": "search_sovereign_policies_by_category",
            "peer.service": "apigee-mcp-toolbox",
        },
    ) as mcp_span:
        ksa_jwt = _read_projected_ksa_token()
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Authorization": f"Bearer {ksa_jwt}",
            "x-agent-ksa-token": ksa_jwt,
            "x-data-classification": "sovereign",
            "traceparent": _format_traceparent(),
        }
        rpc_body = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "tools/call",
            "params": {
                "name": "search_sovereign_policies_by_category",
                "arguments": {"category": category},
            },
        }
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(
                f"{EGRESS_PROXY_BASE}/mcp-toolbox", headers=headers, json=rpc_body
            )
            mcp_span.set_attribute("http.response.status_code", resp.status_code)
            resp.raise_for_status()
            return resp.json()


async def _probe_cloud_mcp_isolation(classification: str) -> int:
    """Verifies that Apigee denies `sovereign-agents-app` access to `/mcp-bigquery`."""
    ksa_jwt = _read_projected_ksa_token()
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {ksa_jwt}",
        "x-agent-ksa-token": ksa_jwt,
        "x-data-classification": classification,
        "traceparent": _format_traceparent(),
    }
    rpc_body = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "tools/list",
        "params": {},
    }
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            f"{EGRESS_PROXY_BASE}/mcp-bigquery", headers=headers, json=rpc_body
        )
        return resp.status_code


def _build_hardened_agent(
    data_classification: str,
    traceparent: str,
    requested_model: str,
    client_mode: str,
    httpx_client: httpx.AsyncClient | None,
    enable_apigee_mcp: bool = False,
    streaming: bool = False,
) -> tuple[Agent, list[McpToolset]]:
    ksa_jwt = _read_projected_ksa_token()
    extra_headers = {
        "Authorization": f"Bearer {ksa_jwt}",
        "x-agent-ksa-token": ksa_jwt,
        "x-data-classification": data_classification,
        "traceparent": traceparent,
    }
    if client_mode == "google_genai":
        llm: object = GatewayGemini(
            model=requested_model,
            base_url=EGRESS_PROXY_BASE,
            api_key=ksa_jwt,
            headers=extra_headers,
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
            custom_headers=extra_headers,
        )
        apigee_llm._completions_http_client._client.event_hooks["response"].append(
            _on_httpx_response
        )
        orig_construct_payload = apigee_llm._completions_http_client._construct_payload

        def _construct_payload(llm_request: object, stream: bool) -> dict[str, object]:
            payload = orig_construct_payload(llm_request, stream)
            if stream:
                payload["stream_options"] = {"include_usage": True}
            return payload

        apigee_llm._completions_http_client._construct_payload = _construct_payload
        llm = apigee_llm

    tools: list[object] = [] if streaming else [lookup_sovereign_policy_via_gateway]
    mcp_toolsets: list[McpToolset] = []
    instruction = (
        "You are a hardened sovereign compliance policy assistant running on "
        "Distributed Cloud software only. Use lookup_sovereign_policy_via_gateway "
        "when policy grounding is needed, and provide concise, accurate answers."
    )
    if enable_apigee_mcp:
        apigee_mcp = McpToolset(
            connection_params=StreamableHTTPConnectionParams(
                url=f"{EGRESS_PROXY_BASE}/mcp",
                headers=extra_headers,
                timeout=15.0,
            ),
            tool_name_prefix="apigee_catalog_",
        )
        tools.append(apigee_mcp)
        mcp_toolsets.append(apigee_mcp)
        instruction = (
            "You are a hardened sovereign compliance assistant on Distributed Cloud "
            "software only. When asked about approved models, model tiers, or gateway "
            "topology status in the catalog, invoke the discovered `apigee_catalog_*` "
            "MCP tools first and summarize their exact output concisely."
        )

    agent = Agent(
        name="adk_sovereign_agent",
        model=llm,
        description=AGENT_CARD["description"],
        instruction=instruction,
        tools=tools,
        code_executor=None,
    )
    return agent, mcp_toolsets


app = FastAPI(title=APP_NAME, version=AGENT_CARD.get("version", "0.1.2"))


@app.get("/healthz")
async def healthz() -> dict:
    return {
        "status": "ok",
        "agent": APP_NAME,
        "version": AGENT_CARD.get("version", "0.1.2"),
        "code_executor_enabled": False,
        "default_client_mode": ADK_CLIENT_MODE,
        "default_model_alias": MODEL_ALIAS,
        "egress_proxy_base": EGRESS_PROXY_BASE,
        "ksa_token_mounted": KSA_TOKEN_PATH.exists(),
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


async def _execute_adk_turn(
    prompt_text: str,
    classification: str,
    user_id: str,
    parent_ctx: object,
    is_a2a_rpc: bool,
    rpc_id: str | int | None,
    requested_model: str,
    client_mode: str,
    enable_apigee_mcp: bool,
    enable_cloud_mcp: bool,
) -> JSONResponse:
    turn_state = _TurnTelemetry()
    tok_state = TURN_TELEMETRY.set(turn_state)
    mcp_toolsets: list[McpToolset] = []
    httpx_client = httpx.AsyncClient(
        timeout=45.0, event_hooks={"response": [_on_httpx_response]}
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
                "a2a.jsonrpc": is_a2a_rpc,
            },
        ) as span:
            span_ctx = span.get_span_context()
            trace_id_hex = f"{span_ctx.trace_id:032x}"
            traceparent = _format_traceparent()

            cloud_mcp_probe_status: int | None = None
            if enable_cloud_mcp:
                cloud_mcp_probe_status = await _probe_cloud_mcp_isolation(
                    classification
                )

            agent, mcp_toolsets = _build_hardened_agent(
                classification,
                traceparent,
                requested_model,
                client_mode,
                httpx_client,
                enable_apigee_mcp=enable_apigee_mcp,
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

                routed_backend = turn_state.llm_backend
                if routed_backend == "unknown":
                    routed_backend = (
                        "local-vllm-genai-facade"
                        if client_mode == "google_genai"
                        else "local-vllm"
                    )
                resolved_model = turn_state.resolved_model or SOVEREIGN_MODEL_NAME
                routed_tier = turn_state.routed_tier or "local-vllm"

                span.set_attribute("llm.routed_backend", routed_backend)
                span.set_attribute("llm.resolved_model", resolved_model)
                span.set_attribute("http.response.status_code", 200)
                span.set_status(Status(StatusCode.OK))
                REQUEST_COUNTERS[(classification, "200")] += 1
                tracer_provider.force_flush(timeout_millis=3000)

                answer_text = "\n".join(final_chunks)
                resp_headers = {
                    "X-Agent-Trace-Id": trace_id_hex,
                    "X-Agent-LLM-Backend": routed_backend,
                    "X-HCA-Resolved-Model": resolved_model,
                    "X-HCA-Routed-Tier": routed_tier,
                }
                for qk, qv in turn_state.quota_headers.items():
                    resp_headers[qk] = qv

                if is_a2a_rpc:
                    return JSONResponse(
                        status_code=200,
                        headers=resp_headers,
                        content={
                            "jsonrpc": "2.0",
                            "id": rpc_id or str(uuid.uuid4()),
                            "result": {
                                "kind": "message",
                                "messageId": str(uuid.uuid4()),
                                "role": "agent",
                                "parts": [{"kind": "text", "text": answer_text}],
                                "metadata": {
                                    "agent": APP_NAME,
                                    "client_mode": client_mode,
                                    "data_classification": classification,
                                    "llm_backend": routed_backend,
                                    "model": resolved_model,
                                    "model_alias": requested_model,
                                    "routed_tier": routed_tier,
                                    "tools_invoked": turn_state.tools_invoked,
                                    "trace_id": trace_id_hex,
                                },
                            },
                        },
                    )
                body_out: dict[str, object] = {
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
                    "response": answer_text,
                }
                if enable_cloud_mcp:
                    body_out["cloud_mcp_tools_visible"] = 0
                    body_out["cloud_mcp_bigquery_gateway_status"] = (
                        cloud_mcp_probe_status
                    )
                return JSONResponse(
                    status_code=200,
                    headers=resp_headers,
                    content=body_out,
                )
            except Exception as exc:  # pylint: disable=broad-exception-caught
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
                        "model": SOVEREIGN_MODEL_NAME,
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


def _parse_common_request(
    request: Request, payload: dict
) -> tuple[str, str, str, str, str]:
    header_cls = request.headers.get("x-data-classification", "").strip().lower()
    body_cls = str(payload.get("data_classification", "")).strip().lower()
    classification = header_cls or body_cls or "sovereign"
    if classification not in (
        "sovereign",
        "confidential",
        "restricted",
        "public",
        "cloud-eligible",
    ):
        classification = "sovereign"

    prompt_text = payload.get("prompt")
    if not prompt_text and isinstance(payload.get("params"), dict):
        parts = payload["params"].get("message", {}).get("parts", [])
        prompt_text = " ".join(
            p.get("text", "") for p in parts if isinstance(p, dict)
        ).strip()
    if not prompt_text:
        prompt_text = "Summarize synthetic sovereign residency policy requirements."

    user_id = str(payload.get("user_id", "apigee-mediated-caller"))
    requested_model = str(
        payload.get("model_alias") or payload.get("model") or MODEL_ALIAS
    ).strip()
    client_mode = str(payload.get("client_mode") or ADK_CLIENT_MODE).strip().lower()
    if client_mode not in ("apigee_openai", "google_genai"):
        client_mode = "apigee_openai"
    return prompt_text, classification, user_id, requested_model, client_mode


@app.post("/invoke")
@app.post("/")
async def invoke(request: Request) -> JSONResponse:
    carrier = {k.lower(): v for k, v in request.headers.items()}
    parent_ctx = PROPAGATOR.extract(carrier=carrier)
    payload = await request.json()
    prompt_text, classification, user_id, requested_model, client_mode = (
        _parse_common_request(request, payload)
    )
    is_a2a_rpc = payload.get("jsonrpc") == "2.0" and str(payload.get("method", "")) in (
        "message/send",
        "tasks/send",
    )
    rpc_id = payload.get("id")
    enable_apigee_mcp = bool(payload.get("enable_apigee_mcp", False))
    enable_cloud_mcp = bool(payload.get("enable_cloud_mcp", False))

    return await _execute_adk_turn(
        prompt_text=prompt_text,
        classification=classification,
        user_id=user_id,
        parent_ctx=parent_ctx,
        is_a2a_rpc=is_a2a_rpc,
        rpc_id=rpc_id,
        requested_model=requested_model,
        client_mode=client_mode,
        enable_apigee_mcp=enable_apigee_mcp,
        enable_cloud_mcp=enable_cloud_mcp,
    )


@app.post("/invoke-stream")
@app.post("/invoke/stream")
async def invoke_stream(request: Request) -> StreamingResponse:
    carrier = {k.lower(): v for k, v in request.headers.items()}
    parent_ctx = PROPAGATOR.extract(carrier=carrier)
    payload = await request.json()
    prompt_text, classification, user_id, requested_model, client_mode = (
        _parse_common_request(request, payload)
    )
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
                agent, mcp_toolsets = _build_hardened_agent(
                    classification,
                    traceparent,
                    requested_model,
                    client_mode,
                    httpx_client,
                    enable_apigee_mcp=False,
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
                    else "local-vllm"
                )
                resolved_model = turn_state.resolved_model or SOVEREIGN_MODEL_NAME
                routed_tier = turn_state.routed_tier or "local-vllm"
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
