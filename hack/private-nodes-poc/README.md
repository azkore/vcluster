# Bootstrap reproducibility plan

This is the repo-local, durable procedure for making the vCluster Private Nodes
PoC recreatable without depending on the old reference VMs. For a full
start-to-finish run, including fresh VM provisioning examples, use
`FRESH-TWO-PROVIDER-RUNBOOK.md`.

## Durable artifacts

- `values/private-nodes-poc.yaml.tmpl` - Helm values for the patched OSS
  vCluster control plane image and Private Nodes mode.
- `scripts/install-private-nodes-poc.sh` - renders the values template and
  installs/upgrades the vCluster release from this fork's `chart/` directory.
- `scripts/build-node-bundle.sh` - builds a tarball containing kubeadm,
  kubelet, kubectl, containerd, CNI plugins, kube-proxy, and proxy-agent from
  the same images used in the manual PoC.
- `scripts/mint-node-secrets.sh` - creates one short-lived kubeadm bootstrap
  token and short-lived ServiceAccount tokens, then writes them to a `0600`
  env file. It prints the file path only, not token values.
- `scripts/bootstrap-private-node.sh` - runs on a fresh external VM and installs
  the binary bundle, joins the vCluster, and configures bridge CNI, kube-proxy,
  and Konnectivity.
- `scripts/configure-wireguard.sh` - configures WireGuard pod-CIDR routing on an
  already joined node after both node PodCIDRs and peer public keys are known.
- `scripts/private-node.env.example` - redacted per-node config shape.
- `scripts/wireguard-node.env.example` - redacted WireGuard config shape for the
  post-join helper.
- `scripts/cloud-init.example.yaml` - minimal cloud-init user-data shape for
  fresh Ubuntu nodes.
- `scripts/render-cloud-init.sh` - injects an operator SSH public key into the
  cloud-init template and fails if the placeholder is left behind.
- `FRESH-TWO-PROVIDER-RUNBOOK.md` - complete repo-local reproduction flow:
  provider VM examples, control plane install, node bootstrap, WireGuard, and
  validation.

Do not store generated token env files, WireGuard private keys, kubeconfigs, or
provider credentials in this directory.

## Control plane recreate

Pick a stable public endpoint for the vCluster before installing. Use a DNS name
or load balancer IP that external nodes can reach:

```bash
export VCLUSTER_ENDPOINT='<vcluster-api-host>:443'
export VCLUSTER_NAME='private-nodes-poc'
export VCLUSTER_NAMESPACE='private-nodes-poc'
export HOST_CONTEXT='<host-cluster-context>'
./scripts/install-private-nodes-poc.sh
```

The rendered values expose both `443` for Kubernetes API traffic and `8091` for
Konnectivity agent traffic on the LoadBalancer Service. The install script waits
for the LoadBalancer and endpoint DNS to become usable, then restarts the
control-plane Pod once so the PoC can create the virtual `default/kubernetes`
Endpoints from the now-resolvable public endpoint.

After install, create a virtual-cluster kubeconfig with `vcluster connect` or an
equivalent kubeconfig workflow, then use that kubeconfig for token minting and
validation.

## Build node bundle

Run on an operator machine with Docker access:

```bash
./scripts/build-node-bundle.sh
```

Copy `dist/vcluster-node-bundle-v1.35.0.tgz` and
`scripts/bootstrap-private-node.sh` to the fresh VM, or make the bundle
available at a temporary URL and set `NODE_BUNDLE_URL` in the node config.

## Mint short-lived node credentials

Run against the virtual-cluster kubeconfig, not the host cluster kubeconfig:

```bash
export KUBECONFIG=/path/to/private-nodes-poc.kubeconfig
export NODE_NAME='node-a'
export VCLUSTER_ENDPOINT='<vcluster-api-host>:443'
./scripts/mint-node-secrets.sh
```

The script writes `/tmp/vcluster-private-node-${NODE_NAME}.env` by default.
Copy the values into a private per-node config on the target VM, along with the
non-secret node-specific settings (`NODE_IP` and `NODE_BUNDLE` or
`NODE_BUNDLE_URL`). Keep that file mode `0600`. Delete the generated bootstrap
token after successful use if it is no longer needed.

## Bootstrap a fresh VM

On each VM:

```bash
sudo install -m 0700 bootstrap-private-node.sh /root/bootstrap-private-node.sh
sudo install -m 0600 private-node.env /root/private-node.env
sudo /root/bootstrap-private-node.sh /root/private-node.env
```

For a two-provider demo, run the script on both VMs first, then read the assigned
PodCIDRs from the vCluster. Configure WireGuard with opposite peer settings and
include the peer PodCIDR in `WG_ALLOWED_IPS`, matching the old pattern:

- node A: `WG_ADDRESS=10.250.0.1/30`, allowed IPs include node B's PodCIDR
- node B: `WG_ADDRESS=10.250.0.2/30`, allowed IPs include node A's PodCIDR

Copy `scripts/configure-wireguard.sh` to each VM, create a private
`/root/wireguard-node.env` containing the WireGuard fields, then run this on
each VM:

```bash
sudo install -m 0700 configure-wireguard.sh /root/configure-wireguard.sh
sudo /root/configure-wireguard.sh /root/wireguard-node.env
```

The WireGuard helper lets `wg-quick` install routes from `AllowedIPs`, enables
IPv4 forwarding, enables bridge netfilter for kube-proxy service NAT, and
persists the `wg0`/`cni0` forwarding rules used during the manual PoC.

## Validation checklist

From the virtual-cluster kubeconfig:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
kubectl run node-a-smoke --image=busybox:1.36 --restart=Never --overrides='{"spec":{"nodeName":"node-a","containers":[{"name":"bb","image":"busybox:1.36","command":["sh","-c","sleep 3600"]}]}}'
kubectl run node-b-smoke --image=busybox:1.36 --restart=Never --overrides='{"spec":{"nodeName":"node-b","containers":[{"name":"bb","image":"busybox:1.36","command":["sh","-c","sleep 3600"]}]}}'
kubectl get pods -o wide
kubectl exec node-a-smoke -- nslookup kubernetes.default.svc.cluster.local
kubectl logs node-a-smoke
kubectl port-forward pod/node-a-smoke 18080:8080
```

Add simple HTTP pods/services on each provider node and repeat the old
cross-service `wget` checks to prove Service and PodCIDR traffic both ways.

## Fresh proof status

- A fresh two-provider repro passed on 2026-05-21 with one VM from each of two
  providers joined to a recreated vCluster.
- Verified: both nodes `Ready`, pinned Pods on both providers, DNS from both
  Pods, direct Pod IP traffic both ways, ClusterIP Service traffic both ways,
  `kubectl logs`, `kubectl exec`, and `kubectl port-forward`.

## Current caveats

- `configure-wireguard.sh` is the durable version of the post-join WireGuard
  steps proven manually during the fresh repro.
- `bootstrap-private-node.sh` targets Ubuntu/Debian-like hosts with systemd.
- The control-plane endpoint still needs an externally reachable DNS name or LB
  IP before fresh nodes can join. The install script waits for this and restarts
  the control plane once, because this PoC writes the virtual Kubernetes
  Endpoints during control-plane startup.
- Generated token env files and WireGuard private keys are intentionally not
  durable artifacts.
