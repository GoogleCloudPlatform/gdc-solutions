// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Prepare local-vLLM failover variables for TargetEndpoint FaultRules so token
// counting, quota headers, FinOps attribution, and SSE clients receive accurate
// local-vllm-failover metadata rather than upstream Vertex error payloads.
var failoverRaw = context.getVariable("failoverVllmResp.content");
var isSse = String(context.getVariable("is_sse_stream") || "false") === "true";
var failoverTokens = 0;
var ssePayload = "";

context.setVariable("is_local_vllm_failover", "true");
context.setVariable("resolved_llm_model", "google/gemma-4-31B-it");
context.setVariable("routed_tier_label", "local-vllm-failover");

if (failoverRaw) {
  try {
    var obj = JSON.parse(failoverRaw);
    if (obj && obj.usage && typeof obj.usage.total_tokens === "number") {
      failoverTokens = obj.usage.total_tokens;
    }
    if (isSse) {
      var choices = [];
      if (Array.isArray(obj.choices)) {
        for (var i = 0; i < obj.choices.length; i++) {
          var ch = obj.choices[i] || {};
          var msg = ch.message || {};
          var delta = {};
          if (msg.role) {
            delta.role = msg.role;
          }
          if (typeof msg.content === "string") {
            delta.content = msg.content;
          }
          if (Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0) {
            delta.tool_calls = msg.tool_calls;
          }
          choices.push({
            index: typeof ch.index === "number" ? ch.index : i,
            delta: delta,
            finish_reason: ch.finish_reason || "stop"
          });
        }
      }
      var chunk = {
        id: obj.id || "local-vllm-failover",
        object: "chat.completion.chunk",
        created: obj.created || Math.floor(Date.now() / 1000),
        model: obj.model || "google/gemma-4-31B-it",
        choices: choices
      };
      if (obj.usage) {
        chunk.usage = obj.usage;
      }
      ssePayload = "data: " + JSON.stringify(chunk) + "\n\ndata: [DONE]\n\n";
    }
  } catch (e) {
    failoverTokens = 0;
    if (isSse) {
      ssePayload = "data: " + String(failoverRaw) + "\n\ndata: [DONE]\n\n";
    }
  }
} else if (isSse) {
  ssePayload = "data: [DONE]\n\n";
}

context.setVariable("failover_total_tokens", String(failoverTokens));
if (isSse) {
  context.setVariable("failover_sse_payload", ssePayload);
}
