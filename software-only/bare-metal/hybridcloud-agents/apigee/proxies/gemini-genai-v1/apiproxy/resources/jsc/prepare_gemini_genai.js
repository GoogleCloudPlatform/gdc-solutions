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

var suffix = String(context.getVariable("proxy.pathsuffix") || "");
var dataClass = String(context.getVariable("request.header.x-data-classification") || "sovereign").toLowerCase();
var isCloudClass = (dataClass === "cloud-eligible" || dataClass === "public");
var allowBurst = String(context.getVariable("verifyapikey.VerifyAPIKey-1.apiproduct.allow_cloud_burst") || "false") === "true";
var allowedCsv = String(context.getVariable("verifyapikey.VerifyAPIKey-1.apiproduct.allowed_models") || "");

var aliasSovereign = String(context.getVariable("private.kvm_alias_sovereign") || "google/gemma-4-31B-it");
var aliasFlash = String(context.getVariable("private.kvm_alias_flash") || "google/gemini-3.5-flash");

var m = suffix.match(/\/models\/([^\/:]+):(generateContent|streamGenerateContent)/);
var reqModel = m ? m[1] : (isCloudClass ? "enterprise-flash" : "enterprise-sovereign");
var action = m ? m[2] : "generateContent";
context.setVariable("requested_llm_model", reqModel);

var modelNotAuthorized = "false";
if (isCloudClass && !allowBurst) {
  modelNotAuthorized = "true";
}
if (allowedCsv.trim().length > 0) {
  var parts = allowedCsv.split(",");
  var ok = false;
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i].trim();
    if (p === reqModel || p === ("google/" + reqModel)) {
      ok = true;
      break;
    }
  }
  if (!ok) {
    modelNotAuthorized = "true";
  }
}

var resolvedModel = aliasSovereign;
var targetTier = "local-vllm";
if (reqModel === "enterprise-sovereign" || !isCloudClass) {
  if (!isCloudClass && (reqModel === "enterprise-flash" || reqModel.indexOf("gemini") !== -1)) {
    modelNotAuthorized = "true";
  }
  resolvedModel = aliasSovereign;
  targetTier = "local-vllm";
} else if (reqModel === "enterprise-flash" || reqModel.indexOf("gemini") !== -1) {
  resolvedModel = aliasFlash;
  targetTier = (resolvedModel.indexOf("google/gemini-") === 0) ? "vertex-gemini" : "local-vllm";
} else {
  resolvedModel = reqModel;
  targetTier = (resolvedModel.indexOf("google/gemini-") === 0) ? "vertex-gemini" : "local-vllm";
}

var vertexShortModel = resolvedModel.replace(/^google\//, "");
context.setVariable("model_not_authorized", modelNotAuthorized);
context.setVariable("resolved_llm_model", resolvedModel);
context.setVariable("genai_target_tier", targetTier);
context.setVariable("vertex_model_action", vertexShortModel + ":" + action);

var raw = context.getVariable("request.content");
var promptTexts = [];
var openaiMessages = [];
var openaiTools = [];
var maxTokens = 512;
var temperature = 0.2;

if (raw) {
  try {
    var body = JSON.parse(raw);
    var sysInst = body.systemInstruction || body.system_instruction;
    if (sysInst && Array.isArray(sysInst.parts)) {
      var sParts = [];
      for (var s = 0; s < sysInst.parts.length; s++) {
        if (sysInst.parts[s] && sysInst.parts[s].text) {
          sParts.push(String(sysInst.parts[s].text));
        }
      }
      if (sParts.length > 0) {
        openaiMessages.push({role: "system", content: sParts.join("\n")});
      }
    }
    if (Array.isArray(body.contents)) {
      for (var c = 0; c < body.contents.length; c++) {
        var item = body.contents[c] || {};
        var role = (item.role === "model") ? "assistant" : "user";
        var textAcc = [];
        if (Array.isArray(item.parts)) {
          for (var k = 0; k < item.parts.length; k++) {
            var pt = item.parts[k] || {};
            if (pt.text) {
              textAcc.push(String(pt.text));
              if (role === "user") {
                promptTexts.push(String(pt.text));
              }
            } else if (pt.functionResponse) {
              var frStr = "[Tool response " + String(pt.functionResponse.name || "tool") + "]: " + JSON.stringify(pt.functionResponse.response || {});
              textAcc.push(frStr);
              promptTexts.push(frStr);
            } else if (pt.functionCall) {
              textAcc.push("[Tool call " + String(pt.functionCall.name || "tool") + "]: " + JSON.stringify(pt.functionCall.args || {}));
            }
          }
        }
        if (textAcc.length > 0) {
          openaiMessages.push({role: role, content: textAcc.join("\n")});
        }
      }
    }
    var genCfg = body.generationConfig || body.generation_config;
    if (genCfg) {
      if (typeof genCfg.maxOutputTokens === "number") {
        maxTokens = genCfg.maxOutputTokens;
      }
      if (typeof genCfg.temperature === "number") {
        temperature = genCfg.temperature;
      }
    }
    if (Array.isArray(body.tools)) {
      for (var t = 0; t < body.tools.length; t++) {
        var decls = body.tools[t].functionDeclarations || body.tools[t].function_declarations || [];
        for (var d = 0; d < decls.length; d++) {
          var fd = decls[d];
          if (fd && fd.name) {
            openaiTools.push({
              type: "function",
              function: {
                name: fd.name,
                description: fd.description || "",
                parameters: fd.parameters || {type: "object", properties: {}}
              }
            });
          }
        }
      }
    }
  } catch (e) {
    promptTexts.push(String(raw).substring(0, 2048));
  }
}

if (openaiMessages.length === 0) {
  openaiMessages.push({role: "user", content: "Hello"});
}
var vllmPayload = {
  model: (resolvedModel.indexOf("google/gemma-") === 0) ? resolvedModel : "google/gemma-4-31B-it",
  messages: openaiMessages,
  max_tokens: maxTokens,
  temperature: temperature
};
if (openaiTools.length > 0) {
  vllmPayload.tools = openaiTools;
}
context.setVariable("translated_vllm_payload", JSON.stringify(vllmPayload));
context.setVariable("model_armor_user_prompt", promptTexts.length > 0 ? promptTexts[promptTexts.length - 1] : "[prompt]");
if (targetTier === "local-vllm") {
  context.setVariable("request.content", JSON.stringify(vllmPayload));
}
