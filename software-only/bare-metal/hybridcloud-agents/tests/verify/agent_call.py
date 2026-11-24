# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# cspell:words urllib urlopen

"""In-pod HTTP helper matching the Solution User Guide `agent_call` semantics.

Executed inside an agent container via `kubectl exec -i deploy/<agent> -- python3 -`
so that no API key or projected Kubernetes ServiceAccount token leaves the pod.
"""

import json
import os
import sys
import urllib.error
import urllib.request


def main() -> int:
    args = list(sys.argv[1:])
    method = "POST"
    if args and args[0].startswith("--method="):
        method = args.pop(0).split("=", 1)[1].upper()
    if len(args) < 3:
        sys.stderr.write(
            "Usage: agent_call.py [--method=POST|GET] <agent|gateway> <path> <body|-> [HEADER=VALUE ...]\n"
        )
        return 2

    target, path, body, *extra = args
    base = (
        os.environ["EGRESS_PROXY_BASE"]
        if target == "gateway"
        else "http://127.0.0.1:8080"
    )
    headers = {
        "Accept": "application/json, text/event-stream",
    }
    if method != "GET" and body not in ("", "-"):
        headers["Content-Type"] = "application/json"
    if target == "gateway":
        token_path = os.environ.get(
            "KSA_TOKEN_PATH", "/var/run/secrets/tokens/apigee-ksa/token"
        )
        with open(token_path, encoding="utf-8") as token_file:
            headers["X-Agent-KSA-Token"] = token_file.read().strip()

    for item in extra:
        name, value = item.split("=", 1)
        headers[name] = value

    payload = None if (method == "GET" or body in ("", "-")) else body.encode("utf-8")
    req = urllib.request.Request(
        base + path, data=payload, headers=headers, method=method
    )
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            status = resp.status
            resp_headers = dict(resp.headers)
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as err:
        status = err.code
        resp_headers = dict(err.headers)
        raw = err.read().decode("utf-8", errors="replace")

    lower_headers = {k.lower(): v for k, v in resp_headers.items()}
    out = {
        "status": status,
        "headers": {k: v for k, v in lower_headers.items() if k.startswith("x-")},
    }
    if "text/event-stream" in lower_headers.get("content-type", "").lower():
        events = [
            line[6:]
            for line in raw.splitlines()
            if line.startswith("data: ") and line[6:].strip() != "[DONE]"
        ]
        out["sse_events"] = len(events)
        out["last_event"] = events[-1] if events else None
    else:
        try:
            out["body"] = json.loads(raw)
        except ValueError:
            out["body"] = raw[:800]

    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
