#!/bin/bash

set -e

DOWNLOAD_DIR="/usr/local/bin"

if [ "${DEBUG}" = 1 ]; then
    set -x
    KUBEADM_VERBOSE="-v=8"
else
    KUBEADM_VERBOSE="-v=4"
fi

# Usage:
#   curl ... | ENV_VAR=... sh -
#       or
#   ENV_VAR=... ./setup.sh
#

# Environment variables:
#
#   - INSTALL_METHOD
#     The installation method to use: 'apt', 'tar' (TBD), 'rpm', or 'airgap' (TBD).
#     Default is 'apt'
#
#   - KUBERNETES_VERSION
#     Version of kubernetes to install.
#     Default is the latest version.
#
#   - CRICTL_VERSION
#     Version of crictl to install
#     Default is not set
#
#   - JOIN_TOKEN
#     Token to join the control-plane, node will not join if not passed.
#     Default is not set.
#
#   - JOIN_TOKEN_CACERT_HASH
#     Token Certificate Authority hash to join the control-plane, node will not join if not passed.
#     Default is not set.
#
#   - JOIN_URL
#     URL to join the control-plane, node will not join if not passed.
#     Default is not set.
#

# setup_arch set arch and suffix, fatal if architecture is not supported.
setup_arch() {
    case ${ARCH:=$(uname -m)} in
    amd64)
        ARCH=amd64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    x86_64)
        ARCH=amd64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    arm64)
        ARCH=arm64
        SUFFIX=$(uname -s | tr '[:upper:]' '[:lower:]')-${ARCH}
        ;;
    *)
        fatal "unsupported architecture ${ARCH}"
        ;;
    esac
}

# setup_env defines needed environment variables.
setup_env() {
    # must be root
    if [ ! "$(id -u)" -eq 0 ]; then
        fatal "You need to be root to perform this install"
    fi

    # use 'apt' install method if available by default
    if [ -z "${INSTALL_METHOD}" ] && command -v apt >/dev/null 2>&1; then
        INSTALL_METHOD="apt"
    fi

}

# info logs the given argument at info log level.
info() {
    echo "[INFO] " "$@"
}

# warn logs the given argument at warn log level.
warn() {
    echo "[WARN] " "$@" >&2
}

# fatal logs the given argument at fatal log level.
fatal() {
    echo "[ERROR] " "$@" >&2
    exit 1
}

set_prerequisites() {
    info "Set node prerequisites: forwarding IPv4 and letting iptables see bridged traffic"
    cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter

    # sysctl params required by setup, params persist across reboots
    cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

    # Apply sysctl params without reboot
    sysctl --system
}

install_containerd() {
    info "installing containerd"
    wget https://github.com/containerd/containerd/releases/download/v1.6.15/containerd-1.6.15-linux-amd64.tar.gz && \
    	tar Cxzvf /usr/local containerd-1.6.15-linux-amd64.tar.gz

    mkdir -p /usr/local/lib/systemd/system/ && \
    	wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service && \
    	mv containerd.service /usr/local/lib/systemd/system/

    wget https://github.com/opencontainers/runc/releases/download/v1.1.4/runc.amd64 && \
        chmod 755 runc.amd64 && \
        mv runc.amd64 /usr/local/sbin/runc

    mkdir -p /opt/cni/bin && \
    	wget https://github.com/containernetworking/plugins/releases/download/v1.2.0/cni-plugins-linux-amd64-v1.2.0.tgz && \
    	tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.2.0.tgz

    mkdir -p /etc/containerd
    containerd config default | sed -e "s#SystemdCgroup = false#SystemdCgroup = true#g" | tee /etc/containerd/config.toml

    systemctl daemon-reload
    systemctl enable --now containerd
    systemctl restart containerd

}

install_crictl() {
    info "installing crictl"
    if [ -z "${CRICTL_VERSION}" ]; then
        warn "===== The crictl version has not been passed, STOP ====="
        return
    fi

    curl -L "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz" |\
    sudo tar -C "$DOWNLOAD_DIR" -xz
}

apt_install_containerd() {
    info "installing containerd"
    apt update
    apt install -y containerd
    mkdir -p /etc/containerd
    containerd config default | sed -e "s#SystemdCgroup = false#SystemdCgroup = true#g" | tee /etc/containerd/config.toml
    systemctl restart containerd
    systemctl enable containerd
    apt-mark hold containerd
}

apt_install_kube() {
    info "Update the apt package index and install packages needed to use the Kubernetes apt repository"
    apt install -y apt-transport-https ca-certificates socat conntrack
    info "Download the Google Cloud public signing key"
    curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    info "Add the Kubernetes apt repository"
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    info "Download and install kubernetes components"
    local VERSION
    if [ ! -z "${KUBERNETES_VERSION}" ]; then
        VERSION="=${KUBERNETES_VERSION}-00"
    fi

    apt update
    apt install -y kubelet"$VERSION" kubeadm"$VERSION" kubectl"$VERSION" --allow-downgrades --allow-change-held-packages
    apt-mark hold kubelet kubeadm kubectl
}

install_kube() {
    if [ -z "${KUBERNETES_VERSION}" ]; then
        warn "===== The kubernetes version has not been passed, a tested version will be used ====="
        KUBERNETES_VERSION="1.25.5"
    fi
    
    info "Update the apt package index and install packages needed to use the Kubernetes apt repository"
    apt install -y apt-transport-https ca-certificates socat conntrack
    
    wget https://storage.googleapis.com/kubernetes-release/release/v"${KUBERNETES_VERSION}"/bin/linux/"${ARCH}"/{kubeadm,kubelet,kubectl} && \
        chmod +x {kubeadm,kubelet,kubectl} && \
        mv {kubeadm,kubelet,kubectl} "${DOWNLOAD_DIR}"

    RELEASE_VERSION="v0.4.0"
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" |\
        sed "s:/usr/bin:${DOWNLOAD_DIR}:g" |\
        sudo tee /etc/systemd/system/kubelet.service

    sudo mkdir -p /etc/systemd/system/kubelet.service.d
    curl -sSL "https://raw.githubusercontent.com/kubernetes/release/${RELEASE_VERSION}/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" |\
        sed "s:/usr/bin:${DOWNLOAD_DIR}:g" |\
        sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    
    systemctl enable --now kubelet
}

join_controlplane() {
    # check if env var for joining has been passed
    if [ -z "${JOIN_TOKEN}" ]; then
        warn "The join Token has not passed, the machine will not be part of the cluster"
        return
    fi
    if [ -z "${JOIN_TOKEN_CACERT_HASH}" ]; then
        warn "The join Token Certificate Authority hash has not passed, the machine will not be part of the cluster"
        return
    fi
    if [ -z "${JOIN_URL}" ]; then
        warn "The join url has not passed, the machine will not be part of the cluster"
        return
    fi
    info "Joining the control-plane"
    kubeadm join "${JOIN_URL}" --token "${JOIN_TOKEN}" --discovery-token-ca-cert-hash "${JOIN_TOKEN_CACERT_HASH}" "${KUBEADM_VERBOSE}"
}

# install container runtime and kubernetes components
install() {
    case ${INSTALL_METHOD} in
    apt)
        install_crictl
        apt_install_containerd
        apt_install_kube "${KUBERNETES_VERSION}"
        ;;
    rpm)
        fatal "currently unsupported install method ${INSTALL_METHOD}"
        ;;
    tar)
        install_crictl
        install_containerd
        install_kube "${KUBERNETES_VERSION}"
        ;;
    airgap)
        fatal "currently unsupported install method ${INSTALL_METHOD}"
        ;;
    *)
        fatal "unknown install method ${INSTALL_METHOD}"
        ;;
    esac
}

do_setup() {
    setup_arch
    setup_env
    set_prerequisites
    install 
    join_controlplane
}

do_setup
exit 0
