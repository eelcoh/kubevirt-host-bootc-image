FROM ghcr.io/zirconium-dev/zirconium:latest
# FROM ghcr.io/eelcoh/zirconium-base:latest
# FROM quay.io/fedora/fedora-bootc:44

# 1. Boot minimal: zirconium enables a graphical target (Niri/DMS) by default.
# We still ship the full desktop, but the appliance should come up headless;
# switch to it on demand with `systemctl start graphical.target` (or
# `systemctl set-default graphical.target` to make it persistent).
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
# than zirconium's desktop-oriented SELinux policy allows out of the box.
# Set this at build time rather than at boot so it's a persisted, single
# source of truth instead of a `setenforce 0` that has to be redone every boot.
RUN sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

# 4. Install K3s directly into the image (no network needed on first boot).
# --write-kubeconfig-mode=644 makes /etc/rancher/k3s/k3s.yaml world-readable:
# fine for a single-user appliance, but note it grants cluster-admin to any
# local user. servicelb/traefik are disabled since this is a single desktop
# box, not a box that needs its own load balancer/ingress.
# INSTALL_K3S_BIN_DIR=/usr/bin: zirconium (like stock ostree) ships /usr/local
# as a symlink into /var/usrlocal, which doesn't exist yet at build time, so
# the installer's default /usr/local/bin fails outright. /usr/bin is real,
# non-/var image content, so it survives into the deployed system.
# INSTALL_K3S_SKIP_ENABLE=true: the installer's own enable step also runs
# `systemctl daemon-reload`, which (unlike plain `systemctl enable`) needs a
# live systemd bus that doesn't exist during a container build and fails hard.
# Step 7 below enables k3s.service itself once the unit file already exists.
RUN curl -sfL https://get.k3s.io | INSTALL_K3S_SKIP_START=true INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_BIN_DIR=/usr/bin sh -s - server \
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
    && mv "virtctl-${KUBEVIRT_VERSION}-linux-amd64" /usr/bin/virtctl \
    && echo -n "${KUBEVIRT_VERSION}" > /etc/kubevirt-version

# 6. Inject the automated initialization script: waits for K3s to come up,
# then applies the KubeVirt operator + CR if not already deployed.
# Lives under /usr/bin rather than /usr/local/bin for the same /var/usrlocal
# reason as steps 4-5 above.
COPY <<-'EOF' /usr/bin/bootstrap-kubevirt.sh
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
RUN chmod +x /usr/bin/bootstrap-kubevirt.sh

# 7. Define the one-shot systemd service that runs the bootstrap script, and
# enable it plus K3s itself so both come up automatically on first boot.
COPY <<-'EOF' /usr/lib/systemd/system/kubevirt-bootstrap.service
[Unit]
Description=Automated Single-Box KubeVirt Bootstrapper
After=k3s.service
Requires=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bootstrap-kubevirt.sh

[Install]
WantedBy=multi-user.target
EOF

RUN systemctl enable k3s.service kubevirt-bootstrap.service
