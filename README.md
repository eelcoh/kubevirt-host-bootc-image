# kubevirt-host-bootc-image

A family of [bootc](https://containers.github.io/bootc/) (bootable container)
OS images, all built from one common `base` and layered from there into more
specialized flavors. Everything is baked into the image at build time — a
box needs no network access on first boot to come up working, and SSH
(`sshd.service`) is enabled out of the box on every flavor.

See [`CLAUDE.md`](CLAUDE.md) for how the Containerfiles themselves are
organized and how the CI pipeline builds/publishes them. This document is
about *using* the appliances once installed.

## Flavors

| Image | What it is |
|---|---|
| `ghcr.io/eelcoh/kubevirt-host-bootc-image/base` | Plain Fedora bootc + KVM/libvirt (hardware virtualization). No desktop, no Kubernetes. |
| `ghcr.io/eelcoh/kubevirt-host-bootc-image/kubevirt` | base + K3s (Kubernetes) + KubeVirt (VM workloads). The single-box KubeVirt appliance. |
| `ghcr.io/eelcoh/kubevirt-host-bootc-image/niri` | base + [Niri](https://github.com/niri-wm/niri) + [DankMaterialShell](https://danklinux.com/docs/dankmaterialshell/installation) desktop. No Kubernetes. |
| `ghcr.io/eelcoh/kubevirt-host-bootc-image/sway` | base + [Sway](https://swaywm.org/) desktop. No Kubernetes. |
| `ghcr.io/eelcoh/kubevirt-host-bootc-image/cosmic` | base + [COSMIC](https://system76.com/cosmic/) desktop. No Kubernetes. |
| `ghcr.io/eelcoh/kubevirt-host-bootc-image/niri-kubevirt` | kubevirt + the Niri/DMS desktop layered on top — the KubeVirt appliance *with* a desktop. |

Pick whichever image matches what you want the box to be; the install and
first-boot mechanics below are the same for all of them, just point them at
a different image reference.

## Prerequisites

- A CPU with hardware virtualization (Intel VT-x / AMD-V) and `/dev/kvm`
  available. Needed by every flavor (KVM/libvirt is in `base`); doubly so for
  `kubevirt`/`niri-kubevirt`, where KubeVirt VMs run under emulation without
  it, which works but is very slow.
- For bare metal: BIOS/UEFI virtualization extensions enabled.

## Installing

Replace `<image>` below with one of the flavor image references from the
table above (e.g. `ghcr.io/eelcoh/kubevirt-host-bootc-image/kubevirt:latest`).

### Onto an existing bootc/Fedora system

If the target machine is already running a bootc-based OS (e.g. plain
`fedora-bootc`), rebase it onto this image and reboot:

```sh
sudo bootc switch <image>
sudo systemctl reboot
```

This also works to move between flavors on a box you already installed (e.g.
`base` → `kubevirt` once you decide you want KubeVirt after all).

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
  <image>
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

bootc --source-imgref=registry:<image>
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

Every flavor boots to a console (`multi-user.target`) by default, even the
desktop ones (see below). SSH is enabled by default (`sshd.service`).

### kubevirt / niri-kubevirt

See [`kubevirt/README.md`](kubevirt/README.md) for K3s/KubeVirt first-boot
behavior, `kubectl`/`virtctl` usage, and deploying containers/VMs.

### Desktop flavors (niri, sway, cosmic, niri-kubevirt)

Bring the desktop up on demand:

```sh
sudo systemctl start graphical.target      # this boot only
sudo systemctl set-default graphical.target  # persist across reboots
```

SSH stays available regardless of which target is active — the
console/graphical choice doesn't gate remote access.

## Using the desktop

### niri / niri-kubevirt

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

### sway

`graphical.target` brings up `greetd`, which shows `tuigreet` (a console/TUI
login prompt) and hands off into a Sway session. `waybar` runs as the status
bar, and `alacritty` is the default terminal. Sway's stock config
(`sway-config-fedora`) is used as-is; customize at `~/.config/sway/config`.

### cosmic

`graphical.target` brings up `cosmic-greeter`, COSMIC's own native login
screen, straight into a COSMIC session — no manual greeter wiring involved,
it's fully self-configured out of the box.

## Kubernetes and KubeVirt

*(kubevirt / niri-kubevirt only.)* Deploying containers to K3s, running VMs
in KubeVirt, and the K3s/KubeVirt-specific troubleshooting/SELinux notes all
live in [`kubevirt/README.md`](kubevirt/README.md).

## Troubleshooting

```sh
journalctl -u greetd.service             # niri / sway / niri-kubevirt: login screen not coming up
journalctl -u cosmic-greeter.service     # cosmic: login screen not coming up
```

See [`kubevirt/README.md`](kubevirt/README.md#troubleshooting) for
K3s/KubeVirt troubleshooting and SELinux notes (kubevirt / niri-kubevirt
only — `base` and the other desktop flavors stay at Fedora's default
`enforcing`).
