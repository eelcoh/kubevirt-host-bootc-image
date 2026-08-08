FROM quay.io/fedora/fedora-bootc:44
# FROM ghcr.io/zirconium-dev/zirconium:latest
# FROM quay.io/hummingbird-community/bootc-os:latest

# This rebuilds the appliance directly on plain fedora-bootc instead of the
# zirconium base used previously (kept above, commented, for reference/
# rollback). fedora-bootc:44 is already minimal (541 packages, no GNOME/
# desktop of any kind, ~2GB) — it's the same base Silverblue/Kinoite/etc.
# layer their desktops onto, so every desktop package below is added
# explicitly by us, not inherited. Verified by pulling and inspecting the
# image directly (`rpm -qa`, `ls /usr/local`, etc.) rather than assuming
# from docs. Notably /usr/local is a real directory here (not an
# ostree-style symlink into /var/usrlocal like some bases use), so unlike
# the earlier zirconium-based attempt, no INSTALL_K3S_BIN_DIR workaround is
# needed for K3s/virtctl to land where they normally would.
#
# quay.io/hummingbird-community/bootc-os (Fedora Hummingbird) was also
# evaluated as an even-smaller base and rejected: it ships only 266 packages
# from its own curated repo (no qemu-kvm/libvirt/niri/etc at all), and
# layering Fedora Rawhide on top to fill the gap currently fails outright —
# Rawhide has moved to OpenSSL 4.0 while Hummingbird pins patched OpenSSL
# 3.5.6 builds, so core libs can't be resolved together. Its own image
# description calls it "experimental," not meant as a general extensible
# base the way fedora-bootc is.

# 1. Boot headless (console), not graphical, even though a full desktop is
# installed below. Bring it up on demand with `systemctl start
# graphical.target` (or `systemctl set-default graphical.target` to persist).
RUN systemctl set-default multi-user.target

# 2. Install KVM, hardware virtualization tools, and system utility packages
RUN dnf -y install \
    qemu-kvm \
    libvirt \
    virt-install \
    util-linux \
    iptables \
    iscsi-initiator-utils \
    && dnf clean all

# 3. KubeVirt's device plugin and K3s's default CNI (flannel/vxlan) need more
# than the default targeted SELinux policy allows out of the box. Set this at
# build time rather than at boot so it's a persisted, single source of truth
# instead of a `setenforce 0` that has to be redone every boot.
RUN sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# 4. Install K3s directly into the image (no network needed on first boot).
# --write-kubeconfig-mode=644 makes /etc/rancher/k3s/k3s.yaml world-readable:
# fine for a single-user appliance, but note it grants cluster-admin to any
# local user. servicelb/traefik are disabled since this is a single box, not
# one that needs its own load balancer/ingress.
# INSTALL_K3S_SKIP_ENABLE=true: the installer's own enable step runs
# `systemctl daemon-reload`, which (unlike plain `systemctl enable`) needs a
# live systemd bus that doesn't exist during a container build and fails
# hard. Step 9 below enables k3s.service itself once the unit file exists.
RUN curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true sh -s - server \
    --disable=traefik \
    --disable=servicelb \
    --write-kubeconfig-mode=644

# Make kubectl (and k3s's bundled kubectl) usable from any interactive shell,
# console or graphical terminal, without the user having to export KUBECONFIG.
COPY <<-'EOF' /etc/profile.d/k3s-kubeconfig.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF

# 5. Install the KubeVirt management client binary (virtctl), and record the
# resolved version so the first-boot bootstrap script (step 6) deploys the
# exact same release instead of re-resolving "latest" at runtime.
RUN KUBEVIRT_VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt) \
    && echo "Found stable KubeVirt version: ${KUBEVIRT_VERSION}" \
    && curl -LO "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64" \
    && chmod +x "virtctl-${KUBEVIRT_VERSION}-linux-amd64" \
    && mv "virtctl-${KUBEVIRT_VERSION}-linux-amd64" /usr/local/bin/virtctl \
    && echo -n "${KUBEVIRT_VERSION}" > /etc/kubevirt-version

# 6. Inject the automated initialization script: waits for K3s to come up,
# then applies the KubeVirt operator + CR if not already deployed.
COPY <<-'EOF' /usr/local/bin/bootstrap-kubevirt.sh
#!/bin/bash
set -e

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes >/dev/null 2>&1; do
    echo "Waiting for local K3s node status..."
    sleep 3
done

if ! kubectl get namespace kubevirt >/dev/null 2>&1; then
    KUBEVIRT_VERSION=$(cat /etc/kubevirt-version)
    echo "Deploying KubeVirt Operator version ${KUBEVIRT_VERSION}..."
    kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
    kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
fi

echo "Appliance Initialization Complete!"
EOF
RUN chmod +x /usr/local/bin/bootstrap-kubevirt.sh

# 7. Define the one-shot systemd service that runs the bootstrap script.
# Enabled together with k3s.service in step 9.
COPY <<-'EOF' /usr/lib/systemd/system/kubevirt-bootstrap.service
[Unit]
Description=Automated Single-Box KubeVirt Bootstrapper
After=k3s.service
Requires=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bootstrap-kubevirt.sh

[Install]
WantedBy=multi-user.target
EOF

# 8. Desktop: Niri (scrollable-tiling Wayland compositor) + DankMaterialShell
# (DMS, a Quickshell-based shell that replaces the usual pile of bar/
# launcher/lock/notification daemons) — deliberately not GNOME/KDE/etc. All
# of niri, quickshell and DankMaterialShell are plain Fedora 44 packages, no
# COPR required (verified directly: `dnf search`/`dnf info` against this
# base pulls them straight from the `fedora`/`updates` repos).
#
# - xdg-desktop-portal-gtk / -gnome + gnome-keyring + polkit-kde: niri's own
#   upstream guidance (github.com/niri-wm/niri wiki, "Important Software")
#   for portals (file chooser + screencast), secrets, and a polkit
#   authentication agent. polkit-kde despite the name is a ~300KB standalone
#   agent, not KDE/Plasma itself.
# - alacritty: matches the terminal niri's own default-config.kdl binds to
#   Mod+T out of the box, so the default keybind works unmodified.
# - greetd: a generic greeter daemon; wired up to DMS's own bundled greeter
#   in step 9, rather than a GNOME/KDE display manager.
RUN dnf -y install \
    niri \
    DankMaterialShell \
    alacritty \
    xdg-desktop-portal \
    xdg-desktop-portal-gtk \
    xdg-desktop-portal-gnome \
    gnome-keyring \
    polkit-kde \
    greetd \
    pipewire \
    pipewire-pulseaudio \
    pipewire-alsa \
    wireplumber \
    google-noto-sans-fonts \
    google-noto-emoji-fonts \
    && dnf clean all

# 9. Wire up login and first-user-session autostart, then enable everything
# that should come up automatically.
#
# DankMaterialShell ships its own greetd-native greeter (the "dms-greeter"
# script + matching niri/greetd config templates) under
# /usr/share/quickshell/dms/Modules/Greetd/, but — unlike Arch/openSUSE/
# Debian — Fedora doesn't yet package a separate `dms-greeter` RPM that does
# this wiring automatically. This replicates DMS upstream's own documented
# manual-install steps for that case (see DankMaterialShell's
# Modules/Greetd/README.md "Manual (fallback only)" section) rather than
# inventing a new install path: create the greeter system user, seed its
# cache dir with the ownership/mode DMS's own tmpfiles rule uses
# (/usr/share/quickshell/dms/systemd/tmpfiles-dms-greeter.conf), install the
# dms-greeter wrapper, and point greetd's config.toml at it.
#
# For a real (non-greeter) login, DMS ships a proper systemd --user unit
# (dms.service, WantedBy=graphical-session.target) that niri.service already
# reaches on login — `--global` enables it for every user account up front,
# no per-user `systemctl --user enable` step needed after first login.
RUN groupadd -r greeter \
    && useradd -r -g greeter -d /var/lib/greeter -s /bin/bash -c "System Greeter" greeter \
    && mkdir -p /var/lib/greeter /var/cache/dms-greeter \
    && chown greeter:greeter /var/lib/greeter /var/cache/dms-greeter \
    && chmod 750 /var/cache/dms-greeter \
    && install -m 0755 /usr/share/quickshell/dms/Modules/Greetd/assets/dms-greeter /usr/local/bin/dms-greeter

COPY <<-'EOF' /etc/greetd/config.toml
[terminal]
vt = 1

[default_session]
user = "greeter"
command = "/usr/local/bin/dms-greeter --command niri"
EOF

#
# systemd-remount-fs.service is masked because it fails on every boot on
# this composefs-based root (`fsconfig() failed: overlay: No changes
# allowed in reconfigure` — the unit tries to reconfigure `/etc/fstab`
# mount options onto the overlayfs root, which overlayfs doesn't support).
# This is a known upstream issue on ostree/bootc composefs roots, not
# specific to this image (see fedora-silverblue/issue-tracker#605,
# bootc-dev/bootc#971). The unit is `static` (no [Install] section), so it
# isn't started via a `.wants/` symlink `disable` could remove — masking is
# the only way to actually stop it running.
RUN systemctl --global enable dms.service \
    && systemctl enable k3s.service kubevirt-bootstrap.service greetd.service sshd.service \
    && systemctl mask systemd-remount-fs.service
