#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Configure WireGuard pod-CIDR routing for an already joined vCluster Private Node.

Run as root on the target VM. Pass a config file as the first argument or set
NODE_CONFIG. The config is a shell env file.

Required config:
  WG_ADDRESS           local WireGuard address, e.g. 10.250.0.1/30
  WG_PRIVATE_KEY       local WireGuard private key
  WG_PEER_PUBLIC_KEY   peer WireGuard public key
  WG_PEER_ENDPOINT     peer public endpoint, e.g. <peer-public-ip>:51820
  WG_ALLOWED_IPS       peer WG IP and peer PodCIDR, e.g. 10.250.0.2/32,10.244.0.0/24

Optional config:
  CLUSTER_CIDR         default 10.244.0.0/16
  WG_LISTEN_PORT       default 51820
  WG_MTU               default 1380

No secrets are printed. The WireGuard private key is written only to
/etc/wireguard/wg0.conf with mode 0600.
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

: "${WG_ADDRESS:?set WG_ADDRESS}"
: "${WG_PRIVATE_KEY:?set WG_PRIVATE_KEY}"
: "${WG_PEER_PUBLIC_KEY:?set WG_PEER_PUBLIC_KEY}"
: "${WG_PEER_ENDPOINT:?set WG_PEER_ENDPOINT}"
: "${WG_ALLOWED_IPS:?set WG_ALLOWED_IPS}"

CLUSTER_CIDR="${CLUSTER_CIDR:-10.244.0.0/16}"
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

install -d -m 0755 /etc/modules-load.d /etc/sysctl.d
cat >/etc/modules-load.d/vcluster-private-node.conf <<'EOF'
br_netfilter
EOF
modprobe br_netfilter || true
cat >/etc/sysctl.d/98-vcluster-bridge-netfilter.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
cat >/etc/sysctl.d/99-vcluster-private-node.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null

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

systemctl daemon-reload
systemctl enable --now wg-quick@wg0 vcluster-poc-wireguard-forwarding.service
echo "WireGuard pod-CIDR routing configured."
