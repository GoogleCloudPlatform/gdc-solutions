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
var extracted = "";
if (rawResp) {
  try {
    var obj = JSON.parse(rawResp);
    if (Array.isArray(obj.candidates) && obj.candidates.length > 0) {
      var content = obj.candidates[0].content || {};
      var parts = content.parts || [];
      var texts = [];
      for (var i = 0; i < parts.length; i++) {
        if (parts[i] && parts[i].text) {
          texts.push(String(parts[i].text));
        } else if (parts[i] && parts[i].functionCall) {
          texts.push(JSON.stringify(parts[i].functionCall));
        }
      }
      extracted = texts.join("\n").trim();
    }
  } catch (e) {
    extracted = String(rawResp).substring(0, 4096);
  }
}
if (!extracted) {
  extracted = "[no-textual-content]";
}
context.setVariable("model_armor_llm_response", extracted);
context.setVariable("response.header.X-LLM-Backend", "vertex-gemini-3.5-flash-genai-facade");
context.setVariable("response.header.X-HCA-Resolved-Model", String(context.getVariable("resolved_llm_model") || "google/gemini-3.5-flash"));
context.setVariable("response.header.X-HCA-Routed-Tier", "cloud-burst-gemini");
