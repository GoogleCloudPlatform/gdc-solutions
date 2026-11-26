<!--
Copyright 2026 Google LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Optional Test Fixtures

Test-only helpers kept outside the deployable Apigee and Config Delivery
packages.

## Contents

- `toggle-failover-simulation.sh`: Temporarily flips `allow_failover_simulation`
  (`true` or `false`) in the Apigee `hybrid_agents_env` environment PropertySet.
  By default, `apigee/environments/env-config.json` sets
  `allow_failover_simulation=false`, so `llm-router-v1` ignores caller-supplied
  `x-simulate-cloud-burst-status: 503` headers. Enable it only during a
  controlled `tests/verify/verify.sh --allow-failover-sim` test window and reset
  it to `false` afterward (the next release tag also resets it to `false`).

## Usage

```bash
chmod +x tests/fixtures/toggle-failover-simulation.sh
PROJECT_ID="${PROJECT_ID}" ./tests/fixtures/toggle-failover-simulation.sh true
./tests/verify/verify.sh step3 --allow-failover-sim
PROJECT_ID="${PROJECT_ID}" ./tests/fixtures/toggle-failover-simulation.sh false
```
