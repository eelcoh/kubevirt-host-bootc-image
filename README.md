# kubevirt-host-bootc-image

A [bootc](https://containers.github.io/bootc/) (bootable container) image that
turns a bare-metal or VM host into a single-box KubeVirt appliance: K3s as the
Kubernetes control plane, KubeVirt for running VMs, KVM/libvirt for hardware
virtualization, and a [Niri](https://github.com/niri-wm/niri) +
[DankMaterialShell](https://danklinux.com/docs/dankmaterialshell/installation)
desktop available on demand (no GNOME/KDE). Everything is baked into the
image at build time — the box needs no network access on first boot to come
up with a working cluster, and SSH (`sshd.service`) is enabled out of the
box.

See [`CLAUDE.md`](CLAUDE.md) for how the `Containerfile` itself is organized.
This document is about *using* the appliance once it's installed.

Published image: `ghcr.io/eelcoh/kubevirt-host-bootc-image:latest`

## Prerequisites

- A CPU with hardware virtualization (Intel VT-x / AMD-V) and `/dev/kvm`
  available — KubeVirt VMs run under emulation without it, which works but is
  very slow.
- For bare metal: BIOS/UEFI virtualization extensions enabled.

## Installing

### Onto an existing bootc/Fedora system

If the target machine is already running a bootc-based OS (e.g. plain
`fedora-bootc`), rebase it onto this image and reboot:

```sh
sudo bootc switch ghcr.io/eelcoh/kubevirt-host-bootc-image:latest
sudo systemctl reboot
```

### Fresh bare metal / VM

Note: Anaconda itself isn't part of the deployed appliance — it's not
installed at all in `quay.io/fedora/fedora-bootc:44` or anything layered on
top of it here. So "install with Anaconda" means building install *media*
that boots into Anaconda pointed at this image, not running a tool that's
already sitting on some pristine box. Two ways to do that:

**Unattended, graphical progress (recommended)** — build an installer ISO
with [`bootc-image-builder`](https://github.com/osbuild/bootc-image-builder).
This is itself an Anaconda-based ISO (osbuild wires up the kickstart for
you), just unattended by default — boot it and it partitions/installs this
image without prompting, showing normal Anaconda progress on screen:

```sh
sudo podman run --rm -it --privileged \
  --pull=newer \
  -v ./output:/output \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type iso \
  ghcr.io/eelcoh/kubevirt-host-bootc-image:latest
```

Swap `--type iso` for `--type qcow2` or `--type raw` if you want a disk
image instead of installer media. See the bootc-image-builder docs for the
full set of output types.

**Scripted, via kickstart on a stock Fedora Anaconda ISO** — no custom image
build needed; point any current Fedora Anaconda installer (netinst ISO, PXE,
etc.) at this image with a kickstart using the `bootc` command:

```
zerombr
clearpart --all --initlabel
autopart

lang en_US.UTF-8
keyboard us
timezone UTC --utc
rootpw --lock

bootc --source-imgref=registry:ghcr.io/eelcoh/kubevirt-host-bootc-image:latest
```

Host that kickstart somewhere reachable and boot the installer with
`inst.ks=http://.../kubevirt-host.ks` on the kernel command line (or embed it
in the ISO with `mkksiso`). This boots the normal Anaconda UI (graphical or
text) and installs straight from the registry — useful if you already have
PXE/kickstart infrastructure and don't want to build custom media per image
update. See the [Fedora Magazine writeup of the `bootc` kickstart
command](https://fedoramagazine.org/introducing-the-new-bootc-kickstart-command-in-anaconda/)
for details.

## First boot

On first boot, `k3s.service` starts immediately (no network required — the
binary is baked into the image), and `kubevirt-bootstrap.service` waits for
the K3s API to come up and then applies the KubeVirt operator + CR pinned in
`/etc/kubevirt-version`. Give it a minute or two, then check:

```sh
kubectl get nodes
kubectl get pods -n kubevirt
```

`KUBECONFIG` is already exported for every shell via
`/etc/profile.d/k3s-kubeconfig.sh`, so `kubectl`/`virtctl` work out of the box
for any user, console or terminal — no manual export needed.

The appliance boots to a console (`multi-user.target`) by default even though
the Niri/DankMaterialShell desktop (see below) is fully installed. Bring it
up on demand:

```sh
sudo systemctl start graphical.target      # this boot only
sudo systemctl set-default graphical.target  # persist across reboots
```

SSH is enabled by default (`sshd.service`), so the console/graphical choice
doesn't actually gate remote access — you can always `ssh` in regardless of
which target is active.

## Using the desktop

`graphical.target` brings up `greetd`, which shows DankMaterialShell's own
greeter (login screen) and hands off into a Niri session running DMS as the
shell — no GNOME/KDE anywhere in the stack. `alacritty` is installed as the
default terminal (matches niri's own default `Mod+T` keybind). Niri looks
for its config at `~/.config/niri/config.kdl`; if you don't have one yet,
start from niri's own documented default:

```sh
mkdir -p ~/.config/niri
cp /usr/share/doc/niri/default-config.kdl ~/.config/niri/config.kdl
```

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
journalctl -u greetd.service   # login screen / desktop not coming up
```

SELinux is set to `permissive` at build time (K3s's CNI and KubeVirt's device
plugin need more than the default targeted policy allows out of the box) —
this is a deliberate, persisted setting, not something to "fix" back to
enforcing without also sorting out the required policy.
