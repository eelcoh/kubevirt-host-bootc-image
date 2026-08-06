FROM quay.io/fedora/fedora-bootc:44

# 1. Install KVM, hardware virtualization tools, and system utility packages
RUN dnf -y install \
    qemu-kvm \
    libvirt \
    virt-install \
    util-linux \
    iptables \
    iscsi-initiator-utils \
    && dnf clean all

# 2. Download K3s installer script
RUN curl -sfL https://k3s.io -o /usr/local/bin/k3s-installer.sh \
    && chmod +x /usr/local/bin/k3s-installer.sh

# 3. Install the KubeVirt management client binary (virtctl)
RUN KUBEVIRT_VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt) \
    && echo "Gevonden stabiele KubeVirt versie: ${KUBEVIRT_VERSION}" \
    && curl -LO "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64" \
    && chmod +x "virtctl-${KUBEVIRT_VERSION}-linux-amd64" \
    && mv "virtctl-${KUBEVIRT_VERSION}-linux-amd64" /usr/local/bin/virtctl

# 4. Inject the automated initialization script
RUN mkdir -p /usr/local/bin
COPY <<-'EOF' /usr/local/bin/bootstrap-kubevirt.sh
#!/bin/bash
set -e

# Put SELinux in permissive mode temporarily if it blocks local K3s networking
setenforce 0 || true

# Run K3s in standalone control-plane mode
if ! systemctl is-active --quiet k3s; then
    echo "Launching embedded K3s cluster..."
    INSTALL_K3S_SKIP_DOWNLOAD=true /usr/local/bin/k3s-installer.sh --disable=traefik
fi

# Set up local context permissions for the script layer
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get nodes; do
    echo "Waiting for local node status..."
    sleep 3
done

# Grab latest release tag version
KUBEVIRT_VERSION=$(curl -s https://github.com | grep tag_name | cut -d '"' -f 4)

# Deploy the operator and resources if missing
if ! kubectl get namespace kubevirt >/dev/null 2>&1; then
    echo "Deploying KubeVirt Operator version ${KUBEVIRT_VERSION}..."
    kubectl create -f "https://github.com{KUBEVIRT_VERSION}/kubevirt-operator.yaml"
    kubectl create -f "https://github.com{KUBEVIRT_VERSION}/kubevirt-cr.yaml"
fi

echo "Appliance Initialization Complete!"
EOF
RUN chmod +x /usr/local/bin/bootstrap-kubevirt.sh

# 5. Define the One-Shot systemd service definition
COPY <<-'EOF' /usr/lib/systemd/system/kubevirt-bootstrap.service
[Unit]
Description=Automated Single-Box KubeVirt Bootstrapper
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/bootstrap-kubevirt.sh

[Install]
WantedBy=multi-user.target
EOF

# 6. Enable system services inside image layer
RUN systemctl enable kubevirt-bootstrap.service
