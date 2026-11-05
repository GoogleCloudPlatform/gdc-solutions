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
var dataClass = String(context.getVariable("request.header.x-data-classification") || "sovereign").toLowerCase();
var isCloudClass = (dataClass === "cloud-eligible" || dataClass === "public");
var allowedCsv = String(context.getVariable("verifyapikey.VerifyAPIKey-1.apiproduct.allowed_models") || "");

var aliasSovereign = String(context.getVariable("private.kvm_alias_sovereign") || "google/gemma-4-31B-it");
var aliasFlash = String(context.getVariable("private.kvm_alias_flash") || "google/gemini-3.5-flash");
var canaryWeight = parseInt(String(context.getVariable("private.kvm_canary_weight") || "0"), 10);
if (isNaN(canaryWeight) || canaryWeight < 0) {
  canaryWeight = 0;
}
var canaryTarget = String(context.getVariable("private.kvm_canary_target") || "google/gemma-4-31B-it");

var reqModel = "enterprise-sovereign";
var resolvedModel = aliasSovereign;
var targetTier = "local-vllm";
var routedTierLabel = "local-vllm";
var isSse = "false";
var modelNotAuthorized = "false";

if (raw) {
  try {
    var body = JSON.parse(raw);
    reqModel = String(body.model || (isCloudClass ? "enterprise-flash" : "enterprise-sovereign"));
    context.setVariable("requested_llm_model", reqModel);

    if (allowedCsv.trim().length > 0) {
      var parts = allowedCsv.split(",");
      var permitted = false;
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].trim() === reqModel) {
          permitted = true;
          break;
        }
      }
      if (!permitted) {
        modelNotAuthorized = "true";
      }
    }

    if (reqModel === "enterprise-sovereign") {
      resolvedModel = aliasSovereign;
      targetTier = "local-vllm";
      routedTierLabel = "local-vllm";
    } else if (reqModel === "enterprise-flash" || (isCloudClass && (reqModel === "google/gemini-3.5-flash" || reqModel === "google/gemma-4-31B-it"))) {
      if (!isCloudClass) {
        modelNotAuthorized = "true";
      }
      var canarySelected = false;
      if (canaryWeight >= 100) {
        resolvedModel = canaryTarget;
        canarySelected = true;
      } else if (canaryWeight > 0 && Math.floor(Math.random() * 100) < canaryWeight) {
        resolvedModel = canaryTarget;
        canarySelected = true;
      } else {
        resolvedModel = aliasFlash;
      }

      if (resolvedModel.indexOf("google/gemini-") === 0) {
        targetTier = "vertex-gemini";
        routedTierLabel = canarySelected ? "vertex-gemini-canary" : "vertex-gemini-3.5-flash";
      } else {
        targetTier = "local-vllm";
        routedTierLabel = canarySelected ? "local-vllm-canary" : "local-vllm-alias-remapped";
      }
    } else if (!isCloudClass) {
      resolvedModel = aliasSovereign;
      targetTier = "local-vllm";
      routedTierLabel = "local-vllm";
    } else {
      resolvedModel = reqModel;
      targetTier = (resolvedModel.indexOf("google/gemini-") === 0) ? "vertex-gemini" : "local-vllm";
      routedTierLabel = (targetTier === "vertex-gemini") ? "vertex-gemini-3.5-flash" : "local-vllm";
    }

    if (body.stream === true) {
      isSse = "true";
      if (!body.stream_options || typeof body.stream_options !== "object") {
        body.stream_options = {};
      }
      body.stream_options.include_usage = true;
    }

    var failoverCopy = JSON.parse(JSON.stringify(body));
    failoverCopy.model = "google/gemma-4-31B-it";
    failoverCopy.stream = false;
    delete failoverCopy.stream_options;
    context.setVariable("failover_vllm_payload", JSON.stringify(failoverCopy));

    body.model = resolvedModel;
    context.setVariable("request.content", JSON.stringify(body));
  } catch (e) {
    context.setVariable("failover_vllm_payload", raw);
  }
}

context.setVariable("model_not_authorized", modelNotAuthorized);
context.setVariable("resolved_llm_model", resolvedModel);
context.setVariable("llm_target_tier", targetTier);
context.setVariable("routed_tier_label", routedTierLabel);
context.setVariable("is_sse_stream", isSse);
context.setVariable("finops_business_unit", String(context.getVariable("verifyapikey.VerifyAPIKey-1.business_unit") || context.getVariable("app.business_unit") || "unassigned"));
context.setVariable("finops_cost_center", String(context.getVariable("verifyapikey.VerifyAPIKey-1.cost_center") || context.getVariable("app.cost_center") || "unassigned"));
