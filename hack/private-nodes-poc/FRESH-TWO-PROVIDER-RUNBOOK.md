# Fresh two-provider reproduction runbook

This runbook is the repo-local procedure for reproducing the Private Nodes PoC
from scratch with fresh external VMs. It intentionally uses placeholders instead
of project names, cluster names, domains, resource IDs, IP addresses, tokens,
kubeconfigs, SSH private keys, WireGuard private keys, generated passwords, or
cloud credentials.

The fresh proof used one VM from each of two providers. The node bootstrap steps
apply to any Ubuntu/Debian systemd VM with public egress and inbound WireGuard
between peers.

## 0. Inputs and tools

Required local tools:

- `kubectl`
- `helm`
- `vcluster`
- `docker`
- `ssh`, `scp`, `ssh-keygen`
- cloud CLIs for the providers you use

Choose these values before starting:

```bash
export VCLUSTER_NAME='private-nodes-poc'
export VCLUSTER_NAMESPACE='private-nodes-poc'
export HOST_CONTEXT='<host-cluster-context>'
export VCLUSTER_ENDPOINT='<vcluster-api-host>:443'
```

`values/private-nodes-poc.yaml.tmpl` adds an
`external-dns.alpha.kubernetes.io/hostname` annotation to the vCluster
LoadBalancer Service. If your host cluster does not run external-dns for Service
records, create DNS for the LoadBalancer IP yourself and use that host in
`VCLUSTER_ENDPOINT`.

## 1. Create fresh VMs

Create an operator SSH key outside the repo:

```bash
ssh-keygen -t ed25519 -f /tmp/private-nodes-poc_ed25519 -C private-nodes-poc
```

Render cloud-init from the repo template. Do not hand-edit the template in
place; the helper fails if the SSH key placeholder is left behind.

```bash
PUBLIC_KEY_FILE=/tmp/private-nodes-poc_ed25519.pub \
  OUT=/tmp/private-nodes-cloud-init.yaml \
  ./scripts/render-cloud-init.sh
```

### Provider A / OpenStack-style example

Adjust image/flavor/network names for your project.

```bash
openstack --os-cloud <openstack-cloud-name> keypair create \
  --public-key /tmp/private-nodes-poc_ed25519.pub \
  private-nodes-poc

openstack --os-cloud <openstack-cloud-name> server create \
  --image '<ubuntu-24.04-image-name-or-id>' \
  --flavor '<small-cpu-flavor>' \
  --key-name private-nodes-poc \
  --network '<public-or-routed-network>' \
  --security-group '<security-group-allowing-ssh-and-wireguard>' \
  --user-data /tmp/private-nodes-cloud-init.yaml \
  --wait \
  private-nodes-poc-node-a
```

Record the VM ID and public IPv4. Do not copy or store any generated admin
password from cloud output.

### Provider B / Nebius-style example

Adjust project, profile, network, image family, platform, and preset for your
account. The example shows a disk created from a public Ubuntu image family and
then attached as the instance boot disk.

```bash
nebius compute disk create \
  --profile <nebius-profile> \
  --parent-id <nebius-project-id> \
  --name private-nodes-poc-node-b-disk \
  --type network_ssd \
  --size-gibibytes 20 \
  --source-image-family-parent-id <public-images-project-id> \
  --source-image-family-image-family <ubuntu-24.04-image-family> \
  --labels purpose=private-nodes-poc \
  --format json

nebius compute instance create \
  --profile <nebius-profile> \
  --parent-id <nebius-project-id> \
  --name private-nodes-poc-node-b \
  --hostname private-nodes-poc-node-b \
  --resources-platform <cpu-platform> \
  --resources-preset <small-cpu-preset> \
  --boot-disk-existing-disk-id '<disk-id-from-previous-command>' \
  --boot-disk-attach-mode read_write \
  --network-interfaces '[{"name":"eth0","ip_address":{},"public_ip_address":{"static":false},"subnet_id":"<subnet-id>"}]' \
  --cloud-init-user-data "$(cat /tmp/private-nodes-cloud-init.yaml)" \
  --labels purpose=private-nodes-poc \
  --format json
```

Record the instance ID, disk ID, public IP, and private IP.

## 2. Install the vCluster control plane

From this directory:

```bash
export VCLUSTER_NAME VCLUSTER_NAMESPACE HOST_CONTEXT VCLUSTER_ENDPOINT
./scripts/install-private-nodes-poc.sh
```

The install script waits for the LoadBalancer and endpoint DNS, then restarts
the control-plane Pod once. That restart is required for this PoC because the
virtual `default/kubernetes` Endpoints are written at control-plane startup from
the public endpoint.

Create a virtual-cluster kubeconfig:

```bash
vcluster connect "$VCLUSTER_NAME" \
  --namespace "$VCLUSTER_NAMESPACE" \
  --context "$HOST_CONTEXT" \
  --print > /tmp/private-nodes-poc.kubeconfig
chmod 0600 /tmp/private-nodes-poc.kubeconfig
```

Verify the vCluster API works:

```bash
KUBECONFIG=/tmp/private-nodes-poc.kubeconfig kubectl get ns
```

## 3. Build and copy the node binary bundle

Build the reusable binary payload:

```bash
./scripts/build-node-bundle.sh
```

Copy the bundle and bootstrap script to each VM:

```bash
scp -i /tmp/private-nodes-poc_ed25519 \
  dist/vcluster-node-bundle-v1.35.0.tgz \
  scripts/bootstrap-private-node.sh \
  ubuntu@<vm-public-ip>:/tmp/
```

## 4. Mint per-node credentials

Run once per node against the virtual-cluster kubeconfig:

```bash
export KUBECONFIG=/tmp/private-nodes-poc.kubeconfig
export VCLUSTER_ENDPOINT='<vcluster-api-host>:443'

export NODE_NAME='node-a'
export OUT=/tmp/node-a.env
./scripts/mint-node-secrets.sh

export NODE_NAME='node-b'
export OUT=/tmp/node-b.env
./scripts/mint-node-secrets.sh
```

Edit each private env file and add the non-secret node settings:

```bash
NODE_IP='<node-advertise-ip>'
NODE_BUNDLE='/root/vcluster-node-bundle-v1.35.0.tgz'
KONNECTIVITY_AGENT_IDENTIFIERS='host=<node-name>&ipv4=<node-advertise-ip>'
```

For a node whose reachable kubelet address is a public /32, include the `cidr`
identifier:

```bash
KONNECTIVITY_AGENT_IDENTIFIERS='host=<node-name>&ipv4=<public-ip>&cidr=<public-ip>/32'
```

Keep these env files mode `0600`; they contain tokens.

## 5. Bootstrap each node

Copy each private env file to its VM, then install and run the bootstrap script:

```bash
scp -i /tmp/private-nodes-poc_ed25519 /tmp/<node>.env ubuntu@<vm-public-ip>:/tmp/private-node.env

ssh -i /tmp/private-nodes-poc_ed25519 ubuntu@<vm-public-ip> '
  sudo install -m 0700 /tmp/bootstrap-private-node.sh /root/bootstrap-private-node.sh
  sudo install -m 0644 /tmp/vcluster-node-bundle-v1.35.0.tgz /root/vcluster-node-bundle-v1.35.0.tgz
  sudo install -m 0600 /tmp/private-node.env /root/private-node.env
  sudo /root/bootstrap-private-node.sh /root/private-node.env
'
```

Wait for both nodes and record their PodCIDRs:

```bash
KUBECONFIG=/tmp/private-nodes-poc.kubeconfig kubectl get nodes -o wide
KUBECONFIG=/tmp/private-nodes-poc.kubeconfig kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
```

## 6. Configure WireGuard after PodCIDRs are known

On each VM, generate a WireGuard keypair without printing the private key:

```bash
sudo install -d -m 0700 /root/wireguard
sudo sh -c 'umask 077; wg genkey | tee /root/wireguard/private.key | wg pubkey > /root/wireguard/public.key'
sudo cat /root/wireguard/public.key
```

Create one private WireGuard env file per VM from
`scripts/wireguard-node.env.example`. Include the peer WG IP and the peer
PodCIDR in `WG_ALLOWED_IPS`:

- node A: `WG_ADDRESS=10.250.0.1/30`, `WG_ALLOWED_IPS=10.250.0.2/32,<node-b-pod-cidr>`
- node B: `WG_ADDRESS=10.250.0.2/30`, `WG_ALLOWED_IPS=10.250.0.1/32,<node-a-pod-cidr>`

Copy and run the helper on each VM:

```bash
scp -i /tmp/private-nodes-poc_ed25519 \
  scripts/configure-wireguard.sh /tmp/<node>-wireguard.env \
  ubuntu@<vm-public-ip>:/tmp/

ssh -i /tmp/private-nodes-poc_ed25519 ubuntu@<vm-public-ip> '
  sudo install -m 0700 /tmp/configure-wireguard.sh /root/configure-wireguard.sh
  sudo install -m 0600 /tmp/<node>-wireguard.env /root/wireguard-node.env
  sudo /root/configure-wireguard.sh /root/wireguard-node.env
'
```

The helper persists the required network settings:

- `net.ipv4.ip_forward=1`
- `net.bridge.bridge-nf-call-iptables=1`
- `net.bridge.bridge-nf-call-ip6tables=1`
- forwarding rules for `wg0` <-> `cni0`

## 7. Validate

Create smoke pods on both nodes and expose them:

```bash
export KUBECONFIG=/tmp/private-nodes-poc.kubeconfig

kubectl run node-a-smoke --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"nodeName":"node-a","containers":[{"name":"bb","image":"busybox:1.36","command":["sh","-c","mkdir -p /www; echo served-from-node-a >/www/index.html; echo node-a-smoke-started; httpd -f -p 8080 -h /www"]}]}}'

kubectl run node-b-smoke --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"nodeName":"node-b","containers":[{"name":"bb","image":"busybox:1.36","command":["sh","-c","mkdir -p /www; echo served-from-node-b >/www/index.html; echo node-b-smoke-started; httpd -f -p 8080 -h /www"]}]}}'

kubectl wait --for=condition=Ready pod/node-a-smoke pod/node-b-smoke --timeout=120s
kubectl expose pod node-a-smoke --port 8080 --target-port 8080
kubectl expose pod node-b-smoke --port 8080 --target-port 8080
```

Run the checks:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl logs node-a-smoke
kubectl logs node-b-smoke

for pod in node-a-smoke node-b-smoke; do
  kubectl exec "$pod" -- nslookup -type=A kubernetes.default.svc.cluster.local
  kubectl exec "$pod" -- nslookup -type=A node-a-smoke.default.svc.cluster.local
  kubectl exec "$pod" -- nslookup -type=A node-b-smoke.default.svc.cluster.local
  kubectl exec "$pod" -- wget -qO- --timeout=5 http://node-a-smoke.default.svc.cluster.local:8080
  kubectl exec "$pod" -- wget -qO- --timeout=5 http://node-b-smoke.default.svc.cluster.local:8080
done
```

Validate port-forward through Konnectivity:

```bash
kubectl port-forward pod/node-a-smoke 18080:8080
curl http://127.0.0.1:18080
```

Expected result: both nodes are `Ready`; logs, exec, DNS, direct Pod IP traffic,
ClusterIP Service traffic, and port-forward all work.

## 8. Cleanup

Do not clean up shared/reference resources without explicit approval. For fresh
test resources, record all VM, disk, keypair, security group, and DNS resources
before deleting them.
