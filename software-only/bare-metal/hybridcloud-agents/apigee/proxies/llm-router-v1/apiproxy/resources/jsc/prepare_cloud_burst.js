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

var raw = context.getVariable("request.content");
var extractedPrompt = "";
var resolvedModel = String(context.getVariable("resolved_llm_model") || "google/gemini-3.5-flash");

function extractMsgText(msg) {
  if (!msg) {
    return "";
  }
  if (typeof msg.content === "string" && msg.content.trim().length > 0) {
    return msg.content;
  }
  if (Array.isArray(msg.content)) {
    var parts = [];
    for (var i = 0; i < msg.content.length; i++) {
      if (msg.content[i] && msg.content[i].text) {
        parts.push(String(msg.content[i].text));
      }
    }
    if (parts.length > 0) {
      return parts.join("\n");
    }
  }
  if (Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0) {
    return JSON.stringify(msg.tool_calls);
  }
  return "";
}

if (raw) {
  try {
    if (!context.getVariable("failover_vllm_payload")) {
      var fallbackObj = JSON.parse(raw);
      fallbackObj.model = "google/gemma-4-31B-it";
      fallbackObj.stream = false;
      delete fallbackObj.stream_options;
      context.setVariable("failover_vllm_payload", JSON.stringify(fallbackObj));
    }

    var burstObj = JSON.parse(raw);
    if (Array.isArray(burstObj.messages) && burstObj.messages.length > 0) {
      var lastMsg = burstObj.messages[burstObj.messages.length - 1];
      var lastText = extractMsgText(lastMsg);
      var latestUserText = "";
      for (var j = burstObj.messages.length - 1; j >= 0; j--) {
        if (burstObj.messages[j] && burstObj.messages[j].role === "user") {
          latestUserText = extractMsgText(burstObj.messages[j]);
          if (latestUserText) {
            break;
          }
        }
      }
      if (lastMsg && lastMsg.role !== "user" && latestUserText && lastText) {
        extractedPrompt = latestUserText + "\n" + lastText;
      } else {
        extractedPrompt = lastText || latestUserText;
      }
    }
    if (resolvedModel.indexOf("google/gemini-") === 0) {
      burstObj.model = resolvedModel;
    } else if (!burstObj.model || burstObj.model.indexOf("google/gemini-") !== 0) {
      burstObj.model = "google/gemini-3.5-flash";
    }
    context.setVariable("request.content", JSON.stringify(burstObj));
  } catch (e) {
    if (!context.getVariable("failover_vllm_payload")) {
      context.setVariable("failover_vllm_payload", raw);
    }
    extractedPrompt = String(raw).substring(0, 4096);
  }
}
if (!extractedPrompt) {
  extractedPrompt = "[prompt]";
}
context.setVariable("model_armor_user_prompt", extractedPrompt);
context.removeVariable("request.header.Authorization");
context.removeVariable("request.header.authorization");
context.removeVariable("request.header.x-api-key");
context.removeVariable("request.header.x-agent-ksa-token");
