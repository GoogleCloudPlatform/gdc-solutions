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

cspell:words creds hostnossl hostssl initdb pgdata pgvector scram sslmode statefulset
-->

# Sample PostgreSQL + `pgvector` Data-Tier Test Cluster Manifests

Optional, self-contained Kubernetes manifests for deploying a sample PostgreSQL
16 + `pgvector` database on a Kubernetes test cluster when evaluating the MCP
Toolbox integration without an existing external PostgreSQL instance.

These manifests are applied directly with `kubectl` and are **not** managed by
Google Cloud Config Delivery (`FleetPackage`).

## Contents

- `00-namespace-and-pki.yaml` — Creates `Namespace/data-systems` (with Pod
  Security Standards `restricted`) and `Certificate/pgvector-server-tls` (ECDSA
  P-256 server certificate issued by `ClusterIssuer/hybrid-agents-ca` with IP
  SANs `YOUR_PGVECTOR_HOST` and `YOUR_DATA_INGRESS_VIP`).
- `01-postgres-pgvector.yaml` — Deploys `ConfigMap/pgvector-synthetic-seed`
  (seeds 5 synthetic compliance policy rows `SYN-POL-001`..`SYN-POL-005`,
  creates the least-privilege `SELECT`-only `mcp_reader` role with
  `statement_timeout = '10s'`, and enforces `hostssl` `scram-sha-256` in
  `pg_hba.conf`), `PersistentVolumeClaim/pgvector-data-pvc`,
  `StatefulSet/pgvector-db` (TLS 1.3 enforced), and
  `Service/pgvector-db-external` (`type: LoadBalancer` at `YOUR_PGVECTOR_HOST`).
- `02-network-policies.yaml` — Enforces default-deny ingress/egress in
  `data-systems` and allows `:5432` ingress to `pgvector-db` only from the
  Gateway and Tools cluster (`YOUR_GATEWAY_NODE_CIDR` and
  `YOUR_GATEWAY_POD_CIDR`), blocking direct `:5432` connections from the Agents
  cluster.

## Placeholders

Replace the following placeholders before applying the manifests:

<!-- mdformat off -->

| Placeholder              | Description                                                                                 |
| :----------------------- | :------------------------------------------------------------------------------------------ |
| `YOUR_PGVECTOR_HOST`     | MetalLB `LoadBalancer` IP exposed by `Service/pgvector-db-external` on port `5432`          |
| `YOUR_DATA_INGRESS_VIP`  | Ingress VIP of the sample data-tier test cluster (included as an IP SAN on the certificate) |
| `YOUR_GATEWAY_NODE_CIDR` | Node IP CIDR (for example `<GATEWAY_NODE_IP>/32`) of the Gateway and Tools cluster          |
| `YOUR_GATEWAY_POD_CIDR`  | Pod/alias IP CIDR (for example `<GATEWAY_ALIAS_CIDR>/28`) of the Gateway and Tools cluster  |

<!-- mdformat on -->

## Deployment steps

1. Substitute the placeholders in a working copy of these manifests:

   ```bash
   sed -i \
     -e "s|YOUR_PGVECTOR_HOST|${PGVECTOR_HOST}|g" \
     -e "s|YOUR_DATA_INGRESS_VIP|${DATA_INGRESS_VIP}|g" \
     -e "s|YOUR_GATEWAY_NODE_CIDR|${GATEWAY_NODE_CIDR}|g" \
     -e "s|YOUR_GATEWAY_POD_CIDR|${GATEWAY_POD_CIDR}|g" \
     tests/data-tier/*.yaml
   ```

2. Apply the namespace and TLS certificate (or copy `Secret/pgvector-server-tls`
   signed by `hybrid-agents-root-ca`), then create `Secret/pgvector-db-creds` in
   `namespace: data-systems` from Secret Manager (`hybrid-agents-pgvector-creds`
   containing `PG_DATABASE`, `PG_USER`, `PG_PASSWORD`, and
   `POSTGRES_SUPER_PASSWORD`):

   ```bash
   kubectl apply -f tests/data-tier/00-namespace-and-pki.yaml
   ```

3. Deploy PostgreSQL 16 + `pgvector` and the `data-systems` `NetworkPolicies`:

   ```bash
   kubectl apply -f tests/data-tier/01-postgres-pgvector.yaml
   kubectl apply -f tests/data-tier/02-network-policies.yaml
   kubectl -n data-systems rollout status statefulset/pgvector-db --timeout=180s
   ```
