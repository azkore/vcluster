#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Install or upgrade the patched vCluster Private Nodes PoC control plane.

Required env:
  VCLUSTER_ENDPOINT     Externally reachable host:port, e.g. demo.example:443

Optional env:
  VCLUSTER_NAME         Helm release name (default: private-nodes-poc)
  VCLUSTER_NAMESPACE    Host namespace (default: private-nodes-poc)
  HOST_CONTEXT          kubectl/helm context (default: current context)
  CHART_DIR             Local chart path (default: this repo's chart/)
  TEMPLATE              Values template path
  RENDERED_VALUES       Rendered output path (default: runtime/generated-values-<name>.yaml)
  ENDPOINT_READY_TIMEOUT how long to wait for LoadBalancer/DNS readiness (default: 10m)
  RESTART_AFTER_ENDPOINT_READY restart control plane after endpoint is ready (default: true)

This script writes no secrets. It renders the durable values template and runs
helm upgrade --install against the local vCluster fork chart.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

: "${VCLUSTER_ENDPOINT:?set VCLUSTER_ENDPOINT to the public vCluster endpoint host:port}"

VCLUSTER_NAME="${VCLUSTER_NAME:-private-nodes-poc}"
VCLUSTER_NAMESPACE="${VCLUSTER_NAMESPACE:-private-nodes-poc}"
HOST_CONTEXT="${HOST_CONTEXT:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
CHART_DIR="${CHART_DIR:-${REPO_DIR}/chart}"
TEMPLATE="${TEMPLATE:-${ROOT_DIR}/values/private-nodes-poc.yaml.tmpl}"
RENDERED_VALUES="${RENDERED_VALUES:-${ROOT_DIR}/runtime/generated-values-${VCLUSTER_NAME}.yaml}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd helm
require_cmd kubectl
require_cmd python3

if [[ ! -d "${CHART_DIR}" ]]; then
  echo "chart directory not found: ${CHART_DIR}" >&2
  exit 1
fi
if [[ ! -f "${TEMPLATE}" ]]; then
  echo "values template not found: ${TEMPLATE}" >&2
  exit 1
fi

mkdir -p "$(dirname -- "${RENDERED_VALUES}")"
python3 - "$TEMPLATE" "$RENDERED_VALUES" "$VCLUSTER_ENDPOINT" <<'PY'
import pathlib
import sys

template, output, endpoint = sys.argv[1:]
endpoint_host = endpoint.rsplit(":", 1)[0]
data = pathlib.Path(template).read_text()
data = data.replace("__VCLUSTER_ENDPOINT__", endpoint)
data = data.replace("__VCLUSTER_ENDPOINT_HOST__", endpoint_host)
pathlib.Path(output).write_text(data)
PY

context_args=()
if [[ -n "${HOST_CONTEXT}" ]]; then
  context_args=(--context "${HOST_CONTEXT}")
fi

helm_context_args=()
if [[ -n "${HOST_CONTEXT}" ]]; then
  helm_context_args=(--kube-context "${HOST_CONTEXT}")
fi

endpoint_host="${VCLUSTER_ENDPOINT%:*}"
ENDPOINT_READY_TIMEOUT="${ENDPOINT_READY_TIMEOUT:-10m}"
RESTART_AFTER_ENDPOINT_READY="${RESTART_AFTER_ENDPOINT_READY:-true}"

timeout_seconds() {
  python3 - "$1" <<'PY'
import re
import sys

value = sys.argv[1]
match = re.fullmatch(r"(\d+)([smh]?)", value)
if not match:
    raise SystemExit(f"unsupported timeout {value!r}; use seconds or a simple s/m/h duration")
amount = int(match.group(1))
unit = match.group(2) or "s"
print(amount * {"s": 1, "m": 60, "h": 3600}[unit])
PY
}

wait_for_control_plane_endpoint() {
  local timeout deadline service_ingress ready
  timeout="$(timeout_seconds "${ENDPOINT_READY_TIMEOUT}")"
  deadline=$((SECONDS + timeout))

  echo "Waiting for LoadBalancer and endpoint DNS for ${VCLUSTER_ENDPOINT}..."
  while (( SECONDS < deadline )); do
    service_ingress="$(kubectl get svc "${VCLUSTER_NAME}" -n "${VCLUSTER_NAMESPACE}" "${context_args[@]}" -o jsonpath='{range .status.loadBalancer.ingress[*]}{.ip}{" "}{.hostname}{" "}{end}' 2>/dev/null || true)"
    if [[ -n "${service_ingress// /}" ]]; then
      ready="$(python3 - "${endpoint_host}" "${service_ingress}" <<'PY'
import ipaddress
import socket
import sys

host, ingress = sys.argv[1], sys.argv[2].split()

try:
    ipaddress.ip_address(host)
    resolved = {host}
except ValueError:
    try:
        resolved = {item[4][0] for item in socket.getaddrinfo(host, None, socket.AF_INET)}
    except OSError:
        resolved = set()

ingress_ips = {item for item in ingress if item and item[0].isdigit()}
if resolved and (not ingress_ips or resolved & ingress_ips):
    print("ready")
PY
)"
      if [[ "${ready}" == "ready" ]]; then
        echo "Endpoint is ready: ${endpoint_host} -> ${service_ingress}"
        return 0
      fi
    fi
    sleep 5
  done

  echo "timed out waiting for ${VCLUSTER_NAME} LoadBalancer/DNS endpoint" >&2
  return 1
}

restart_control_plane() {
  if [[ "${RESTART_AFTER_ENDPOINT_READY}" != "true" ]]; then
    return 0
  fi

  # The Private Nodes PoC writes the virtual default/kubernetes Endpoints at
  # startup from controlPlane.endpoint. Restart after the external endpoint is
  # resolvable so DNS and in-cluster clients can reach the virtual apiserver.
  echo "Restarting control plane after endpoint readiness..."
  kubectl delete pod "${VCLUSTER_NAME}-0" -n "${VCLUSTER_NAMESPACE}" "${context_args[@]}" --wait=false
  kubectl wait pod "${VCLUSTER_NAME}-0" -n "${VCLUSTER_NAMESPACE}" "${context_args[@]}" --for=condition=Ready --timeout=10m
}

kubectl get namespace "${VCLUSTER_NAMESPACE}" "${context_args[@]}" >/dev/null 2>&1 || \
  kubectl create namespace "${VCLUSTER_NAMESPACE}" "${context_args[@]}"

helm upgrade --install "${VCLUSTER_NAME}" "${CHART_DIR}" \
  --namespace "${VCLUSTER_NAMESPACE}" \
  "${helm_context_args[@]}" \
  --values "${RENDERED_VALUES}" \
  --wait \
  --timeout 10m

wait_for_control_plane_endpoint
restart_control_plane

echo "Rendered values: ${RENDERED_VALUES}"
if [[ -n "${HOST_CONTEXT}" ]]; then
  echo "Control plane service: kubectl get svc ${VCLUSTER_NAME} -n ${VCLUSTER_NAMESPACE} --context ${HOST_CONTEXT} -o wide"
else
  echo "Control plane service: kubectl get svc ${VCLUSTER_NAME} -n ${VCLUSTER_NAMESPACE} -o wide"
fi
