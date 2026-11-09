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
# cspell:words adkagent importlib isvertexai nologin pythondontwritebytecode pythonunbuffered uvicorn

# Hardened Google ADK Operations Orchestrator Agent Container (v0.3.0)
# Security & runtime invariants:
#   - Non-root uid/gid 10001 compatible with Pod Security Standards `restricted` and `readOnlyRootFilesystem: true`
#   - Zero shell, interpreter, or code-execution tools enabled (`code_executor=None`)
#   - First-party `google.adk.models.apigee_llm.ApigeeLlm` (`apigee/openai/<alias>`) with zero `litellm` dependency
#   - GenAI and ADK message/tool content capture disabled at source (`OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false`
#     and `ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=false`)
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    ADK_CLIENT_MODE=apigee_openai \
    ADK_CAPTURE_MESSAGE_CONTENT_IN_SPANS=false \
    OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT=false

RUN groupadd --gid 10001 adkagent && \
    useradd --uid 10001 --gid 10001 --home-dir /tmp --no-create-home --shell /usr/sbin/nologin adkagent

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r /app/requirements.txt && \
    pip freeze > /app/pip-freeze.lock

COPY agent-card.json /app/agent-card.json
COPY app.py /app/app.py

RUN chown -R 10001:10001 /app && \
    python -c "import importlib.util, app; from google.adk.models.apigee_llm import ApigeeLlm; assert importlib.util.find_spec('litellm') is None; ag, _ = app._build_orchestrator_agent('cloud-eligible', '00-00', 'enterprise-flash', 'apigee_openai', None, enforce_a2a=False, streaming=True); assert isinstance(ag.model, ApigeeLlm) and ag.model.model == 'apigee/openai/enterprise-flash' and ag.model._api_type == ApigeeLlm.ApiType.CHAT_COMPLETIONS and ag.model._isvertexai is False and ag.model._custom_headers['Authorization'].startswith('Bearer '); ag_g, _ = app._build_orchestrator_agent('sovereign', '00-00', 'enterprise-sovereign', 'google_genai', None, enforce_a2a=False, streaming=False); assert isinstance(ag_g.model, app.GatewayGemini) and app.AGENT_CARD['name'] == 'adk-ops-orchestrator' and app.AGENT_CARD['version'] == '0.3.0' and app.AGENT_CARD['capabilities']['streaming'] is True"

USER 10001:10001
EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
