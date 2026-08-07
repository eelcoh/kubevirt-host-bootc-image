# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single `Containerfile` that builds a [bootc](https://containers.github.io/bootc/) (bootable container) OS image turning a host into a single-box KubeVirt appliance: K3s as the Kubernetes control plane, KubeVirt for VM workloads, KVM/libvirt for hardware virtualization. There is no application code — the entire project is the image definition plus the CI pipeline that builds and publishes it.

## Repository layout

- `Containerfile` — the image build. Currently `FROM ghcr.io/zirconium-dev/zirconium:latest`, with alternate bases commented out above it (a private `zirconium-base` image and plain `quay.io/fedora/fedora-bootc:44`). Switching the base is a one-line edit; keep the alternatives commented for reference unless asked to remove them.
- `.github/workflows/build-os.yml` — builds and pushes the image to `ghcr.io/<repo>` on every push to `main` that touches `Containerfile` or the workflow itself, on a weekly cron (Sunday 00:00, for security updates), and via manual `workflow_dispatch`. Tags: `latest` and short-sha.

## Containerfile structure

The base image (`ghcr.io/zirconium-dev/zirconium:latest`) already ships a full Niri + DankMaterialShell (DMS) desktop — see "Zirconium base image" below. Everything after `FROM` turns it into a headless-by-default KubeVirt/K3s appliance. Stages are organized as numbered comments (`# 1.`, `# 2.` …) — preserve this numbering when editing:

1. `systemctl set-default multi-user.target` — boot to console, not zirconium's default graphical target. The desktop is still fully installed; switch to it with `systemctl start graphical.target` (or `set-default graphical.target` to make it stick).
2. Install KVM/virt packages via `dnf` (`qemu-kvm`, `libvirt`, `virt-install`, `iscsi-initiator-utils`, etc.)
3. Flip `/etc/selinux/config` to `SELINUX=permissive` at build time (K3s's CNI + KubeVirt's device plugin need more than zirconium's desktop SELinux policy allows; this is a persisted single source of truth, not a per-boot `setenforce`).
4. Install K3s straight into the image via `curl https://get.k3s.io | INSTALL_K3S_SKIP_START=true sh -s - server ...` (`--disable=traefik --disable=servicelb --write-kubeconfig-mode=644`), so the binary + systemd unit are baked in and first boot needs no network. `INSTALL_K3S_SKIP_START=true` avoids trying to actually start the service during the container build; `systemctl enable`/`daemon-reload` invoked by the installer are safe there because systemd detects it's running in a container build and no-ops privileged calls instead of failing — the same reason `RUN systemctl enable ...` works at all in this file. Also drops `/etc/profile.d/k3s-kubeconfig.sh` so any shell (console or a Niri terminal) has `KUBECONFIG` set without the user exporting it manually.
5. Fetch the current stable KubeVirt release tag, install `virtctl` to `/usr/local/bin`, and write that resolved version to `/etc/kubevirt-version` — the single source of truth step 6 reads from, so the manifests deployed at first boot always match the `virtctl` baked into the image.
6. Heredoc-inject `/usr/local/bin/bootstrap-kubevirt.sh`, a first-boot script that waits for the (already-running, systemd-managed) K3s API to come up, then applies the KubeVirt operator + CR from `/etc/kubevirt-version` if the `kubevirt` namespace doesn't already exist.
7. Heredoc-inject a systemd oneshot unit (`kubevirt-bootstrap.service`, `After=/Requires=k3s.service`) that runs step 6's script, then `systemctl enable k3s.service kubevirt-bootstrap.service` so both come up automatically on first boot.

Version pinning is intentionally build-time-only: nothing at runtime scrapes GitHub/DNS for "latest" — `/etc/kubevirt-version` (baked in step 5) is the only thing step 6 trusts, so a given built image always deploys a consistent, known KubeVirt version regardless of what's "latest" by the time it boots.

## Zirconium base image

Zirconium (https://github.com/zirconium-dev/zirconium) is *not* built from a plain Containerfile — it uses `mkosi` (chroot prepare/postinst scripts, a Homebrew tarball pulled from `ghcr.io/ublue-os/brew`, Flatpak repo setup, custom `/usr/lib/os-release` generation, etc.). Don't try to reproduce that pipeline by hand in this repo's Containerfile — that's almost certainly the source of past `/usr/local/share`-not-found build failures when attempting to compile zirconium from source. Instead, this project consumes zirconium's *already-built* published image (`ghcr.io/zirconium-dev/zirconium:latest`) as a `FROM` base and layers KubeVirt/K3s on top, which sidesteps the mkosi build entirely.

## Working with this repo

- There is no build/lint/test tooling in-repo. To validate a change, build the image locally with `podman build -f Containerfile .` (or `docker build`) — bootc images require a container runtime capable of building OCI images; there's no Kubernetes/VM available to test the first-boot bootstrap script itself short of actually booting the image.
- CI (`build-os.yml`) is the source of truth for how the image is built and published; mirror any local build flags/context changes there.
- Multi-line heredoc `COPY <<-'EOF' ... EOF` blocks in the Containerfile inject files directly — edit the heredoc body in place rather than switching to separate files unless there's a reason to.
