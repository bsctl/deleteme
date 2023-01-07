#!/bin/sh

set -e

if [ "${DEBUG}" = 1 ]; then
    set -x
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
    if [ ! $(id -u) -eq 0 ]; then
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
    apt install -y apt-transport-https ca-certificates
    info "Download the Google Cloud public signing key"
    curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
    info "Add the Kubernetes apt repository"
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    info "installing kubernetes components"
    local VERSION
    if [ ! -z "${KUBERNETES_VERSION}" ]; then
        VERSION="=${KUBERNETES_VERSION}-00"
    fi
    apt update
    apt install -y kubelet$VERSION kubeadm$VERSION --allow-downgrades --allow-change-held-packages
    apt-mark hold kubelet kubeadm
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
    kubeadm join ${JOIN_URL} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${JOIN_TOKEN_CACERT_HASH}

}

# install container runtime and kubernetes components
install() {
    case ${INSTALL_METHOD} in
    apt)
        apt_install_containerd
        apt_install_kube "${KUBERNETES_VERSION}"
        ;;
    rpm)
        fatal "currently unsupported install method ${INSTALL_METHOD}"
        ;;
    tar)
        fatal "currently unsupported install method ${INSTALL_METHOD}"
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