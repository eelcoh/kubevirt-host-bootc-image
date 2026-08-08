# Using Kubernetes (K3s) and KubeVirt

This covers the K3s/KubeVirt-specific parts of the `kubevirt` image, and
applies equally to `niri-kubevirt` (which is `kubevirt` with a desktop
layered on top — see [`../niri-kubevirt/Containerfile`](../niri-kubevirt/Containerfile)).
For install/first-boot basics common to every flavor, see the
[top-level README](../README.md).

## First boot

`k3s.service` starts immediately (no network required — the binary is baked
into the image), and `kubevirt-bootstrap.service` waits for the K3s API to
come up and then applies the KubeVirt operator + CR pinned in
`/etc/kubevirt-version`. Give it a minute or two, then check:

```sh
kubectl get nodes
kubectl get pods -n kubevirt
```

`KUBECONFIG` is already exported for every shell via
`/etc/profile.d/k3s-kubeconfig.sh`, so `kubectl`/`virtctl` work out of the box
for any user, console or terminal — no manual export needed.

## Deploying containers to K3s

This is a normal, single-node K3s cluster — anything that runs on Kubernetes
runs here. `traefik` and `servicelb` are disabled (no ingress/LB needed on a
single box), everything else is stock.

**From a public registry** — just reference the image, K3s pulls it like any
Kubernetes cluster would:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 1
  selector:
    matchLabels: {app: hello}
  template:
    metadata:
      labels: {app: hello}
    spec:
      containers:
        - name: hello
          image: ghcr.io/example/hello:latest
```

```sh
kubectl apply -f hello.yaml
```

**From a locally built image** (nothing pushed anywhere) — import it
straight into K3s's containerd, no registry round-trip needed:

```sh
podman build -t local/myapp:dev .
podman save local/myapp:dev | sudo k3s ctr images import -
```

Then reference `local/myapp:dev` in your manifest with
`imagePullPolicy: IfNotPresent` (or `Never`) so K3s doesn't try to pull it
from a registry.

## Running VMs in KubeVirt

KubeVirt VMs are defined as `VirtualMachine` resources; `virtctl` (baked into
`/usr/local/bin`, version pinned to match the deployed KubeVirt release) is the CLI
for lifecycle/console/VNC operations. Only the core KubeVirt operator+CR are
installed — not CDI (Containerized Data Importer) — so the straightforward
way to get a disk image into a VM here is via **containerDisk**: package the
qcow2 inside a container image and reference it directly, no separate import
step or registry-adjacent service required.

### Package a disk image as a containerDisk

```dockerfile
FROM scratch
COPY my-disk.qcow2 /disk/
```

```sh
podman build -t ghcr.io/you/my-vm-disk:latest -f Containerfile.disk .
podman push ghcr.io/you/my-vm-disk:latest
```

(For a locally built image, `podman save | sudo k3s ctr images import -`
works here too, same as any other container image.)

### Define and start the VM

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: my-vm
spec:
  running: false
  template:
    spec:
      domain:
        cpu: {cores: 2}
        resources:
          requests: {memory: 2Gi}
        devices:
          disks:
            - name: rootdisk
              disk: {bus: virtio}
            - name: cloudinitdisk
              disk: {bus: virtio}
      volumes:
        - name: rootdisk
          containerDisk:
            image: ghcr.io/you/my-vm-disk:latest
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: changeme
              chpasswd: {expire: false}
```

```sh
kubectl apply -f my-vm.yaml
virtctl start my-vm
virtctl console my-vm      # serial console
virtctl vnc my-vm          # graphical console (needs a local VNC viewer)
virtctl stop my-vm
```

`kubectl get vmis` shows running VM instances; `kubectl get vms` shows the
VM objects (which persist whether running or stopped).

> Want URL- or upload-based disk imports (`virtctl image-upload`, DataVolumes
> from a URL) instead of building containerDisk images by hand? That needs
> CDI installed separately — it isn't part of this image's bootstrap step.

## Troubleshooting

```sh
journalctl -u k3s.service
journalctl -u kubevirt-bootstrap.service
kubectl get pods -n kubevirt   # operator/virt-* components stuck/crashlooping
```

SELinux is set to `permissive` at build time on this flavor (K3s's CNI and
KubeVirt's device plugin need more than Fedora's default targeted policy
allows out of the box) — a deliberate, persisted setting, not something to
"fix" back to enforcing without also sorting out the required policy. Every
other flavor (`base`, `sway`, `cosmic`, plain `niri`) stays at Fedora's
default `enforcing`.
