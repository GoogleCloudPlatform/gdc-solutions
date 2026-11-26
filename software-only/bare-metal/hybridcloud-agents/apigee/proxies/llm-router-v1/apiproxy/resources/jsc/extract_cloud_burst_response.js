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
var extractedResp = "";
if (rawResp) {
  try {
    var respObj = JSON.parse(rawResp);
    var segments = [];
    var choices = Array.isArray(respObj.choices) ? respObj.choices : [];
    for (var c = 0; c < choices.length; c++) {
      var msg = (choices[c] && choices[c].message) ? choices[c].message : null;
      if (!msg) {
        continue;
      }
      if (typeof msg.content === "string" && msg.content.trim().length > 0) {
        segments.push(msg.content);
      } else if (Array.isArray(msg.content) && msg.content.length > 0) {
        for (var i = 0; i < msg.content.length; i++) {
          if (msg.content[i] && msg.content[i].text) {
            segments.push(String(msg.content[i].text));
          }
        }
      }
      if (Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0) {
        segments.push(JSON.stringify(msg.tool_calls));
      }
      if (msg.function_call) {
        segments.push(JSON.stringify(msg.function_call));
      }
    }
    extractedResp = segments.join("\n").trim();
  } catch (e) {
    extractedResp = String(rawResp).substring(0, 65536);
  }
}
if (!extractedResp) {
  extractedResp = "[no-textual-content]";
}
context.setVariable("model_armor_llm_response", extractedResp);
if (!context.getVariable("model_armor_user_prompt")) {
  context.setVariable("model_armor_user_prompt", "[prompt]");
}
