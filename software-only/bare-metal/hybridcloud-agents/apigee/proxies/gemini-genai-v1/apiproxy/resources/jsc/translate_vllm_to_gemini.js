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

var rawResp = context.getVariable("response.content");
var resolvedModel = String(context.getVariable("resolved_llm_model") || "google/gemma-4-31B-it");
var parts = [];
var promptTokens = 0;
var completionTokens = 0;
var totalTokens = 0;

if (rawResp) {
  try {
    var obj = JSON.parse(rawResp);
    var choice = (obj.choices && obj.choices.length > 0) ? obj.choices[0] : null;
    var msg = choice ? choice.message : null;
    if (msg) {
      if (Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0) {
        for (var i = 0; i < msg.tool_calls.length; i++) {
          var tc = msg.tool_calls[i];
          var parsedArgs = {};
          try {
            parsedArgs = tc.function && tc.function.arguments ? JSON.parse(tc.function.arguments) : {};
          } catch (e2) {
            parsedArgs = {};
          }
          parts.push({
            functionCall: {
              name: (tc.function && tc.function.name) ? tc.function.name : "tool",
              args: parsedArgs
            }
          });
        }
      }
      if (typeof msg.content === "string" && msg.content.length > 0) {
        parts.push({text: msg.content});
      }
    }
    if (obj.usage) {
      promptTokens = obj.usage.prompt_tokens || 0;
      completionTokens = obj.usage.completion_tokens || 0;
      totalTokens = obj.usage.total_tokens || (promptTokens + completionTokens);
    }
  } catch (e) {
    parts.push({text: String(rawResp)});
  }
}
if (parts.length === 0) {
  parts.push({text: ""});
}

var geminiResp = {
  candidates: [
    {
      content: {
        role: "model",
        parts: parts
      },
      finishReason: "STOP",
      index: 0
    }
  ],
  usageMetadata: {
    promptTokenCount: promptTokens,
    candidatesTokenCount: completionTokens,
    totalTokenCount: totalTokens
  },
  modelVersion: resolvedModel
};

context.setVariable("response.content", JSON.stringify(geminiResp));
context.setVariable("response.header.Content-Type", "application/json");
context.setVariable("response.header.X-LLM-Backend", "local-vllm-genai-facade");
context.setVariable("response.header.X-HCA-Resolved-Model", resolvedModel);
context.setVariable("response.header.X-HCA-Routed-Tier", "local-vllm");
