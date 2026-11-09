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

cspell:words creds dbname hostnossl hostssl initdb pgdata pgpassword pgvector scram snated sslmode sslrootcert statefulset
-->

# Sample PostgreSQL + `pgvector` Data-Tier Test Cluster Manifests

Optional, self-contained Kubernetes manifests for deploying a sample PostgreSQL
16 + `pgvector` database on a Kubernetes test cluster when evaluating the MCP
Toolbox integration without an existing external PostgreSQL instance.

These manifests are applied directly with `kubectl` and are **not** managed by
Google Cloud Config Delivery (`FleetPackage`).

## Contents

- `00-namespace-and-pki.yaml` — **Apply on the Gateway and Tools cluster**
  (`namespace: cert-manager`): creates `Certificate/pgvector-server-tls` (ECDSA
  P-256 server certificate issued by `ClusterIssuer/hybrid-agents-ca` with IP
  SANs `YOUR_PGVECTOR_HOST` and `YOUR_DATA_INGRESS_VIP`), mirroring how the
  model-tier ingress TLS certificate is issued. You then copy the resulting
  `kubernetes.io/tls` `Secret/pgvector-server-tls` into
  `namespace: data-systems` on the data-tier test cluster.
- `01-postgres-pgvector.yaml` — **Apply on the data-tier test cluster**
  (`namespace: data-systems`): creates `Namespace/data-systems` (with Pod
  Security Standards `restricted`), `ConfigMap/pgvector-synthetic-seed` (seeds 5
  synthetic compliance policy rows `SYN-POL-001`..`SYN-POL-005`, creates the
  least-privilege `SELECT`-only `mcp_reader` role with
  `statement_timeout = '10s'`, and enforces `hostssl all all 0.0.0.0/0`
  `scram-sha-256` and `hostnossl all all 0.0.0.0/0 reject` in `pg_hba.conf`),
  `PersistentVolumeClaim/pgvector-data-pvc`, `StatefulSet/pgvector-db` (TLS 1.3
  enforced), and `Service/pgvector-db-external` (`type: LoadBalancer` with
  `externalTrafficPolicy: Local` at `YOUR_PGVECTOR_HOST`).
- `02-network-policies.yaml` — **Apply on the data-tier test cluster**
  (`namespace: data-systems`): enforces default-deny ingress/egress in
  `data-systems` and allows TCP `:5432` ingress to `pgvector-db` only from the
  Gateway and Tools cluster node IP CIDR (`YOUR_GATEWAY_NODE_CIDR`), blocking
  direct `:5432` connections from the Agents cluster. Because cross-cluster pod
  egress from MCP Toolbox on the Gateway and Tools cluster is SNATed to the
  Gateway and Tools node IPs and `Service/pgvector-db-external` sets
  `externalTrafficPolicy: Local`, `pgvector-db` sees the Gateway and Tools node
  IP as `client_addr`, making `YOUR_GATEWAY_NODE_CIDR` the required allow-list
  entry.

## Placeholders

Replace the following placeholders before applying the manifests:

<!-- mdformat off -->

| Placeholder              | Description                                                                                 |
| :----------------------- | :------------------------------------------------------------------------------------------ |
| `YOUR_PGVECTOR_HOST`     | MetalLB `LoadBalancer` IP exposed by `Service/pgvector-db-external` on port `5432`          |
| `YOUR_DATA_INGRESS_VIP`  | Ingress VIP of the sample data-tier test cluster (included as an IP SAN on the certificate) |
| `YOUR_GATEWAY_NODE_CIDR` | Node IP CIDR (for example `<GATEWAY_NODE_IP>/32`) of the Gateway and Tools cluster          |

<!-- mdformat on -->

## Deployment steps

1. Copy `tests/data-tier/` to a scratch working directory and substitute the
   placeholders:

   ```bash
   cp -r tests/data-tier /tmp/data-tier-work
   sed -i \
     -e "s|YOUR_PGVECTOR_HOST|${PGVECTOR_HOST}|g" \
     -e "s|YOUR_DATA_INGRESS_VIP|${DATA_INGRESS_VIP}|g" \
     -e "s|YOUR_GATEWAY_NODE_CIDR|${GATEWAY_NODE_CIDR}|g" \
     /tmp/data-tier-work/*.yaml
   ```

2. Issue `Certificate/pgvector-server-tls` in `namespace: cert-manager` on the
   **Gateway and Tools cluster**, then create `namespace: data-systems` on the
   **data-tier test cluster** and copy the resulting `kubernetes.io/tls`
   `Secret/pgvector-server-tls` into `namespace: data-systems`:

   ```bash
   kubectl --context="${GATEWAY_CTX}" apply \
     -f /tmp/data-tier-work/00-namespace-and-pki.yaml
   kubectl --context="${GATEWAY_CTX}" -n cert-manager wait \
     --for=condition=Ready certificate/pgvector-server-tls --timeout=60s

   kubectl --context="${DATA_CTX}" create namespace data-systems \
     --dry-run=client -o yaml | kubectl --context="${DATA_CTX}" apply -f -

   kubectl --context="${GATEWAY_CTX}" -n cert-manager get secret pgvector-server-tls -o json \
     | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.annotations)' \
     | kubectl --context="${DATA_CTX}" -n data-systems apply -f -
   ```

3. Create the local 4-key database owner secret `Secret/pgvector-db-creds` in
   `namespace: data-systems` on the **data-tier test cluster**. `PG_DATABASE`,
   `PG_USER`, and `PG_PASSWORD` must match the 3-key Secret Manager secret
   `hybrid-agents-pgvector-creds` that MCP Toolbox reads, whereas
   `POSTGRES_SUPER_PASSWORD` is used only by the local PostgreSQL container
   initialization and never goes to Secret Manager:

   ```bash
   kubectl --context="${DATA_CTX}" -n data-systems create secret generic pgvector-db-creds \
     --from-literal=PG_DATABASE="sovereign_kb" \
     --from-literal=PG_USER="mcp_reader" \
     --from-literal=PG_PASSWORD="${PG_READER_PASSWORD}" \
     --from-literal=POSTGRES_SUPER_PASSWORD="${POSTGRES_SUPER_PASSWORD}" \
     --dry-run=client -o yaml | kubectl --context="${DATA_CTX}" -n data-systems apply -f -
   ```

4. Deploy PostgreSQL 16 + `pgvector` and the `data-systems` `NetworkPolicies` on
   the **data-tier test cluster**:

   ```bash
   kubectl --context="${DATA_CTX}" apply -f /tmp/data-tier-work/01-postgres-pgvector.yaml
   kubectl --context="${DATA_CTX}" apply -f /tmp/data-tier-work/02-network-policies.yaml
   kubectl --context="${DATA_CTX}" -n data-systems rollout status statefulset/pgvector-db --timeout=180s
   ```

## Verification

1. Verify `pgvector-db-0` is `Ready` and contains 5 seeded policy rows:

   ```bash
   kubectl --context="${DATA_CTX}" -n data-systems exec pgvector-db-0 -- \
     psql -U postgres -d sovereign_kb -tAc "SELECT COUNT(*) FROM sovereign_compliance_policies;"
   ```

2. From a pod on the **Gateway and Tools cluster**, verify that TLS 1.3
   `sslmode=verify-full` succeeds against `${PGVECTOR_HOST}:5432` and returns
   `5`, while plaintext `sslmode=disable` is rejected by `pg_hba.conf`:

   ```bash
   CA_CRT_B64=$(kubectl --context="${GATEWAY_CTX}" -n cert-manager get secret hybrid-agents-root-ca-secret -o jsonpath='{.data.tls\.crt}')
   kubectl --context="${GATEWAY_CTX}" -n default run pgvector-verify-probe \
     --rm -i --restart=Never \
     --image="pgvector/pgvector:pg16@sha256:0dd3149a06e4579a0d70d8fef9945636cd514005e7237deb27f9b67886f8dc4f" \
     --env="CA_CRT_B64=${CA_CRT_B64}" \
     --env="PGPASSWORD=${PG_READER_PASSWORD}" \
     --command -- /bin/sh -ec "
       echo \"\$CA_CRT_B64\" | base64 -d > /tmp/ca.crt
       psql \"host=${PGVECTOR_HOST} port=5432 dbname=sovereign_kb user=mcp_reader sslmode=verify-full sslrootcert=/tmp/ca.crt\" \
         -tAc 'SELECT COUNT(*) FROM sovereign_compliance_policies;'
       ! psql \"host=${PGVECTOR_HOST} port=5432 dbname=sovereign_kb user=mcp_reader sslmode=disable\" -c 'SELECT 1;' 2>/dev/null
     "
   ```

## Cleanup

To remove the sample data-tier deployment and the certificate on the Gateway and
Tools cluster:

```bash
kubectl --context="${DATA_CTX}" delete namespace data-systems --ignore-not-found
kubectl --context="${GATEWAY_CTX}" -n cert-manager delete certificate pgvector-server-tls --ignore-not-found
kubectl --context="${GATEWAY_CTX}" -n cert-manager delete secret pgvector-server-tls --ignore-not-found
rm -rf /tmp/data-tier-work
```
