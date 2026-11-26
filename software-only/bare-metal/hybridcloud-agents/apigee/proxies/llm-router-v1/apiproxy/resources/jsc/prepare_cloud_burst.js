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
var promptTooLarge = "false";
var MAX_PROMPT_CHARS = 65536;
var resolvedModel = String(context.getVariable("resolved_llm_model") || "google/gemini-3.5-flash");

function extractMsgSegments(msg) {
  var segments = [];
  if (!msg) {
    return segments;
  }
  if (typeof msg.content === "string" && msg.content.trim().length > 0) {
    segments.push(msg.content);
  } else if (Array.isArray(msg.content)) {
    for (var i = 0; i < msg.content.length; i++) {
      var part = msg.content[i];
      if (!part) {
        continue;
      }
      if (typeof part === "string" && part.trim().length > 0) {
        segments.push(part);
      } else if (part.text) {
        segments.push(String(part.text));
      } else if (part.input_text) {
        segments.push(String(part.input_text));
      }
    }
  }
  if (Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0) {
    segments.push(JSON.stringify(msg.tool_calls));
  }
  if (msg.function_call) {
    segments.push(JSON.stringify(msg.function_call));
  }
  return segments;
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
    var allSegments = [];
    if (Array.isArray(burstObj.messages)) {
      for (var j = 0; j < burstObj.messages.length; j++) {
        var msgSegments = extractMsgSegments(burstObj.messages[j]);
        for (var k = 0; k < msgSegments.length; k++) {
          allSegments.push(msgSegments[k]);
        }
      }
    }
    extractedPrompt = allSegments.join("\n");
    if (extractedPrompt.length > MAX_PROMPT_CHARS) {
      promptTooLarge = "true";
      extractedPrompt = extractedPrompt.substring(0, MAX_PROMPT_CHARS);
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
    if (String(raw).length > MAX_PROMPT_CHARS) {
      promptTooLarge = "true";
    }
    extractedPrompt = String(raw).substring(0, MAX_PROMPT_CHARS);
  }
}
if (!extractedPrompt) {
  extractedPrompt = "[prompt]";
}
context.setVariable("model_armor_prompt_too_large", promptTooLarge);
context.setVariable("model_armor_user_prompt", extractedPrompt);
context.removeVariable("request.header.Authorization");
context.removeVariable("request.header.authorization");
context.removeVariable("request.header.x-api-key");
context.removeVariable("request.header.x-agent-ksa-token");
