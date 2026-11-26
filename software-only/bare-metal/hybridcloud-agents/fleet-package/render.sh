#!/usr/bin/env bash
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

# Renders the DRY Kustomize overlays (agents-platform, gateway-tools-platform,
# and agents by default) into the WET variant bundles that Config Delivery
# packages. For the agents variant, this script first regenerates
# src/overlays/agents/ from the active agent manifests in
# ../registry/agents/*/agent.yaml so only active agents (plus their Envoy
# listeners, secret mounts, routes, NetworkPolicy rules, PodMonitoring entries,
# and A2A peer ConfigMaps) are included. Run it from any directory and commit
# the results with the DRY change in the same pull request.

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2> /dev/null || (cd "${SCRIPT_DIR}/../../../.." && pwd))"
AGENTS_REGISTRY_DIR="${AGENTS_REGISTRY_DIR:-${SCRIPT_DIR}/../registry/agents}"

PYTHON_BIN="$(command -v python3 || gcloud info --format='value(basic.python_location)' 2> /dev/null || true)"
CLOUDSDK_THIRD_PARTY="$(gcloud info --format='value(installation.sdk_root)' 2> /dev/null || echo /usr/lib/google-cloud-sdk)/lib/third_party"
export CLOUDSDK_THIRD_PARTY
if [[ -z "${PYTHON_BIN}" || ! -x "${PYTHON_BIN}" ]]; then
  echo "ERROR: Python 3 runtime not found." >&2
  exit 1
fi

generate_agents_overlay() {
  "${PYTHON_BIN}" - "${SCRIPT_DIR}" "${AGENTS_REGISTRY_DIR}" << 'EOF'
import hashlib
import json
import os
from pathlib import Path
import sys


def _load_yaml(text: str):
  try:
    import yaml as pyyaml
    return pyyaml.safe_load(text)
  except Exception:
    for p in (
        os.environ.get("CLOUDSDK_THIRD_PARTY", ""),
        "/usr/lib/google-cloud-sdk/lib/third_party",
        "/google-cloud-sdk/lib/third_party",
    ):
      if p and os.path.isdir(p) and p not in sys.path:
        sys.path.insert(0, p)
    from ruamel import yaml as ryaml
    return ryaml.YAML(typ="safe").load(text)


LICENSE_HEADER = """# Copyright 2026 Google LLC
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
"""

script_dir = Path(sys.argv[1])
registry_agents_dir = Path(sys.argv[2])
overlay_dir = script_dir / "src" / "overlays" / "agents"
components_dir = script_dir / "src" / "components" / "agents"

generated_files = (
    overlay_dir / "generated-pod-monitoring.yaml",
    overlay_dir / "generated-envoy-patches.yaml",
    overlay_dir / "generated-egress-envoy-config.yaml",
    overlay_dir / "generated-ingress-envoy-config.yaml",
    overlay_dir / "generated-peer-config.yaml",
)

agents = []
if registry_agents_dir.is_dir():
  for manifest_path in sorted(registry_agents_dir.glob("*/agent.yaml")):
    obj = _load_yaml(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(obj, dict):
      raise RuntimeError(f"{manifest_path}: expected YAML mapping")
    name = str(obj.get("name") or manifest_path.parent.name).strip()
    comp_dir = components_dir / name
    if not (comp_dir / "kustomization.yaml").is_file():
      raise RuntimeError(
          f"Active agent '{name}' is missing Kustomize component {comp_dir}/kustomization.yaml"
      )
    egress = obj.get("egressProxy") or {}
    ingress = obj.get("ingressProxy") or {}
    k8s_id = obj.get("kubernetesIdentity") or {}
    port = int(egress["port"])
    agents.append({
        "a2a_peers": obj.get("a2aPeers") or [],
        "cluster_name": str(
            ingress.get("clusterName") or f"{name.replace('-', '_')}_cluster"
        ),
        "component_label": str(k8s_id.get("componentLabel") or name),
        "endpoint": str(
            egress.get("endpoint")
            or f"http://agent-egress-envoy.agent-workloads.svc.cluster.local:{port}"
        ),
        "mount_path": str(
            egress.get("mountPath") or f"/etc/envoy/{name}-apigee-key"
        ),
        "name": name,
        "namespace": str(k8s_id.get("namespace") or "agent-workloads"),
        "path_prefix": str(ingress.get("pathPrefix") or f"/{name}"),
        "port": port,
        "port_name": str(egress.get("portName") or f"egress-{port}"),
        "sds_secret_name": str(
            egress.get("sdsSecretName")
            or f"apigee_{name.replace('-', '_')}_api_key"
        ),
        "secret_name": str(egress.get("secretName") or f"{name}-apigee-api-key"),
        "service_name": str(ingress.get("serviceName") or name),
        "service_port": int(ingress.get("servicePort") or 8080),
        "stat_prefix": str(
            egress.get("statPrefix") or f"{name.replace('-', '_')}_apigee_egress"
        ),
        "volume_name": str(egress.get("volumeName") or f"{name}-apigee-key"),
    })

# Sort deterministically by egress port ascending and fail fast on conflicts
agents.sort(key=lambda a: (a["port"], a["name"]))
seen_ports: dict[int, str] = {}
seen_prefixes: dict[str, str] = {}
for a in agents:
  if a["port"] in seen_ports:
    raise RuntimeError(
        f"Duplicate egressProxy.port {a['port']} assigned to both "
        f"'{seen_ports[a['port']]}' and '{a['name']}'"
    )
  seen_ports[a["port"]] = a["name"]
  norm_pref = "/" + a["path_prefix"].strip("/")
  if norm_pref in seen_prefixes:
    raise RuntimeError(
        f"Duplicate ingressProxy.pathPrefix '{norm_pref}' assigned to both "
        f"'{seen_prefixes[norm_pref]}' and '{a['name']}'"
    )
  seen_prefixes[norm_pref] = a["name"]
active_names = {a["name"] for a in agents}


def _indent(text: str, spaces: int) -> str:
  pad = " " * spaces
  return "\n".join((pad + line if line else "") for line in text.splitlines())


def _build_egress_envoy_yaml(active_agents: list[dict]) -> str:
  blocks = []
  for ag in active_agents:
    listener_prefix = (
        "agent_egress"
        if ag["port"] == 15001
        else ("ops_egress" if ag["port"] == 15002 else ag["name"].replace("-", "_"))
    )
    route_name = (
        "apigee_egress_routes"
        if ag["port"] == 15001
        else (
            "ops_egress_routes"
            if ag["port"] == 15002
            else f"{ag['name'].replace('-', '_')}_egress_routes"
        )
    )
    virtual_host_name = (
        "apigee_gateway"
        if ag["port"] == 15001
        else (
            "ops_apigee_gateway"
            if ag["port"] == 15002
            else f"{ag['name'].replace('-', '_')}_apigee_gateway"
        )
    )
    blocks.append(f"""    - name: {listener_prefix}_{ag['port']}
      address:
        socket_address:
          address: 0.0.0.0
          port_value: {ag['port']}
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: {ag['stat_prefix']}
                codec_type: AUTO
                generate_request_id: true
                preserve_external_request_id: true
                stream_idle_timeout: 360s
                tracing:
                  provider:
                    name: envoy.tracers.opentelemetry
                    typed_config:
                      "@type": type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig
                      grpc_service:
                        envoy_grpc:
                          cluster_name: otel_collector_grpc
                        timeout: 2s
                      service_name: agent-egress-envoy
                  spawn_upstream_span: true
                route_config:
                  name: {route_name}
                  virtual_hosts:
                    - name: {virtual_host_name}
                      domains: ["*"]
                      routes:
                        - match:
                            prefix: "/"
                          route:
                            cluster: apigee_hybrid_gateway
                            host_rewrite_literal: api.hybrid-agents.internal
                            timeout: 0s
                            idle_timeout: 360s
                            max_stream_duration:
                              max_stream_duration: 360s
                http_filters:
                  - name: envoy.filters.http.credential_injector
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.credential_injector.v3.CredentialInjector
                      overwrite: true
                      allow_request_without_credential: false
                      credential:
                        name: envoy.http.injected_credentials.generic
                        typed_config:
                          "@type": type.googleapis.com/envoy.extensions.http.injected_credentials.generic.v3.Generic
                          credential:
                            name: {ag['sds_secret_name']}
                            sds_config:
                              resource_api_version: V3
                              path_config_source:
                                path: {ag['mount_path']}/sds-apigee-key.yaml
                                watched_directory:
                                  path: {ag['mount_path']}
                          header: x-api-key
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
""")

  listeners_str = "\n".join(blocks)
  if listeners_str:
    listeners_str += "\n"
  return f"""node:
  id: agent-egress-envoy
  cluster: agent-egress-envoy

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901

static_resources:
  listeners:
{listeners_str}    - name: observability_19000
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 19000
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: envoy_observability
                route_config:
                  name: readonly_admin_routes
                  virtual_hosts:
                    - name: local_observability
                      domains: ["*"]
                      routes:
                        - match:
                            path: "/ready"
                          route:
                            cluster: envoy_admin_loopback
                        - match:
                            prefix: "/stats/prometheus"
                          route:
                            cluster: envoy_admin_loopback
                        - match:
                            prefix: "/"
                          direct_response:
                            status: 403
                            body:
                              inline_string: "forbidden\\n"
                http_filters:
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
    - name: apigee_hybrid_gateway
      type: STRICT_DNS
      dns_lookup_family: V4_ONLY
      connect_timeout: 5s
      lb_policy: ROUND_ROBIN
      load_assignment:
        cluster_name: apigee_hybrid_gateway
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: api.hybrid-agents.internal
                      port_value: 443
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
          sni: api.hybrid-agents.internal
          common_tls_context:
            tls_params:
              tls_minimum_protocol_version: TLSv1_3
              tls_maximum_protocol_version: TLSv1_3
            tls_certificates:
              - certificate_chain:
                  filename: /etc/envoy/tls/tls.crt
                private_key:
                  filename: /etc/envoy/tls/tls.key
                watched_directory:
                  path: /etc/envoy/tls
            validation_context:
              trusted_ca:
                filename: /etc/envoy/root-ca/ca.crt
              watched_directory:
                path: /etc/envoy/root-ca
              match_typed_subject_alt_names:
                - san_type: DNS
                  matcher:
                    exact: "api.hybrid-agents.internal"

    - name: otel_collector_grpc
      type: STRICT_DNS
      connect_timeout: 2s
      lb_policy: ROUND_ROBIN
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http2_protocol_options: {{}}
      load_assignment:
        cluster_name: otel_collector_grpc
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: otel-collector.otel-system.svc.cluster.local
                      port_value: 4317

    - name: envoy_admin_loopback
      type: STATIC
      connect_timeout: 1s
      load_assignment:
        cluster_name: envoy_admin_loopback
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: 127.0.0.1
                      port_value: 9901
"""


def _build_ingress_envoy_yaml(active_agents: list[dict]) -> str:
  # Require every active agent to declare a dedicated non-root pathPrefix so
  # unprefixed path suffixes can never fall through to another agent.
  root_agents = [a for a in active_agents if a["path_prefix"].strip("/") == ""]
  if root_agents:
    names = ", ".join(a["name"] for a in root_agents)
    raise RuntimeError(
        "Active agents must declare a dedicated non-root ingressProxy.pathPrefix "
        f"(cannot use '/'): {names}"
    )
  non_root = sorted(
      active_agents,
      key=lambda a: (-len(a["path_prefix"]), a["name"]),
  )
  route_blocks = []
  for ag in non_root:
    pref = "/" + ag["path_prefix"].strip("/")
    route_blocks.append(f"""                        - match:
                            prefix: "{pref}/"
                          route:
                            cluster: {ag['cluster_name']}
                            prefix_rewrite: "/"
                            timeout: 360s
                            idle_timeout: 360s
                        - match:
                            path: "{pref}"
                          route:
                            cluster: {ag['cluster_name']}
                            prefix_rewrite: "/"
                            timeout: 360s
                            idle_timeout: 360s""")
  route_blocks.append("""                        - match:
                            prefix: "/"
                          direct_response:
                            status: 404
                            body:
                              inline_string: "agent not active\\n\"""")

  cluster_blocks = []
  for ag in active_agents:
    cluster_blocks.append(f"""    - name: {ag['cluster_name']}
      type: STRICT_DNS
      connect_timeout: 5s
      lb_policy: ROUND_ROBIN
      load_assignment:
        cluster_name: {ag['cluster_name']}
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: {ag['service_name']}.{ag['namespace']}.svc.cluster.local
                      port_value: {ag['service_port']}
""")

  routes_str = "\n".join(route_blocks)
  clusters_str = "\n".join(cluster_blocks)
  if clusters_str:
    clusters_str += "\n"
  return f"""admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901

static_resources:
  listeners:
    - name: mtls_ingress_8443
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 8443
      filter_chains:
        - transport_socket:
            name: envoy.transport_sockets.tls
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
              require_client_certificate: true
              common_tls_context:
                tls_params:
                  tls_minimum_protocol_version: TLSv1_3
                  tls_maximum_protocol_version: TLSv1_3
                tls_certificates:
                  - certificate_chain:
                      filename: /etc/envoy/tls/tls.crt
                    private_key:
                      filename: /etc/envoy/tls/tls.key
                    watched_directory:
                      path: /etc/envoy/tls
                validation_context:
                  trusted_ca:
                    filename: /etc/envoy/root-ca/ca.crt
                  watched_directory:
                    path: /etc/envoy/root-ca
                  match_typed_subject_alt_names:
                    - san_type: DNS
                      matcher:
                        exact: "apigee-runtime.apigee.hybrid-agents.internal"
          filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: agent_mtls_ingress
                codec_type: AUTO
                use_remote_address: true
                generate_request_id: true
                preserve_external_request_id: true
                forward_client_cert_details: SANITIZE_SET
                set_current_client_cert_details:
                  subject: true
                  dns: true
                stream_idle_timeout: 360s
                tracing:
                  provider:
                    name: envoy.tracers.opentelemetry
                    typed_config:
                      "@type": type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig
                      grpc_service:
                        envoy_grpc:
                          cluster_name: otel_collector_grpc
                        timeout: 2s
                      service_name: agent-ingress-envoy
                  spawn_upstream_span: true
                route_config:
                  name: adk_agent_routes
                  virtual_hosts:
                    - name: adk_agents
                      domains: ["*"]
                      routes:
{routes_str}
                http_filters:
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

    - name: observability_19000
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 19000
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: envoy_observability
                route_config:
                  name: readonly_admin_routes
                  virtual_hosts:
                    - name: local_observability
                      domains: ["*"]
                      routes:
                        - match:
                            path: "/ready"
                          route:
                            cluster: envoy_admin_loopback
                        - match:
                            prefix: "/stats/prometheus"
                          route:
                            cluster: envoy_admin_loopback
                        - match:
                            prefix: "/"
                          direct_response:
                            status: 403
                            body:
                              inline_string: "forbidden\\n"
                http_filters:
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
{clusters_str}    - name: otel_collector_grpc
      type: STRICT_DNS
      connect_timeout: 2s
      lb_policy: ROUND_ROBIN
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http2_protocol_options: {{}}
      load_assignment:
        cluster_name: otel_collector_grpc
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: otel-collector.otel-system.svc.cluster.local
                      port_value: 4317

    - name: envoy_admin_loopback
      type: STATIC
      connect_timeout: 1s
      load_assignment:
        cluster_name: envoy_admin_loopback
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: 127.0.0.1
                      port_value: 9901
"""


if not agents:
  for gf in generated_files:
    if gf.exists():
      gf.unlink()
  kustomization_text = (
      LICENSE_HEADER
      + "\n# Generated by render.sh from registry/agents/*/agent.yaml (0 active agents).\n"
      + "apiVersion: kustomize.config.k8s.io/v1beta1\n"
      + "kind: Kustomization\n"
      + "resources:\n"
      + "  - ../../base\n"
  )
  (overlay_dir / "kustomization.yaml").write_text(
      kustomization_text, encoding="utf-8"
  )
  print("Generated src/overlays/agents for 0 active agent(s) (shared Envoy idle baseline).")
  sys.exit(0)

# Build Envoy configs and config-version hashes
egress_yaml = _build_egress_envoy_yaml(agents)
egress_sha = hashlib.sha256(egress_yaml.encode("utf-8")).hexdigest()[:12]
ingress_yaml = _build_ingress_envoy_yaml(agents)
ingress_sha = hashlib.sha256(ingress_yaml.encode("utf-8")).hexdigest()[:12]

# 1. ConfigMap strategic-merge patches for shared Envoys
(overlay_dir / "generated-egress-envoy-config.yaml").write_text(
    LICENSE_HEADER
    + "\n# Generated by render.sh from registry/agents/*/agent.yaml. Do not edit by hand.\n"
    + "apiVersion: v1\n"
    + "data:\n"
    + "  envoy.yaml: |\n"
    + _indent(egress_yaml, 4)
    + "\nkind: ConfigMap\n"
    + "metadata:\n"
    + "  name: agent-egress-envoy-config\n"
    + "  namespace: agent-workloads\n",
    encoding="utf-8",
)

(overlay_dir / "generated-ingress-envoy-config.yaml").write_text(
    LICENSE_HEADER
    + "\n# Generated by render.sh from registry/agents/*/agent.yaml. Do not edit by hand.\n"
    + "apiVersion: v1\n"
    + "data:\n"
    + "  envoy.yaml: |\n"
    + _indent(ingress_yaml, 4)
    + "\nkind: ConfigMap\n"
    + "metadata:\n"
    + "  name: agent-ingress-envoy-config\n"
    + "  namespace: agent-workloads\n",
    encoding="utf-8",
)

# 2. PodMonitoring for active agents only
comp_values = sorted({a["component_label"] for a in agents})
pm_values_yaml = "\n".join(f"          - {c}" for c in comp_values)
(overlay_dir / "generated-pod-monitoring.yaml").write_text(
    LICENSE_HEADER
    + "\n# Generated by render.sh from registry/agents/*/agent.yaml. Do not edit by hand.\n"
    + "apiVersion: monitoring.googleapis.com/v1\n"
    + "kind: PodMonitoring\n"
    + "metadata:\n"
    + "  labels:\n"
    + "    app.kubernetes.io/part-of: hybrid-cloud-agents\n"
    + "  name: adk-agents-monitoring\n"
    + "  namespace: agent-workloads\n"
    + "spec:\n"
    + "  endpoints:\n"
    + "    - interval: 30s\n"
    + "      path: /metrics\n"
    + "      port: metrics\n"
    + "  selector:\n"
    + "    matchExpressions:\n"
    + "      - key: app.kubernetes.io/component\n"
    + "        operator: In\n"
    + "        values:\n"
    + pm_values_yaml
    + "\n",
    encoding="utf-8",
)

# 3. Peer ConfigMap patches for any active agent declaring a2aPeers
peer_patch_docs = []
for ag in agents:
  if not ag["a2a_peers"]:
    continue
  peers_obj = {}
  for peer in ag["a2a_peers"]:
    pname = str(peer["name"])
    if pname not in active_names:
      continue
    a2a_path = str(peer["a2aPath"])
    card_path = str(peer["agentCardGatewayPath"])
    peers_obj[pname] = {
        "a2a_egress_url": f"{ag['endpoint']}{a2a_path}",
        "agent_card_gateway_url": f"https://api.hybrid-agents.internal{card_path}",
        "canonical_gateway_url": f"https://api.hybrid-agents.internal{a2a_path}",
        "protocol_binding": str(peer.get("protocolBinding", "HTTP+JSON")),
        "required_skill": str(peer.get("requiredSkill", "")),
    }
  peer_json = json.dumps(
      {
          "discovery_source": "agent-registry-gitops-configmap",
          "peers": peers_obj,
      },
      indent=2,
      sort_keys=True,
  )
  peer_patch_docs.append(
      "apiVersion: v1\n"
      + "data:\n"
      + "  peer-agents.json: |\n"
      + _indent(peer_json, 4)
      + "\nkind: ConfigMap\n"
      + "metadata:\n"
      + f"  name: {ag['name']}-config\n"
      + f"  namespace: {ag['namespace']}\n"
  )

peer_patch_file = overlay_dir / "generated-peer-config.yaml"
if peer_patch_docs:
  peer_patch_file.write_text(
      LICENSE_HEADER
      + "\n# Generated by render.sh from registry/agents/*/agent.yaml. Do not edit by hand.\n"
      + "---\n".join(peer_patch_docs),
      encoding="utf-8",
  )
elif peer_patch_file.exists():
  peer_patch_file.unlink()

# 4. Build JSON-6902 patches for shared Envoy Deployments, Service, and NetworkPolicies
egress_ports = [
    {"containerPort": a["port"], "name": a["port_name"], "protocol": "TCP"}
    for a in agents
] + [{"containerPort": 19000, "name": "metrics", "protocol": "TCP"}]

egress_mounts = [
    {"mountPath": "/etc/envoy", "name": "config", "readOnly": True},
    {"mountPath": "/etc/envoy/tls", "name": "tls", "readOnly": True},
    {"mountPath": "/etc/envoy/root-ca", "name": "root-ca", "readOnly": True},
] + [
    {"mountPath": a["mount_path"], "name": a["volume_name"], "readOnly": True}
    for a in agents
] + [{"mountPath": "/tmp", "name": "tmp"}]

egress_volumes = [
    {"configMap": {"name": "agent-egress-envoy-config"}, "name": "config"},
    {"name": "tls", "secret": {"secretName": "agent-envoy-egress-client-tls"}},
    {"name": "root-ca", "secret": {"secretName": "hybrid-agents-root-ca-bundle"}},
] + [
    {"name": a["volume_name"], "secret": {"secretName": a["secret_name"]}}
    for a in agents
] + [{"emptyDir": {"medium": "Memory", "sizeLimit": "16Mi"}, "name": "tmp"}]

egress_svc_ports = [
    {
        "name": a["port_name"],
        "port": a["port"],
        "protocol": "TCP",
        "targetPort": a["port"],
    }
    for a in agents
]

egress_dep_patch = [
    {
        "op": "replace",
        "path": "/spec/template/metadata/annotations/envoy.hybrid-agents.internal~1config-version",
        "value": f"v0.7.0-{egress_sha}",
    },
    {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/ports",
        "value": egress_ports,
    },
    {
        "op": "replace",
        "path": "/spec/template/spec/containers/0/volumeMounts",
        "value": egress_mounts,
    },
    {
        "op": "replace",
        "path": "/spec/template/spec/volumes",
        "value": egress_volumes,
    },
]

ingress_dep_patch = [
    {
        "op": "replace",
        "path": "/spec/template/metadata/annotations/envoy.hybrid-agents.internal~1config-version",
        "value": f"v0.7.0-{ingress_sha}",
    },
]

egress_svc_patch = [
    {
        "op": "replace",
        "path": "/spec/ports",
        "value": egress_svc_ports,
    }
]

egress_np_patch = [
    {
        "op": "add",
        "path": "/spec/ingress/-",
        "value": {
            "from": [
                {
                    "namespaceSelector": {
                        "matchLabels": {
                            "kubernetes.io/metadata.name": a["namespace"]
                        }
                    },
                    "podSelector": {
                        "matchLabels": {
                            "app.kubernetes.io/component": a["component_label"]
                        }
                    },
                }
            ],
            "ports": [{"port": a["port"], "protocol": "TCP"}],
        },
    }
    for a in agents
]

ingress_np_patch = [
    {
        "op": "add",
        "path": "/spec/egress/-",
        "value": {
            "ports": [{"port": a["service_port"], "protocol": "TCP"}],
            "to": [
                {
                    "namespaceSelector": {
                        "matchLabels": {
                            "kubernetes.io/metadata.name": a["namespace"]
                        }
                    },
                    "podSelector": {
                        "matchLabels": {
                            "app.kubernetes.io/component": a["component_label"]
                        }
                    },
                }
            ],
        },
    }
    for a in agents
]

# Keep keys alphabetically sorted in kustomization.yaml
patch_entries = [
    "  - path: generated-egress-envoy-config.yaml",
    "  - path: generated-ingress-envoy-config.yaml",
]
if peer_patch_docs:
  patch_entries.append("  - path: generated-peer-config.yaml")


def _inline_json_patch(kind: str, name: str, ops: list[dict]) -> str:
  patch_json = json.dumps(ops, sort_keys=True)
  return (
      "  - patch: |-\n"
      + f"      {patch_json}\n"
      + "    target:\n"
      + f"      kind: {kind}\n"
      + f"      name: {name}\n"
      + "      namespace: agent-workloads"
  )


patch_entries.extend([
    _inline_json_patch("Deployment", "agent-egress-envoy", egress_dep_patch),
    _inline_json_patch("Deployment", "agent-ingress-envoy", ingress_dep_patch),
    _inline_json_patch("Service", "agent-egress-envoy", egress_svc_patch),
    _inline_json_patch(
        "NetworkPolicy", "allow-agent-egress-proxy", egress_np_patch
    ),
    _inline_json_patch(
        "NetworkPolicy", "allow-envoy-ingress-proxy", ingress_np_patch
    ),
])

# Sync each active agent's NetworkPolicy egress port directly from agent.yaml
for a in agents:
  np_name = (
      "allow-adk-agents"
      if a["name"] == "adk-sovereign-agent"
      else f"allow-{a['name']}"
  )
  patch_entries.append(
      _inline_json_patch(
          "NetworkPolicy",
          np_name,
          [
              {
                  "op": "replace",
                  "path": "/spec/egress/0/ports/0/port",
                  "value": a["port"],
              }
          ],
      )
  )

comp_lines = "\n".join(
    f"  - ../../components/agents/{a['name']}" for a in agents
)
kustomization_text = (
    LICENSE_HEADER
    + f"\n# Generated by render.sh from registry/agents/*/agent.yaml ({len(agents)} active agent(s)).\n"
    + "apiVersion: kustomize.config.k8s.io/v1beta1\n"
    + "components:\n"
    + comp_lines
    + "\nkind: Kustomization\n"
    + "patches:\n"
    + "\n".join(patch_entries)
    + "\nresources:\n"
    + "  - ../../base\n"
    + "  - generated-pod-monitoring.yaml\n"
)
(overlay_dir / "kustomization.yaml").write_text(
    kustomization_text, encoding="utf-8"
)
if (overlay_dir / "generated-envoy-patches.yaml").exists():
  (overlay_dir / "generated-envoy-patches.yaml").unlink()

print(
    f"Generated src/overlays/agents for {len(agents)} active agent(s): "
    + ", ".join(f"{a['name']}:{a['port']}" for a in agents)
    + "."
)
EOF
}

if [[ $# -gt 0 ]]; then
  VARIANTS=("$@")
else
  VARIANTS=("agents-platform" "gateway-tools-platform" "agents")
fi

for VARIANT in "${VARIANTS[@]}"; do
  if [[ "${VARIANT}" == "agents" ]]; then
    generate_agents_overlay
  fi

  OVERLAY_DIR="${SCRIPT_DIR}/src/overlays/${VARIANT}"
  OUTPUT_DIR="${SCRIPT_DIR}/environments/${VARIANT}"
  OUTPUT_FILE="${OUTPUT_DIR}/manifests.yaml"

  mkdir -p "${OUTPUT_DIR}"
  TMP_FILE="$(mktemp "${OUTPUT_DIR}/.manifests.XXXXXX.yaml")"
  trap 'rm -f "${TMP_FILE}"' EXIT

  {
    cat << 'EOF'
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

# Generated by render.sh from src/overlays. Do not edit by hand.
EOF
    kubectl kustomize "${OVERLAY_DIR}"
  } > "${TMP_FILE}"

  # Commit the bundle formatted with prettier (CI only checks Markdown, so this
  # keeps diffs stable). Set PRETTIER to your prettier command, for example:
  #   PRETTIER="npx --prefix .devcontainer/dependencies prettier" ./render.sh
  if [[ -n ${PRETTIER:-} ]]; then
    read -r -a PRETTIER_CMD <<< "${PRETTIER}"
    "${PRETTIER_CMD[@]}" --write "${TMP_FILE}"
    mv "${TMP_FILE}" "${OUTPUT_FILE}"
    echo "Rendered ${OVERLAY_DIR} to ${OUTPUT_FILE}"
  elif [[ -x "${REPO_ROOT}/node_modules/.bin/prettier" ]]; then
    "${REPO_ROOT}/node_modules/.bin/prettier" --write "${TMP_FILE}"
    mv "${TMP_FILE}" "${OUTPUT_FILE}"
    echo "Rendered ${OVERLAY_DIR} to ${OUTPUT_FILE}"
  elif [[ -x "${REPO_ROOT}/.devcontainer/dependencies/node_modules/.bin/prettier" ]]; then
    "${REPO_ROOT}/.devcontainer/dependencies/node_modules/.bin/prettier" --write "${TMP_FILE}"
    mv "${TMP_FILE}" "${OUTPUT_FILE}"
    echo "Rendered ${OVERLAY_DIR} to ${OUTPUT_FILE}"
  else
    mv "${TMP_FILE}" "${OUTPUT_FILE}"
    echo "Rendered ${OVERLAY_DIR} to ${OUTPUT_FILE}"
    echo "Format ${OUTPUT_FILE} with prettier before you commit it."
  fi
done
