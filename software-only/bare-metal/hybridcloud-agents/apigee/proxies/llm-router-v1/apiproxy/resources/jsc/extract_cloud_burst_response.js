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
    var choice = (respObj.choices && respObj.choices.length > 0) ? respObj.choices[0] : null;
    var msg = (choice && choice.message) ? choice.message : null;
    if (msg) {
      if (typeof msg.content === "string" && msg.content.trim().length > 0) {
        extractedResp = msg.content;
      } else if (Array.isArray(msg.content) && msg.content.length > 0) {
        var parts = [];
        for (var i = 0; i < msg.content.length; i++) {
          if (msg.content[i] && msg.content[i].text) {
            parts.push(String(msg.content[i].text));
          }
        }
        extractedResp = parts.join("\n").trim();
      }
      if (!extractedResp && Array.isArray(msg.tool_calls) && msg.tool_calls.length > 0) {
        extractedResp = JSON.stringify(msg.tool_calls);
      }
    }
  } catch (e) {
    extractedResp = String(rawResp).substring(0, 4096);
  }
}
if (!extractedResp) {
  extractedResp = "[no-textual-content]";
}
context.setVariable("model_armor_llm_response", extractedResp);
if (!context.getVariable("model_armor_user_prompt")) {
  context.setVariable("model_armor_user_prompt", "[prompt]");
}
