# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single `Containerfile` that builds a [bootc](https://containers.github.io/bootc/) (bootable container) OS image turning a host into a single-box KubeVirt appliance: K3s as the Kubernetes control plane, KubeVirt for VM workloads, KVM/libvirt for hardware virtualization, and a Niri + DankMaterialShell (DMS) desktop available on demand (not GNOME/KDE). There is no application code — the entire project is the image definition plus the CI pipeline that builds and publishes it.

## Repository layout

- `Containerfile` — the image build. Currently `FROM quay.io/fedora/fedora-bootc:44`, with alternate bases commented above it (the zirconium base used by an earlier iteration, and Fedora Hummingbird's `bootc-os` which was evaluated and rejected — see the comment block at the top of the Containerfile for why). Switching the base is a one-line edit; keep the alternatives commented for reference unless asked to remove them.
- `.github/workflows/build-os.yml` — builds and pushes the image to `ghcr.io/<repo>` on every push to `main` that touches `Containerfile` or the workflow itself, on a weekly cron (Sunday 00:00, for security updates), and via manual `workflow_dispatch`. Tags: `latest` and short-sha.

## Why fedora-bootc, not zirconium

An earlier iteration of this image was `FROM ghcr.io/zirconium-dev/zirconium:latest`, which already shipped a full Niri/DMS desktop. That was rebuilt from scratch on plain `quay.io/fedora/fedora-bootc:44` instead, because:

- fedora-bootc:44 is *already* minimal (541 packages, no desktop at all — verified directly by pulling and inspecting it, not assumed from docs). It's the same base Silverblue/Kinoite build their desktops on top of, so there was nothing to strip down; every desktop package is added explicitly in this Containerfile instead of inherited from an opinionated spin.
- It ships standard Fedora repos, so `dnf install` for anything (KVM stack, niri, DankMaterialShell) resolves normally against the full Fedora package set — no COPRs or third-party repos needed for any of it (verified: niri, quickshell, and DankMaterialShell are all plain `fedora`/`updates` packages on Fedora 44).
- Fedora Hummingbird's `bootc-os` (`quay.io/hummingbird-community/bootc-os`) was also tried as an even-smaller base and rejected: it only has 266 packages from its own curated repo (no qemu-kvm/libvirt/niri available at all), and layering Fedora Rawhide on top to fill the gap currently fails outright on an OpenSSL 3.5-vs-4.0 conflict between Hummingbird's pinned build and Rawhide. It's explicitly labeled "experimental," not intended as a general extensible base.
- A useful side effect: fedora-bootc's `/usr/local` is a real directory (per bootc's own upstream guidance for base images), unlike zirconium's ostree-standard symlink to `/var/usrlocal` — which doesn't exist at build time and broke installing K3s/virtctl there. No `INSTALL_K3S_BIN_DIR` workaround is needed on this base.

## Containerfile structure

Stages are organized as numbered comments (`# 1.`, `# 2.` …) — preserve this numbering when editing:

1. `systemctl set-default multi-user.target` — boot to console, not graphical. The desktop (step 8) is fully installed; switch to it with `systemctl start graphical.target` (or `set-default graphical.target` to make it stick).
2. Install KVM/virt packages via `dnf` (`qemu-kvm`, `libvirt`, `virt-install`, `iscsi-initiator-utils`, etc.)
3. Flip `/etc/selinux/config` to `SELINUX=permissive` at build time (K3s's CNI + KubeVirt's device plugin need more than the default targeted policy allows; this is a persisted single source of truth, not a per-boot `setenforce`).
4. Install K3s straight into the image via `curl https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true sh -s - server ...` (`--disable=traefik --disable=servicelb --write-kubeconfig-mode=644`), so the binary + systemd unit are baked in and first boot needs no network. `INSTALL_K3S_SKIP_START=true` avoids trying to actually start the service during the container build. `INSTALL_K3S_SKIP_ENABLE=true` skips the installer's own `systemctl enable`/`daemon-reload` — the latter needs a live systemd bus that doesn't exist during a container build and fails hard (unlike plain `systemctl enable`, which works offline); step 9 enables `k3s.service` itself once the unit file already exists. Also drops `/etc/profile.d/k3s-kubeconfig.sh` so any shell (console or a Niri terminal) has `KUBECONFIG` set without the user exporting it manually.
5. Fetch the current stable KubeVirt release tag, install `virtctl` to `/usr/local/bin`, and write that resolved version to `/etc/kubevirt-version` — the single source of truth step 6 reads from, so the manifests deployed at first boot always match the `virtctl` baked into the image.
6. Heredoc-inject `/usr/local/bin/bootstrap-kubevirt.sh`, a first-boot script that waits for the (already-running, systemd-managed) K3s API to come up, then applies the KubeVirt operator + CR from `/etc/kubevirt-version` if the `kubevirt` namespace doesn't already exist.
7. Heredoc-inject a systemd oneshot unit (`kubevirt-bootstrap.service`, `After=/Requires=k3s.service`) that runs step 6's script. Enabled in step 9.
8. Install the desktop: `niri` (scrollable-tiling Wayland compositor) + `DankMaterialShell`/`quickshell` (the shell — replaces the usual bar/launcher/lock/notification-daemon pile), plus `alacritty` (matches niri's default `Mod+T` keybind), portals (`xdg-desktop-portal-gtk`/`-gnome`, per niri's own upstream guidance), `gnome-keyring`, `polkit-kde` (a ~300KB standalone polkit agent, not KDE/Plasma itself), `greetd`, and the PipeWire audio stack. All plain Fedora 44 packages, no COPR.
9. Wire up login and enable everything. DankMaterialShell ships its own greetd-native greeter (`dms-greeter` script + niri/greetd templates under `/usr/share/quickshell/dms/Modules/Greetd/`), but Fedora doesn't package a separate `dms-greeter` RPM the way some other distros do — this step replicates DMS upstream's own documented manual-install fallback: create the `greeter` system user, seed `/var/cache/dms-greeter` and `/var/lib/greeter` with the ownership/mode DMS's own tmpfiles rule specifies, install the `dms-greeter` wrapper to `/usr/local/bin`, and point `/etc/greetd/config.toml` at it. For a normal (non-greeter) login, DMS ships a proper `dms.service` systemd `--user` unit (`WantedBy=graphical-session.target`, which niri's own session unit already reaches) — `systemctl --global enable dms.service` turns it on for every user account up front, no per-user step needed after first login. Finally enables `k3s.service`, `kubevirt-bootstrap.service`, `greetd.service`, and `sshd.service` (present and enabled by default on this base already; enabled explicitly here too for clarity).

Version pinning is intentionally build-time-only: nothing at runtime scrapes GitHub/DNS for "latest" — `/etc/kubevirt-version` (baked in step 5) is the only thing step 6 trusts, so a given built image always deploys a consistent, known KubeVirt version regardless of what's "latest" by the time it boots.

## Working with this repo

- There is no build/lint/test tooling in-repo. To validate a change, build the image locally with `podman build -f Containerfile .` (or `docker build`) — bootc images require a container runtime capable of building OCI images; there's no Kubernetes/VM available to test the first-boot bootstrap script itself short of actually booting the image.
- When evaluating a new base image or an unfamiliar package, prefer pulling and inspecting it directly (`podman run --rm <image> sh -c '...'`, `rpm -qa`, `dnf5 info`/`search`/`download`, `ls`/`readlink -f` on suspect paths like `/usr/local`) over trusting documentation or search results — several past issues here (the `/usr/local` → `/var/usrlocal` symlink breaking K3s installs, Hummingbird's OpenSSL version conflict) were only caught this way, and docs/search results were stale or vague on exactly these points.
- CI (`build-os.yml`) is the source of truth for how the image is built and published; mirror any local build flags/context changes there.
- Multi-line heredoc `COPY <<-'EOF' ... EOF` blocks in the Containerfile inject files directly — edit the heredoc body in place rather than switching to separate files unless there's a reason to.
