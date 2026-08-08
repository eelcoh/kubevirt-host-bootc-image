# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A family of [bootc](https://containers.github.io/bootc/) (bootable container) OS images, all built from a common `base` image and layered from there into more specialized flavors:

- **base** — plain Fedora bootc + KVM/libvirt (hardware virtualization) + a couple of generic bootc/ostree fixes. No desktop, no Kubernetes.
- **kubevirt** — base + K3s (Kubernetes control plane) + KubeVirt (VM workloads). Turns the host into a single-box KubeVirt appliance.
- **desktops/niri**, **desktops/sway**, **desktops/cosmic** — base + one desktop environment each, no Kubernetes. Niri+DankMaterialShell, Sway, and COSMIC respectively.
- **niri-kubevirt** — kubevirt + the niri desktop layered on top. The original single-image goal of this repo, now expressed as kubevirt + niri composed together.

There is no application code — the entire project is the image definitions plus the CI pipeline that builds and publishes each of them.

## Repository layout

```
base/Containerfile                   # shared by everything below
kubevirt/Containerfile               # FROM base
desktops/niri/Containerfile          # FROM base
desktops/sway/Containerfile          # FROM base
desktops/cosmic/Containerfile        # FROM base
niri-kubevirt/Containerfile          # FROM kubevirt
.github/workflows/build-image.yml    # reusable workflow: builds+pushes one flavor
.github/workflows/build-images.yml   # orchestrator: 6 jobs, one per flavor, in dependency order
```

Every non-base Containerfile starts with:

```dockerfile
ARG BASE_IMAGE=ghcr.io/eelcoh/kubevirt-host-bootc-image/<parent-flavor>:latest
FROM ${BASE_IMAGE}
```

so `podman build` works standalone against the published `:latest` parent by default, while CI overrides `BASE_IMAGE` to pin each flavor to the parent image built earlier in the *same* workflow run (see below) rather than a possibly-stale `latest`.

`base/Containerfile` itself is `FROM quay.io/fedora/fedora-bootc:44`, with alternate bases commented above it (the zirconium base used by an earlier iteration, and Fedora Hummingbird's `bootc-os` which was evaluated and rejected — see the comment block at the top of `base/Containerfile` for why). Switching the base is a one-line edit; keep the alternatives commented for reference unless asked to remove them.

## Why fedora-bootc, not zirconium

An earlier iteration of this image was `FROM ghcr.io/zirconium-dev/zirconium:latest`, which already shipped a full Niri/DMS desktop. That was rebuilt from scratch on plain `quay.io/fedora/fedora-bootc:44` instead, because:

- fedora-bootc:44 is *already* minimal (541 packages, no desktop at all — verified directly by pulling and inspecting it, not assumed from docs). It's the same base Silverblue/Kinoite build their desktops on top of, so there was nothing to strip down; every desktop/virt package is added explicitly in these Containerfiles instead of inherited from an opinionated spin.
- It ships standard Fedora repos, so `dnf install` for anything (KVM stack, niri, sway, COSMIC, DankMaterialShell) resolves normally against the full Fedora package set — no COPRs or third-party repos needed for any of it (verified directly against the live Fedora 44 repos for every package used across every flavor).
- Fedora Hummingbird's `bootc-os` (`quay.io/hummingbird-community/bootc-os`) was also tried as an even-smaller base and rejected: it only has 266 packages from its own curated repo (no qemu-kvm/libvirt/niri available at all), and layering Fedora Rawhide on top to fill the gap currently fails outright on an OpenSSL 3.5-vs-4.0 conflict between Hummingbird's pinned build and Rawhide. It's explicitly labeled "experimental," not intended as a general extensible base.
- A useful side effect: fedora-bootc's `/usr/local` is a real directory (per bootc's own upstream guidance for base images), unlike zirconium's ostree-standard symlink to `/var/usrlocal` — which doesn't exist at build time and broke installing K3s/virtctl there. No `INSTALL_K3S_BIN_DIR` workaround is needed on this base.

## base/Containerfile

Numbered steps, preserve the numbering when editing:

1. `systemctl set-default multi-user.target` — boot to console, not graphical. Desktop flavors bring the desktop up on demand with `systemctl start graphical.target` (or `set-default graphical.target` to make it stick).
2. Install KVM/virt packages via `dnf` (`qemu-kvm`, `libvirt`, `virt-install`, `iscsi-initiator-utils`, etc.) — lives in `base`, not just `kubevirt`, so every flavor gets host virtualization capability for free.
3. Mask `systemd-remount-fs.service`. On this composefs-based root, `/` is an overlayfs mount, and this unit fails every boot trying to reconfigure it (`fsconfig() failed: overlay: No changes allowed in reconfigure`) — a known upstream issue on ostree/bootc composefs roots in general (`fedora-silverblue/issue-tracker#605`, `bootc-dev/bootc#971`), not specific to any one flavor. The unit is `static` (no `[Install]` section), so `systemctl disable` can't touch it — masking is the only way to stop it running. Also enables `sshd.service` (already on by default on this base; kept explicit for clarity).

SELinux is deliberately left at Fedora's default `enforcing` in `base` — libvirt/qemu-kvm work fine under the targeted policy. Only `kubevirt` (whose K3s CNI and KubeVirt's device plugin need more than targeted allows) flips it to `permissive`.

## kubevirt/Containerfile

`FROM` base, numbered steps continue the same convention:

1. Flip `/etc/selinux/config` to `SELINUX=permissive` at build time (a persisted single source of truth, not a per-boot `setenforce`).
2. Install K3s straight into the image via `curl https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true sh -s - server ...` (`--disable=traefik --disable=servicelb --write-kubeconfig-mode=644`), so the binary + systemd unit are baked in and first boot needs no network. `INSTALL_K3S_SKIP_START=true` avoids trying to actually start the service during the container build. `INSTALL_K3S_SKIP_ENABLE=true` skips the installer's own `systemctl enable`/`daemon-reload` — the latter needs a live systemd bus that doesn't exist during a container build and fails hard (unlike plain `systemctl enable`, which works offline); step 5 enables `k3s.service` itself once the unit file already exists. Also drops `/etc/profile.d/k3s-kubeconfig.sh` so any shell has `KUBECONFIG` set without the user exporting it manually.
3. Fetch the current stable KubeVirt release tag, install `virtctl` to `/usr/local/bin`, and write that resolved version to `/etc/kubevirt-version` — the single source of truth step 4 reads from, so the manifests deployed at first boot always match the `virtctl` baked into the image.
4. Heredoc-inject `/usr/local/bin/bootstrap-kubevirt.sh`, a first-boot script that waits for the (already-running, systemd-managed) K3s API to come up, then applies the KubeVirt operator + CR from `/etc/kubevirt-version` if the `kubevirt` namespace doesn't already exist. Also injects the `kubevirt-bootstrap.service` systemd oneshot unit (`After=`/`Requires=k3s.service`) that runs it.
5. `systemctl enable k3s.service kubevirt-bootstrap.service`.

Version pinning is intentionally build-time-only: nothing at runtime scrapes GitHub/DNS for "latest" — `/etc/kubevirt-version` (baked in step 3) is the only thing step 4's script trusts, so a given built image always deploys a consistent, known KubeVirt version regardless of what's "latest" by the time it boots.

## Desktop flavors (desktops/niri, desktops/sway, desktops/cosmic)

Each is `FROM` base, self-contained, no Kubernetes:

- **niri** — Niri (scrollable-tiling Wayland compositor) + DankMaterialShell (DMS, a Quickshell-based shell replacing the usual bar/launcher/lock/notification-daemon pile). DankMaterialShell ships its own greetd-native greeter, but Fedora doesn't package a `dms-greeter` RPM the way some other distros do — this Containerfile replicates DMS upstream's own documented manual-install fallback: create a `greeter` system user, seed its cache dir per DMS's own tmpfiles rule, install the `dms-greeter` wrapper, and point `/etc/greetd/config.toml` at it. DMS's own `dms.service` (systemd `--user`, `WantedBy=graphical-session.target`) is enabled globally (`systemctl --global enable`) so every user account gets it without a per-user step.
- **sway** — Sway (i3-compatible wlroots compositor) + waybar (status bar; sway has none built in) + swaybg/swaylock/swayidle + `xdg-desktop-portal-wlr` (sway is genuinely wlroots-based, unlike niri, so this is the correct screen-capture portal backend here) + greetd/tuigreet. Simpler wiring than niri: Fedora's `greetd` RPM already ships a `sysusers.d` entry creating a `greetd` system user, so `/etc/greetd/config.toml` just points `tuigreet --cmd sway` at that existing account — no manual `useradd` needed.
- **cosmic** — `dnf group install cosmic-desktop` (Fedora ships a full spin-quality comps group for COSMIC, unlike niri/sway which are assembled package-by-package) + `cosmic-greeter`. Simplest of the three: `cosmic-greeter`'s RPM ships its own `sysusers.d`, `tmpfiles.d`, and a ready-made `/etc/greetd/cosmic-greeter.toml` — COSMIC's greeter is greetd-based under the hood. No manual wiring at all beyond `systemctl enable cosmic-greeter.service`.

All three: `alacritty` as the terminal (niri/sway; matches niri's default `Mod+T` keybind), `gnome-keyring` + `polkit-kde` (a ~300KB standalone polkit agent, not KDE/Plasma), and the PipeWire audio stack. All plain Fedora 44 packages, no COPR — verified directly against the live Fedora 44 repos, same practice as everything else in this repo.

Every desktop's login front-end (`greetd`, `cosmic-greeter`) aliases `display-manager.service`, which `graphical.target` already `Wants=` — so `systemctl enable <front-end>.service` is sufficient to wire it up; nothing else needs to reference `display-manager.service` directly.

## niri-kubevirt/Containerfile

`FROM` the `kubevirt` image (not the reverse — desktop is layered on top of the Kubernetes appliance, not the other way around). Intentionally duplicates `desktops/niri/Containerfile`'s desktop steps verbatim rather than sharing them through an include mechanism, matching this repo's convention of self-contained, heredoc-style Containerfiles with no cross-file includes anywhere else in the project. **If the niri desktop steps change, update both files together.**

## CI (.github/workflows/)

`build-image.yml` is a reusable workflow (`workflow_call`) that builds and pushes exactly one flavor: given `flavor` (image path suffix), `containerfile` (path), and optional `build_args`, it computes a short SHA, builds with buildx, and pushes `ghcr.io/<repo>/<flavor>:latest` and `:sha-<short>` — tags and cache (`type=gha`, scoped per flavor so the six builds don't clobber each other's cache) all live here.

`build-images.yml` is the orchestrator: same triggers as before (push to `main` touching `base/**`, `kubevirt/**`, `desktops/**`, `niri-kubevirt/**`, or the workflows themselves; weekly Sunday cron for security updates; manual `workflow_dispatch`). It calls `build-image.yml` once per flavor with `needs:` encoding the dependency DAG:

```
base ──┬─→ kubevirt ─→ niri-kubevirt
       ├─→ desktops/sway
       ├─→ desktops/cosmic
       └─→ desktops/niri
```

Every job runs on every trigger — no per-flavor path filtering — so a downstream flavor is never built against a stale published parent. Each dependent job pins its `BASE_IMAGE` build-arg to the exact `sha-<short>` tag its parent job just pushed in the same run (via that job's `short_sha` output), not `:latest`, to avoid a race against a concurrent workflow run.

This is the source of truth for how the images are built and published; mirror any local build flags/context changes here.

## Working with this repo

- There is no build/lint/test tooling in-repo beyond the Containerfiles themselves. To validate a change, build the relevant image locally, e.g.:
  ```sh
  podman build -f base/Containerfile -t local/base:dev .
  podman build -f kubevirt/Containerfile --build-arg BASE_IMAGE=local/base:dev -t local/kubevirt:dev .
  podman build -f desktops/niri/Containerfile --build-arg BASE_IMAGE=local/base:dev -t local/niri:dev .
  ```
  bootc images require a container runtime capable of building OCI images; there's no Kubernetes/VM available to test the first-boot bootstrap script or greeter flows short of actually booting the image.
- When evaluating a new base image or an unfamiliar package, prefer pulling and inspecting it directly (`podman run --rm <image> sh -c '...'`, `rpm -qa`, `dnf5 info`/`search`/`download`, `ls`/`readlink -f` on suspect paths like `/usr/local`, `rpm -qlp`/`rpm -qp --scripts` on a downloaded RPM to see what it actually ships/wires up) over trusting documentation or search results — several past issues here (the `/usr/local` → `/var/usrlocal` symlink breaking K3s installs, Hummingbird's OpenSSL version conflict, which system user each greeter front-end actually creates) were only caught this way, and docs/search results were stale or vague on exactly these points.
- CI (`build-images.yml` + `build-image.yml`) is the source of truth for how the images are built and published; mirror any local build flags/context changes there.
- Multi-line heredoc `COPY <<-'EOF' ... EOF` blocks in the Containerfiles inject files directly — edit the heredoc body in place rather than switching to separate files unless there's a reason to.
