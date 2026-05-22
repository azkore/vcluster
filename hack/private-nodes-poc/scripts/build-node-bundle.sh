#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build a node bootstrap binary bundle from the same images used in the PoC.

Optional env:
  K8S_IMAGE           default ghcr.io/loft-sh/kubernetes:v1.35.0-full
  KUBE_PROXY_IMAGE    default registry.k8s.io/kube-proxy:v1.35.0
  PROXY_AGENT_IMAGE   default registry.k8s.io/kas-network-proxy/proxy-agent:v0.31.2
  OUT                 output tgz path (default: dist/vcluster-node-bundle-v1.35.0.tgz)

The resulting archive is intended to be copied to a fresh VM or served from a
temporary URL and consumed by bootstrap-private-node.sh.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

K8S_IMAGE="${K8S_IMAGE:-ghcr.io/loft-sh/kubernetes:v1.35.0-full}"
KUBE_PROXY_IMAGE="${KUBE_PROXY_IMAGE:-registry.k8s.io/kube-proxy:v1.35.0}"
PROXY_AGENT_IMAGE="${PROXY_AGENT_IMAGE:-registry.k8s.io/kas-network-proxy/proxy-agent:v0.31.2}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
OUT="${OUT:-${ROOT_DIR}/dist/vcluster-node-bundle-v1.35.0.tgz}"

command -v docker >/dev/null 2>&1 || {
  echo "docker is required to extract binaries from images" >&2
  exit 1
}

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

staging="${tmp}/bundle"
mkdir -p "${staging}/bin" "${staging}/opt/cni/bin"

copy_path_from_image() {
  local image="$1"
  local source_path="$2"
  local dest_path="$3"
  local cid
  cid="$(docker create "$image" /bin/true)"
  trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; cleanup' EXIT
  if docker cp "${cid}:${source_path}" "${dest_path}" >/dev/null 2>&1; then
    docker rm -f "$cid" >/dev/null
    trap cleanup EXIT
    return 0
  fi
  docker rm -f "$cid" >/dev/null
  trap cleanup EXIT
  return 1
}

copy_binary() {
  local image="$1"
  local binary="$2"
  local dest="${staging}/bin/${binary}"
  local candidate
  for candidate in "/usr/local/bin/${binary}" "/usr/bin/${binary}" "/bin/${binary}" "/${binary}"; do
    if copy_path_from_image "$image" "$candidate" "$dest"; then
      chmod 0755 "$dest"
      return 0
    fi
  done
  echo "could not find ${binary} in ${image}" >&2
  exit 1
}

release_tgz="${tmp}/kubernetes-release.tgz"
if ! copy_path_from_image "$K8S_IMAGE" "/kubernetes/kubernetes-v1.35.0-amd64.tar.gz" "$release_tgz"; then
  echo "could not find embedded Kubernetes release archive in ${K8S_IMAGE}" >&2
  exit 1
fi
tar -C "$tmp" -xzf "$release_tgz"
for binary in kubeadm kubelet kubectl containerd containerd-shim-runc-v2 ctr crictl runc; do
  install -m 0755 "${tmp}/release/${binary}" "${staging}/bin/${binary}"
done
install -m 0755 "${tmp}"/release/cni/bin/* "${staging}/opt/cni/bin/"

copy_binary "$KUBE_PROXY_IMAGE" kube-proxy
copy_binary "$PROXY_AGENT_IMAGE" proxy-agent

mkdir -p "$(dirname -- "$OUT")"
tar -C "$staging" -czf "$OUT" .
echo "Wrote ${OUT}"
