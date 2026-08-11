# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A family of [bootc](https://containers.github.io/bootc/) (bootable container) OS images, all built from a common `base` image and layered from there into more specialized flavors:

- **base** — plain Fedora bootc + KVM/libvirt (hardware virtualization) + a couple of generic bootc/ostree fixes. No desktop, no Kubernetes.
- **k3s** — base + K3s (Kubernetes control plane), nothing layered on top of it yet. Shared by every flavor below that needs a cluster, so K3s is installed exactly once instead of duplicated per flavor.
- **kubevirt** — k3s + KubeVirt (VM workloads). Turns the host into a single-box KubeVirt appliance.
- **desktops/niri**, **desktops/sway**, **desktops/cosmic** — base + one desktop environment each, no Kubernetes. Niri+DankMaterialShell, Sway, and COSMIC respectively.
- **niri-kubevirt** — kubevirt + the niri desktop layered on top. The original single-image goal of this repo, now expressed as kubevirt + niri composed together.
- **agent-runtime** — k3s + a first-boot deploy of [Agent Substrate](https://github.com/agent-substrate/substrate)'s control plane onto the built-in K3s, for hosting agent workloads at scale. No desktop.

There is no application code — the entire project is the image definitions plus the CI pipeline that builds and publishes each of them.

## Repository layout

```
base/Containerfile                   # shared by everything below
k3s/Containerfile                    # FROM base; shared by kubevirt and agent-runtime
kubevirt/Containerfile               # FROM k3s
desktops/niri/Containerfile          # FROM base
desktops/sway/Containerfile          # FROM base
desktops/cosmic/Containerfile        # FROM base
niri-kubevirt/Containerfile          # FROM kubevirt
agent-runtime/Containerfile          # FROM k3s
.github/workflows/build-image.yml    # reusable workflow: builds+pushes one flavor
.github/workflows/build-images.yml   # orchestrator: 8 jobs, one per flavor, in dependency order
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
4. Install interactive dev tooling (`git`, `zsh`, `chezmoi`, `atuin`, `zoxide`, `htop`, `btop`, `distrobox`) — lives in `base` for the same reason step 2 does: every flavor gets it for free instead of duplicating it per flavor. `distrobox`'s `podman or docker` dependency is satisfied by the `podman` already shipped in `fedora-bootc:44`.

SELinux is deliberately left at Fedora's default `enforcing` in `base` — libvirt/qemu-kvm work fine under the targeted policy. Only `kubevirt` (whose K3s CNI and KubeVirt's device plugin need more than targeted allows) flips it to `permissive`.

## k3s/Containerfile

`FROM` base. Holds exactly the K3s install steps that used to live in `kubevirt/Containerfile`, extracted so `kubevirt` and `agent-runtime` can both build on a shared Kubernetes layer instead of each installing K3s themselves:

1. Flip `/etc/selinux/config` to `SELINUX=permissive` at build time (a persisted single source of truth, not a per-boot `setenforce`). K3s's default CNI (flannel/vxlan) and the workloads layered on top (KubeVirt's device plugin, Agent Substrate's sandboxed actors) need more than the default targeted policy allows.
2. Install K3s straight into the image via `curl https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true sh -s - server ...` (`--disable=traefik --disable=servicelb --write-kubeconfig-mode=644`), so the binary + systemd unit are baked in and first boot needs no network. `INSTALL_K3S_SKIP_START=true` avoids trying to actually start the service during the container build. `INSTALL_K3S_SKIP_ENABLE=true` skips the installer's own `systemctl enable`/`daemon-reload` — the latter needs a live systemd bus that doesn't exist during a container build and fails hard (unlike plain `systemctl enable`, which works offline); step 3 enables `k3s.service` itself once the unit file already exists. Also drops `/etc/profile.d/k3s-kubeconfig.sh` so any shell has `KUBECONFIG` set without the user exporting it manually.
3. `systemctl enable k3s.service`.

## kubevirt/Containerfile

`FROM` k3s, numbered steps continue the same convention:

1. Fetch the current stable KubeVirt release tag, install `virtctl` to `/usr/local/bin`, and write that resolved version to `/etc/kubevirt-version` — the single source of truth step 2 reads from, so the manifests deployed at first boot always match the `virtctl` baked into the image.
2. Heredoc-inject `/usr/local/bin/bootstrap-kubevirt.sh`, a first-boot script that waits for the (already-running, systemd-managed) K3s API to come up, then applies the KubeVirt operator + CR from `/etc/kubevirt-version` if the `kubevirt` namespace doesn't already exist. Also injects the `kubevirt-bootstrap.service` systemd oneshot unit (`After=`/`Requires=k3s.service`) that runs it.
3. `systemctl enable kubevirt-bootstrap.service` (`k3s.service` itself is already enabled by the k3s base layer).

Version pinning is intentionally build-time-only: nothing at runtime scrapes GitHub/DNS for "latest" — `/etc/kubevirt-version` (baked in step 1) is the only thing step 2's script trusts, so a given built image always deploys a consistent, known KubeVirt version regardless of what's "latest" by the time it boots.

## Desktop flavors (desktops/niri, desktops/sway, desktops/cosmic)

Each is `FROM` base, self-contained, no Kubernetes:

- **niri** — Niri (scrollable-tiling Wayland compositor) + DankMaterialShell (DMS, a Quickshell-based shell replacing the usual bar/launcher/lock/notification-daemon pile). DankMaterialShell ships its own greetd-native greeter, but Fedora doesn't package a `dms-greeter` RPM the way some other distros do — this Containerfile replicates DMS upstream's own documented manual-install fallback: create a `greeter` system user, seed its cache dir per DMS's own tmpfiles rule, install the `dms-greeter` wrapper, and point `/etc/greetd/config.toml` at it. DMS's own `dms.service` (systemd `--user`, `WantedBy=graphical-session.target`) is enabled globally (`systemctl --global enable`) so every user account gets it without a per-user step.
- **sway** — Sway (i3-compatible wlroots compositor) + waybar (status bar; sway has none built in) + swaybg/swaylock/swayidle + `xdg-desktop-portal-wlr` (sway is genuinely wlroots-based, unlike niri, so this is the correct screen-capture portal backend here) + greetd/tuigreet. Simpler wiring than niri: Fedora's `greetd` RPM already ships a `sysusers.d` entry creating a `greetd` system user, so `/etc/greetd/config.toml` just points `tuigreet --cmd sway` at that existing account — no manual `useradd` needed.
- **cosmic** — `dnf group install cosmic-desktop` (Fedora ships a full spin-quality comps group for COSMIC, unlike niri/sway which are assembled package-by-package) + `cosmic-greeter`. Simplest of the three: `cosmic-greeter`'s RPM ships its own `sysusers.d`, `tmpfiles.d`, and a ready-made `/etc/greetd/cosmic-greeter.toml` — COSMIC's greeter is greetd-based under the hood. No manual wiring at all beyond `systemctl enable cosmic-greeter.service`.

All three: `alacritty` as the terminal (niri/sway; matches niri's default `Mod+T` keybind), `gnome-keyring` + `polkit-kde` (a ~300KB standalone polkit agent, not KDE/Plasma), and the PipeWire audio stack. All plain Fedora 44 packages, no COPR — verified directly against the live Fedora 44 repos, same practice as everything else in this repo.

Every desktop's login front-end (`greetd`, `cosmic-greeter`) aliases `display-manager.service`, which `graphical.target` already `Wants=` — so `systemctl enable <front-end>.service` is sufficient to wire it up; nothing else needs to reference `display-manager.service` directly. Each desktop flavor also does `systemctl set-default graphical.target` as its own final step, overriding `base`'s console default — without it the host stays on `multi-user.target` and the login front-end never runs at all, leaving the user stuck at a bare tty. For niri specifically this was also the root cause of DankMaterialShell appearing not to work: a user starting `niri` by hand from that tty bypasses greetd's `niri-session` → `niri.service` → `graphical-session.target` chain entirely, and `dms.service` (which is only pulled in via that chain) never starts, leaving a vanilla, unstyled niri session.

### Wallpapers

All three desktops install `fedora-workstation-backgrounds` (Fedora's own official wallpaper art, CC-BY-4.0 — plain Fedora package, no custom image asset needed) and default to `mermaid_dark.webp` from it. Each compositor has its own wiring, since none of them share a config mechanism:

- **sway** — a `swaybg` autostart line in `/etc/sway/config.d/40-wallpaper.conf`, picked up by `sway-config-fedora`'s own `layered-include` of `/etc/sway/config.d/*.conf`. `swaybg` decodes `.webp` via gdk-pixbuf2/glycin (`glycin-image-rs`, already one of `swaybg`'s own dependencies, lists `image/webp` in its loader conf — verified directly).
- **niri** — a `spawn-at-startup "swaybg" ...` line appended to the generated `/etc/niri/config.kdl` (niri has no wallpaper support of its own, and needs `swaybg` added to the package list for it, unlike sway which already installs it as a matter of course). DankMaterialShell has its own wallpaper module, but it starts with an empty `wallpaperPath` in per-user session state, so nothing renders until a user picks one by hand — `swaybg` just paints something underneath in the meantime, and DMS's own module takes over the moment a user sets a wallpaper through it.
- **cosmic** — an `/etc/xdg/cosmic/com.system76.CosmicBackground/v1/all` override (COSMIC's own RON-based `cosmic-config` layers `~/.config/cosmic` > `/etc/xdg/cosmic` > `/usr/share/cosmic`, verified directly via `strings` on `/usr/bin/cosmic-bg`), rather than editing the RPM-owned vendor-default file under `/usr/share/cosmic` directly.

### Sway themes

`desktops/sway/Containerfile` ships four color themes — Nord, Catppuccin (Mocha), Matcha Green, and Chameleon Grove Green — each as a self-contained `(sway.conf, waybar-style.css, alacritty.toml)` triple under `/etc/sway/themes/<name>/`. Matcha Green is the active system default: its three files are copied into `/etc/sway/config.d/20-theme.conf`, `/etc/xdg/waybar/style.css`, and `/etc/alacritty/alacritty.toml` at build time. The other three are reference-only — switch by copying a theme's files over the active ones and running `swaymsg reload` (sway/waybar pick this up live; alacritty reads its config on window-open, not startup, so existing windows need a restart).

Nord and Catppuccin use their respective projects' own officially published palettes (nordtheme.com; catppuccin.com's Mocha variant), including their widely-published Alacritty color mappings. Chameleon Grove Green's sway/waybar colors are ported directly from `cryinkfly/SwayWM-Themes`' theme of the same name (its own description is an near-verbatim match for this repo's issue that requested it); that project ships no Alacritty config, so its `alacritty.toml` here extends the same green family to a full 16-color ANSI palette rather than porting one 1:1. Matcha Green is an original palette built around `#8BC34A` on dark gray — not a literal port of any single upstream project, since none of the sources checked for the other three themes ship one under that name.

## agent-runtime/Containerfile

`FROM` k3s. Does a first-boot deploy of [Agent Substrate](https://github.com/agent-substrate/substrate)'s control plane onto the built-in K3s. No desktop.

Google's [`ax`](https://github.com/google/ax) (Agent Executor) was evaluated and deliberately left out. AX-the-runtime (event log, resumption, distributed scheduling) is genuinely provider-agnostic by its own description, but the only harness it ships today is Antigravity — Google's own coding-agent product, wired specifically to Gemini (AI Studio) or Vertex AI (verified directly in `google/ax`'s `internal/config/config.go` and `internal/harness/antigravity`). Bringing a non-Google harness means implementing their `HarnessService` interface yourself; none ships out of the box, and "support for more frontier harnesses besides Antigravity" is on their own roadmap, not shipped. That makes `ax` as released unusable without a Google AI credential, defeating the point of a general-purpose agent runtime image. Agent Substrate itself has no such dependency — it's a Kubernetes-level scheduler/sandbox layer, agnostic of what actually runs inside its actors (its own docs list LangChain, MCP servers, and Claude Code as compatible) — so only Substrate's control plane is deployed here.

Agent Substrate is explicitly "early development, no backward-compatibility guarantees" (verified directly against the repo) and ships no pre-built binaries or versioned release artifact beyond source tags — it's built from source here, pinned to a specific tag via the `SUBSTRATE_VERSION` build arg rather than "latest", for the same reason KubeVirt's version is pinned in `kubevirt/Containerfile`.

1. Install `golang` and `docker-distribution`. Go is needed because Agent Substrate ships no prebuilt binaries. `docker-distribution` is a local, anonymous (no-auth) OCI registry: Agent Substrate's own install script builds its control-plane images with `ko` and pushes them somewhere, and there's no published pre-built release to `kubectl apply` the way KubeVirt has — this appliance has no external registry to point at, so it runs one itself.
2. `git clone --branch ${SUBSTRATE_VERSION} --depth 1` Agent Substrate into `/opt/agent-substrate`. Its own `hack/` scripts manage their own pinned build of `ko` via Go's tool-directive mechanism (`go tool`, see `hack/run-tool.sh`) — nothing to separately install for that, it resolves from this clone's `go.mod` on first use (needs network the first time, same as KubeVirt's bootstrap needing network to fetch manifests).
3. Write `/etc/rancher/k3s/registries.yaml`, pointing K3s's containerd at `localhost:5000` (the registry from step 1) as a plain-HTTP mirror, so images `ko` pushes there can actually be pulled by the cluster. This works because single-node K3s runs containerd on the same host as the registry — "localhost" means the same machine for both the push and the pull. Wouldn't hold for a multi-node cluster, but this appliance is always one node.
4. Heredoc-inject `/usr/local/bin/bootstrap-agent-substrate.sh`, a first-boot script that waits for K3s and the local registry to come up, then runs Agent Substrate's own `hack/install-ate.sh --deploy-ate-system` (against `KO_DOCKER_REPO=localhost:5000/ate`) if the `ate-system` namespace doesn't already exist. Also injects the `agent-substrate-bootstrap.service` systemd oneshot unit (`After=`/`Requires=k3s.service docker-distribution.service`, `TimeoutStartSec=0` since `ko` builds plus per-component rollout waits routinely exceed systemd's default 90s unit-start timeout).
5. `systemctl enable docker-distribution.service agent-substrate-bootstrap.service` (`k3s.service` itself is already enabled by the k3s base layer).

Unlike `kubevirt`, this control plane comes up fully automatically with no external credentials needed — deploying actual agent workloads onto it (ActorTemplates/WorkerPools) is a "bring your own harness" step left to the user, per Agent Substrate's own framework-agnostic design.

## niri-kubevirt/Containerfile

`FROM` the `kubevirt` image (not the reverse — desktop is layered on top of the Kubernetes appliance, not the other way around). Intentionally duplicates `desktops/niri/Containerfile`'s desktop steps verbatim rather than sharing them through an include mechanism, matching this repo's convention of self-contained, heredoc-style Containerfiles with no cross-file includes anywhere else in the project. **If the niri desktop steps change, update both files together.**

## CI (.github/workflows/)

`build-image.yml` is a reusable workflow (`workflow_call`) that builds and pushes exactly one flavor: given `flavor` (image path suffix), `containerfile` (path), and optional `build_args`, it computes a short SHA, builds with buildx, and pushes `ghcr.io/<repo>/<flavor>:latest` and `:sha-<short>` — tags and cache (`type=gha`, scoped per flavor so the six builds don't clobber each other's cache) all live here.

`build-images.yml` is the orchestrator: same triggers as before (push to `main` touching `base/**`, `k3s/**`, `kubevirt/**`, `desktops/**`, `niri-kubevirt/**`, `agent-runtime/**`, or the workflows themselves; weekly Sunday cron for security updates; manual `workflow_dispatch`). It calls `build-image.yml` once per flavor with `needs:` encoding the dependency DAG:

```
base ──┬─→ k3s ──┬─→ kubevirt ─→ niri-kubevirt
       │         └─→ agent-runtime
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
  podman build -f k3s/Containerfile --build-arg BASE_IMAGE=local/base:dev -t local/k3s:dev .
  podman build -f kubevirt/Containerfile --build-arg BASE_IMAGE=local/k3s:dev -t local/kubevirt:dev .
  podman build -f agent-runtime/Containerfile --build-arg BASE_IMAGE=local/k3s:dev -t local/agent-runtime:dev .
  podman build -f desktops/niri/Containerfile --build-arg BASE_IMAGE=local/base:dev -t local/niri:dev .
  ```
  bootc images require a container runtime capable of building OCI images; there's no Kubernetes/VM available to test the first-boot bootstrap script or greeter flows short of actually booting the image.
- When evaluating a new base image or an unfamiliar package, prefer pulling and inspecting it directly (`podman run --rm <image> sh -c '...'`, `rpm -qa`, `dnf5 info`/`search`/`download`, `ls`/`readlink -f` on suspect paths like `/usr/local`, `rpm -qlp`/`rpm -qp --scripts` on a downloaded RPM to see what it actually ships/wires up) over trusting documentation or search results — several past issues here (the `/usr/local` → `/var/usrlocal` symlink breaking K3s installs, Hummingbird's OpenSSL version conflict, which system user each greeter front-end actually creates) were only caught this way, and docs/search results were stale or vague on exactly these points.
- CI (`build-images.yml` + `build-image.yml`) is the source of truth for how the images are built and published; mirror any local build flags/context changes there.
- Multi-line heredoc `COPY <<-'EOF' ... EOF` blocks in the Containerfiles inject files directly — edit the heredoc body in place rather than switching to separate files unless there's a reason to.
