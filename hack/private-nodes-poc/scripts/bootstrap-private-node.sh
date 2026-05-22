#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Bootstrap a fresh Ubuntu/Debian VM as a vCluster Private Node.

Run as root on the target VM. Pass a config file as the first argument or set
NODE_CONFIG. The config is a shell env file.

Required config:
  NODE_NAME                 virtual Kubernetes node name
  NODE_IP                   IP the kubelet should advertise in the vCluster
  VCLUSTER_ENDPOINT         public vCluster API endpoint host:port
  KUBEADM_TOKEN             bootstrap token minted in the virtual cluster
  KUBE_PROXY_TOKEN          token for kube-system/kube-proxy
  KONNECTIVITY_TOKEN        token for kube-system/konnectivity-agent, audience system:konnectivity-server
  VCLUSTER_CA_B64           base64 CA data, or set VCLUSTER_CA_FILE
  NODE_BUNDLE               local binary bundle path, or set NODE_BUNDLE_URL

Optional config:
  POD_CIDR                  skip waiting for assigned .spec.podCIDR
  CLUSTER_CIDR              default 10.244.0.0/16
  CLUSTER_DNS               default 10.96.0.10
  KONNECTIVITY_SERVER_PORT  default 8091
  KONNECTIVITY_AGENT_IDENTIFIERS default host=$NODE_NAME&ipv4=$NODE_IP
  WG_ENABLE                 true/false, default false
  WG_ADDRESS                e.g. 10.250.0.1/30
  WG_PRIVATE_KEY            WireGuard private key
  WG_PEER_PUBLIC_KEY        WireGuard peer public key
  WG_PEER_ENDPOINT          e.g. <peer-public-ip>:51820
  WG_ALLOWED_IPS            e.g. 10.250.0.2/32,10.244.0.0/24
  WG_LISTEN_PORT            default 51820
  WG_MTU                    default 1380

No secrets are printed. Secret material is written only to root-owned files on
the target VM.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

config_file="${1:-${NODE_CONFIG:-}}"
if [[ -n "${config_file}" ]]; then
  # shellcheck source=/dev/null
  source "${config_file}"
fi

: "${NODE_NAME:?set NODE_NAME}"
: "${NODE_IP:?set NODE_IP}"
: "${VCLUSTER_ENDPOINT:?set VCLUSTER_ENDPOINT}"
: "${KUBEADM_TOKEN:?set KUBEADM_TOKEN}"
: "${KUBE_PROXY_TOKEN:?set KUBE_PROXY_TOKEN}"
: "${KONNECTIVITY_TOKEN:?set KONNECTIVITY_TOKEN}"

CLUSTER_CIDR="${CLUSTER_CIDR:-10.244.0.0/16}"
CLUSTER_DNS="${CLUSTER_DNS:-10.96.0.10}"
KONNECTIVITY_SERVER_PORT="${KONNECTIVITY_SERVER_PORT:-8091}"
KONNECTIVITY_AGENT_IDENTIFIERS="${KONNECTIVITY_AGENT_IDENTIFIERS:-host=${NODE_NAME}&ipv4=${NODE_IP}}"
WG_ENABLE="${WG_ENABLE:-false}"

if [[ -z "${NODE_BUNDLE:-}" && -z "${NODE_BUNDLE_URL:-}" ]]; then
  echo "set NODE_BUNDLE or NODE_BUNDLE_URL" >&2
  exit 1
fi
if [[ -z "${VCLUSTER_CA_B64:-}" && -z "${VCLUSTER_CA_FILE:-}" ]]; then
  echo "set VCLUSTER_CA_B64 or VCLUSTER_CA_FILE" >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command after install: $1" >&2
    exit 1
  }
}

install_os_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl tar gzip iproute2 iptables ebtables ethtool kmod \
      socat conntrack python3 wireguard-tools
  else
    echo "apt-get not found; assuming base networking packages already exist" >&2
  fi
}

install_bundle() {
  local bundle_path="${NODE_BUNDLE:-/tmp/vcluster-node-bundle.tgz}"
  if [[ -n "${NODE_BUNDLE_URL:-}" ]]; then
    curl -fsSL "${NODE_BUNDLE_URL}" -o "$bundle_path"
  fi
  if [[ ! -f "$bundle_path" ]]; then
    echo "bundle not found: $bundle_path" >&2
    exit 1
  fi

  local tmp
  tmp="$(mktemp -d)"
  tar -C "$tmp" -xzf "$bundle_path"
  install -d -m 0755 /usr/local/bin /opt/cni/bin /etc/cni/net.d
  install -m 0755 "$tmp"/bin/* /usr/local/bin/
  if compgen -G "$tmp/opt/cni/bin/*" >/dev/null; then
    install -m 0755 "$tmp"/opt/cni/bin/* /opt/cni/bin/
  fi
  rm -rf "$tmp"
}

write_kernel_networking() {
  install -d -m 0755 /etc/modules-load.d /etc/sysctl.d
  cat >/etc/modules-load.d/vcluster-private-node.conf <<'EOF'
br_netfilter
EOF
  modprobe br_netfilter || true

  cat >/etc/sysctl.d/98-vcluster-bridge-netfilter.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

  if [[ "$WG_ENABLE" == "true" ]]; then
    cat >/etc/sysctl.d/99-vcluster-private-node.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  fi

  sysctl --system >/dev/null
}

write_ca() {
  install -d -m 0755 /etc/kubernetes/pki /etc/kubernetes
  if [[ -n "${VCLUSTER_CA_FILE:-}" ]]; then
    install -m 0644 "$VCLUSTER_CA_FILE" /etc/kubernetes/pki/ca.crt
  else
    printf '%s' "$VCLUSTER_CA_B64" | base64 -d >/etc/kubernetes/pki/ca.crt
    chmod 0644 /etc/kubernetes/pki/ca.crt
  fi
  cp /etc/kubernetes/pki/ca.crt /etc/kubernetes/vcluster-konnectivity-server-ca.crt
}

write_containerd() {
  install -d -m 0755 /etc/containerd
  if containerd config default >/etc/containerd/config.toml.tmp 2>/dev/null; then
    python3 - <<'PY'
from pathlib import Path
p = Path('/etc/containerd/config.toml.tmp')
s = p.read_text()
s = s.replace('SystemdCgroup = false', 'SystemdCgroup = true')
Path('/etc/containerd/config.toml').write_text(s)
PY
    rm -f /etc/containerd/config.toml.tmp
  else
    cat >/etc/containerd/config.toml <<'EOF'
version = 2
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
  runtime_type = "io.containerd.runc.v2"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
  fi

  cat >/etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
}

write_kubelet() {
  install -d -m 0755 /var/lib/kubelet /etc/default
  cat >/etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/
After=containerd.service
Wants=containerd.service

[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
Environment="KUBELET_EXTRA_ARGS=--fail-swap-on=false --node-ip=${NODE_IP}"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

write_discovery() {
  cat >/root/vcluster-discovery.conf <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://${VCLUSTER_ENDPOINT}
  name: vcluster
contexts:
- context:
    cluster: vcluster
    user: bootstrap
  name: bootstrap
current-context: bootstrap
users:
- name: bootstrap
  user:
    token: ${KUBEADM_TOKEN}
EOF
  chmod 0600 /root/vcluster-discovery.conf
}

join_node() {
  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl enable kubelet
  kubeadm reset -f || true
  write_ca
  write_discovery
  kubeadm join \
    --discovery-file /root/vcluster-discovery.conf \
    --tls-bootstrap-token "${KUBEADM_TOKEN}" \
    --cri-socket unix:///run/containerd/containerd.sock \
    --node-name "${NODE_NAME}" \
    --ignore-preflight-errors=all \
    --v=4
}

wait_for_pod_cidr() {
  if [[ -n "${POD_CIDR:-}" ]]; then
    echo "$POD_CIDR"
    return 0
  fi
  local cidr=""
  for _ in $(seq 1 120); do
    cidr="$(kubectl --kubeconfig=/etc/kubernetes/kubelet.conf get node "${NODE_NAME}" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || true)"
    if [[ -n "$cidr" ]]; then
      echo "$cidr"
      return 0
    fi
    sleep 5
  done
  echo "timed out waiting for ${NODE_NAME} PodCIDR; set POD_CIDR and rerun CNI/kube-proxy steps" >&2
  exit 1
}

write_cni() {
  local pod_cidr="$1"
  cat >/etc/cni/net.d/10-vcluster-bridge.conflist <<EOF
{
  "cniVersion": "1.0.0",
  "name": "vcluster-poc",
  "plugins": [
    {
      "type": "bridge",
      "bridge": "cni0",
      "isGateway": true,
      "ipMasq": true,
      "hairpinMode": true,
      "ipam": {
        "type": "host-local",
        "subnet": "${pod_cidr}",
        "routes": [{ "dst": "0.0.0.0/0" }]
      }
    },
    {
      "type": "portmap",
      "capabilities": { "portMappings": true }
    }
  ]
}
EOF
}

write_token_kubeconfig() {
  local path="$1"
  local user="$2"
  local token="$3"
  cat >"$path" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority: /etc/kubernetes/pki/ca.crt
    server: https://${VCLUSTER_ENDPOINT}
  name: vcluster
contexts:
- context:
    cluster: vcluster
    user: ${user}
  name: ${user}@vcluster
current-context: ${user}@vcluster
users:
- name: ${user}
  user:
    token: ${token}
EOF
  chmod 0600 "$path"
}

write_kube_proxy() {
  write_token_kubeconfig /etc/kubernetes/kube-proxy.conf kube-proxy "$KUBE_PROXY_TOKEN"
  cat >/etc/kubernetes/kube-proxy-config.yaml <<EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
clusterCIDR: ${CLUSTER_CIDR}
hostnameOverride: ${NODE_NAME}
clientConnection:
  kubeconfig: /etc/kubernetes/kube-proxy.conf
conntrack:
  maxPerCore: 0
  min: 0
EOF
  cat >/etc/systemd/system/kube-proxy.service <<'EOF'
[Unit]
Description=Kubernetes kube-proxy for vCluster PoC
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kube-proxy --config=/etc/kubernetes/kube-proxy-config.yaml --v=2
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_konnectivity() {
  printf '%s' "$KONNECTIVITY_TOKEN" >/etc/kubernetes/konnectivity-agent-token
  chmod 0600 /etc/kubernetes/konnectivity-agent-token
  local host="${VCLUSTER_ENDPOINT%:*}"
  cat >/etc/systemd/system/konnectivity-agent.service <<EOF
[Unit]
Description=Konnectivity Agent for vCluster PoC
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/proxy-agent \\
  --logtostderr=true \\
  --proxy-server-host=${host} \\
  --proxy-server-port=${KONNECTIVITY_SERVER_PORT} \\
  --ca-cert=/etc/kubernetes/vcluster-konnectivity-server-ca.crt \\
  --service-account-token-path=/etc/kubernetes/konnectivity-agent-token \\
  --agent-identifiers=${KONNECTIVITY_AGENT_IDENTIFIERS} \\
  --health-server-host=127.0.0.1 \\
  --health-server-port=8093 \\
  --admin-bind-address=127.0.0.1 \\
  --admin-server-port=8094 \\
  --v=4
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_wireguard() {
  if [[ "$WG_ENABLE" != "true" ]]; then
    return 0
  fi
  : "${WG_ADDRESS:?set WG_ADDRESS when WG_ENABLE=true}"
  : "${WG_PRIVATE_KEY:?set WG_PRIVATE_KEY when WG_ENABLE=true}"
  : "${WG_PEER_PUBLIC_KEY:?set WG_PEER_PUBLIC_KEY when WG_ENABLE=true}"
  : "${WG_PEER_ENDPOINT:?set WG_PEER_ENDPOINT when WG_ENABLE=true}"
  : "${WG_ALLOWED_IPS:?set WG_ALLOWED_IPS when WG_ENABLE=true}"
  WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
  WG_MTU="${WG_MTU:-1380}"
  install -d -m 0700 /etc/wireguard
  cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_ADDRESS}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = ${WG_PRIVATE_KEY}
MTU = ${WG_MTU}

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
Endpoint = ${WG_PEER_ENDPOINT}
AllowedIPs = ${WG_ALLOWED_IPS}
PersistentKeepalive = 25
EOF
  chmod 0600 /etc/wireguard/wg0.conf
  cat >/etc/systemd/system/vcluster-poc-wireguard-forwarding.service <<EOF
[Unit]
Description=vCluster PoC WireGuard to CNI forwarding rules
After=wg-quick@wg0.service containerd.service
Wants=wg-quick@wg0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -C FORWARD -i wg0 -o cni0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i wg0 -o cni0 -j ACCEPT; iptables -C FORWARD -i cni0 -o wg0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i cni0 -o wg0 -j ACCEPT; iptables -C INPUT -s ${CLUSTER_CIDR} -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -s ${CLUSTER_CIDR} -j ACCEPT'
ExecStop=/bin/sh -c 'iptables -D FORWARD -i wg0 -o cni0 -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i cni0 -o wg0 -j ACCEPT 2>/dev/null || true; iptables -D INPUT -s ${CLUSTER_CIDR} -j ACCEPT 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
}

main() {
  install_os_packages
  install_bundle
  require_cmd kubeadm
  require_cmd kubelet
  require_cmd kubectl
  require_cmd containerd
  require_cmd kube-proxy
  require_cmd proxy-agent

  swapoff -a || true
  write_kernel_networking
  write_containerd
  write_kubelet
  join_node
  pod_cidr="$(wait_for_pod_cidr)"
  write_cni "$pod_cidr"
  systemctl restart kubelet
  write_kube_proxy
  write_konnectivity
  write_wireguard

  systemctl daemon-reload
  systemctl enable --now kubelet kube-proxy konnectivity-agent
  if [[ "$WG_ENABLE" == "true" ]]; then
    systemctl enable --now wg-quick@wg0 vcluster-poc-wireguard-forwarding.service
  fi

  echo "Bootstrap complete for ${NODE_NAME}; check node Ready status from the vCluster kubeconfig."
}

main "$@"
