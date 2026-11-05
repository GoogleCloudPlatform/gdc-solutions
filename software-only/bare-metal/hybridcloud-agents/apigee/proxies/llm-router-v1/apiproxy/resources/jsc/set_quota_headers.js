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

var limit = context.getVariable("ratelimit.LLMTokenQuota-Enforce.allowed.count");
if (limit === null || limit === undefined || String(limit) === "" || Number(limit) > 1000000000000) {
  limit = context.getVariable("verifyapikey.VerifyAPIKey-1.apiproduct.llm_token_quota") || "500000";
}

var used = context.getVariable("ratelimit.LLMTokenQuota-Count.used.count");
if (used === null || used === undefined || String(used) === "") {
  used = context.getVariable("ratelimit.LLMTokenQuota-Enforce.used.count") || "0";
}

var limNum = parseInt(String(limit), 10);
var usedNum = parseInt(String(used), 10);
var avail = (!isNaN(limNum) && !isNaN(usedNum)) ? String(Math.max(0, limNum - usedNum)) : "0";

var expRaw = context.getVariable("ratelimit.LLMTokenQuota-Count.expiry.time") || context.getVariable("ratelimit.LLMTokenQuota-Enforce.expiry.time") || "0";
var expMs = parseInt(String(expRaw), 10);
var nowMs = Date.now();
var retryAfterSec = 60;
var resetIso = "";
if (!isNaN(expMs) && expMs > nowMs) {
  retryAfterSec = Math.max(1, Math.ceil((expMs - nowMs) / 1000));
  resetIso = new Date(expMs).toISOString();
} else {
  retryAfterSec = 3600;
  resetIso = new Date(nowMs + 3600000).toISOString();
}

var resolvedModel = String(context.getVariable("resolved_llm_model") || "google/gemma-4-31B-it");
var backendHeader = String(context.getVariable("response.header.X-LLM-Backend") || context.getVariable("routed_tier_label") || "local-vllm");
var routedTierHeader = String(context.getVariable("response.header.X-HCA-Routed-Tier") || backendHeader);
var promptTokens = String(context.getVariable("ratelimit.PromptTokenLimit-Burst.userPromptTokenCount") || context.getVariable("ratelimit.PromptTokenLimit-Burst.used.count") || "0");

var totalTokens = 0;
var respRaw = context.getVariable("response.content");
if (respRaw) {
  try {
    var respObj = JSON.parse(respRaw);
    if (respObj && respObj.usage && typeof respObj.usage.total_tokens === "number") {
      totalTokens = respObj.usage.total_tokens;
    }
  } catch (e) {
    totalTokens = 0;
  }
}

context.setVariable("quota_hdr_limit", String(limit));
context.setVariable("quota_hdr_used", String(used));
context.setVariable("quota_hdr_remaining", String(avail));
context.setVariable("quota_hdr_reset", resetIso);
context.setVariable("quota_hdr_retry_after", String(retryAfterSec));

context.setVariable("finops_business_unit", String(context.getVariable("verifyapikey.VerifyAPIKey-1.business_unit") || context.getVariable("app.business_unit") || context.getVariable("finops_business_unit") || "unassigned"));
context.setVariable("finops_cost_center", String(context.getVariable("verifyapikey.VerifyAPIKey-1.cost_center") || context.getVariable("app.cost_center") || context.getVariable("finops_cost_center") || "unassigned"));
context.setVariable("finops_resolved_model", resolvedModel);
context.setVariable("finops_routed_tier", routedTierHeader);
context.setVariable("finops_total_tokens", totalTokens);

context.setVariable("response.header.X-TokenQuota-Limit", String(limit));
context.setVariable("response.header.X-TokenQuota-Used", String(used));
context.setVariable("response.header.X-TokenQuota-Remaining", String(avail));
context.setVariable("response.header.X-TokenQuota-Reset", resetIso);
context.setVariable("response.header.X-HCA-Resolved-Model", resolvedModel);
context.setVariable("response.header.X-HCA-Routed-Tier", routedTierHeader);
context.setVariable("response.header.X-Prompt-Tokens", promptTokens);

context.setVariable("error.header.X-TokenQuota-Limit", String(limit));
context.setVariable("error.header.X-TokenQuota-Used", String(used));
context.setVariable("error.header.X-TokenQuota-Remaining", String(avail));
context.setVariable("error.header.X-TokenQuota-Reset", resetIso);
context.setVariable("error.header.Retry-After", String(retryAfterSec));
context.setVariable("error.header.X-HCA-Resolved-Model", resolvedModel);
context.setVariable("quota_already_counted", "true");
