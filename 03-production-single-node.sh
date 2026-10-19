#!/bin/bash
# Single-node kubeadm cluster plus the open-source NVIDIA Run:ai installer.
# Debian-family and RHEL-family hosts get native packages. Other families stop
# with the detected OS instead of running the wrong package commands.
#
#   sudo bash 03-production-single-node.sh
#   sudo bash 03-production-single-node.sh --apply
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/os.sh"
detect_os
# shellcheck disable=SC1091
. "${HERE}/lib/common.sh"

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run this script with sudo."
fi
print_os
require_supported_family

APPLY=0
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=1
elif [[ -n "${1:-}" ]]; then
  die "Usage: sudo bash $0 [--apply]"
fi

if [[ "${OS_FAMILY}" != "debian" && "${OS_FAMILY}" != "rhel" ]]; then
  die "Production kubeadm packages are automated for Debian/Ubuntu/Pop and RHEL/Fedora. This host is ${OS_PRETTY} (${OS_FAMILY}). Use ./install.sh --mode local on this OS."
fi
if [[ "${OS_ARCH}" == "unsupported" ]]; then
  die "Unsupported CPU architecture: ${OS_MACHINE}"
fi

USER_NAME="$(target_user)"
USER_HOME="$(target_home "${USER_NAME}")"
STATE_DIR="${RUNAI_STATE_DIR:-${USER_HOME}/.local/share/runai-setup/production}"
DOMAIN="${RUNAI_DOMAIN:-runai.local}"
CLUSTER_NAME="${RUNAI_CLUSTER_NAME:-local-gpu}"
RUNAI_VERSION="${RUNAI_VERSION:-3.0.20}"

KIND_BIN=""
if [[ -x "${USER_HOME}/.local/bin/kind" ]]; then
  KIND_BIN="${USER_HOME}/.local/bin/kind"
elif command -v kind >/dev/null 2>&1; then
  KIND_BIN="$(command -v kind)"
fi
if [[ -n "${KIND_BIN}" ]] && "${KIND_BIN}" get clusters 2>/dev/null | grep -qx 'runai-local'; then
  die "Kind cluster runai-local is still present. From the Run:ai source tree run: ./local-dev.sh --teardown"
fi
if ss -ltn | awk '{print $4}' | grep -Eq ':(80|443)$'; then
  echo "Port 80 or 443 is already in use." >&2
  ss -ltn | awk 'NR==1 || /:(80|443)$/' >&2
  exit 1
fi

install_containerd_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg apt-transport-https python3 openssl socat conntrack
  if ! dpkg -s containerd.io >/dev/null 2>&1 && ! dpkg -s containerd >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DOCKER_CHANNEL_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_CHANNEL_DISTRO} ${DOCKER_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y containerd.io
  fi
  if ! command -v nvidia-ctk >/dev/null 2>&1 && has_nvidia_driver; then
    rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get install -y nvidia-container-toolkit
  fi
}

install_containerd_rhel() {
  ${PKG_MGR} -y install ca-certificates curl python3 openssl socat conntrack
  if ! command -v containerd >/dev/null 2>&1; then
    if ! ${PKG_MGR} config-manager --add-repo "https://download.docker.com/linux/${DOCKER_CHANNEL_DISTRO}/docker-ce.repo"; then
      ${PKG_MGR} config-manager addrepo --from-repofile="https://download.docker.com/linux/${DOCKER_CHANNEL_DISTRO}/docker-ce.repo"
    fi
    ${PKG_MGR} -y install containerd.io
  fi
  if ! command -v nvidia-ctk >/dev/null 2>&1 && has_nvidia_driver; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
      -o /etc/yum.repos.d/nvidia-container-toolkit.repo
    ${PKG_MGR} -y install nvidia-container-toolkit
  fi
}

install_kubernetes_debian() {
  local minor="$1"
  rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
}

install_kubernetes_rhel() {
  local minor="$1"
  cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/repodata/repomd.xml.key
EOF
  ${PKG_MGR} -y install kubelet kubeadm kubectl
  ${PKG_MGR} -y versionlock add kubelet kubeadm kubectl 2>/dev/null || true
}

if [[ "${OS_FAMILY}" == "debian" ]]; then
  install_containerd_debian
else
  install_containerd_rhel
fi

if [[ ! -s /etc/containerd/config.toml ]]; then
  containerd config default > /etc/containerd/config.toml
fi
if has_nvidia_driver; then
  nvidia-ctk runtime configure --runtime=containerd
fi
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  die "containerd has no SystemdCgroup = true setting. Run: containerd config default > /etc/containerd/config.toml"
fi
systemctl restart containerd

K8S_MINOR=""
for minor in 1.37 1.36 1.35; do
  if [[ "${OS_FAMILY}" == "debian" ]]; then
    probe="https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release"
  else
    probe="https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/repodata/repomd.xml.key"
  fi
  if curl -fsI -o /dev/null "${probe}"; then
    K8S_MINOR="${minor}"
    break
  fi
done
[[ -n "${K8S_MINOR}" ]] || die "Could not reach a Kubernetes 1.35-1.37 package repository."
log "Using Kubernetes ${K8S_MINOR} packages for ${OS_FAMILY}."
if [[ "${OS_FAMILY}" == "debian" ]]; then
  install_kubernetes_debian "${K8S_MINOR}"
else
  install_kubernetes_rhel "${K8S_MINOR}"
fi
systemctl enable kubelet

mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/20-swap.conf <<'EOF'
[Service]
Environment="KUBELET_EXTRA_ARGS=--fail-swap-on=false"
EOF
systemctl daemon-reload

if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --ignore-preflight-errors=Swap \
    --cri-socket=unix:///var/run/containerd/containerd.sock
fi

install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.kube/config"
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl taint nodes --all node-role.kubernetes.io/control-plane- >/dev/null 2>&1 || true
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.32/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostNetwork=true \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.kind=DaemonSet \
  --set controller.service.type=ClusterIP \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClassResource.default=true

if ! grep -qF "${DOMAIN}" /etc/hosts; then
  echo "127.0.0.1 ${DOMAIN}" >> /etc/hosts
fi

mkdir -p "${STATE_DIR}/certs"
if [[ ! -f "${STATE_DIR}/certs/tls.crt" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout "${STATE_DIR}/certs/tls.key" \
    -out "${STATE_DIR}/certs/tls.crt" \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN},IP:127.0.0.1"
fi
chown -R "${USER_NAME}:${USER_NAME}" "${STATE_DIR}"

INSTALLER="${STATE_DIR}/runai-installer"
if [[ ! -x "${INSTALLER}" ]]; then
  curl -fL -o "${INSTALLER}" \
    "https://github.com/dsx-ai-factory/run-ai/releases/download/${RUNAI_VERSION}/runai-installer-linux-${OS_ARCH}"
  chmod +x "${INSTALLER}"
fi

DRIVER_ENABLED=true
if has_nvidia_driver; then
  DRIVER_ENABLED=false
fi

cat > "${STATE_DIR}/config.yaml" <<EOF
install:
  mode: full_installation
  connectivity: connected

registry:
  type: ngc

controlPlane:
  enabled: true
  domain: ${DOMAIN}
  tls:
    certPath: ${STATE_DIR}/certs/tls.crt
    keyPath: ${STATE_DIR}/certs/tls.key

cluster:
  enabled: true
  name: ${CLUSTER_NAME}
  workloadRouting: host
  tls:
    certPath: ${STATE_DIR}/certs/tls.crt
    keyPath: ${STATE_DIR}/certs/tls.key

prerequisites:
  gpuOperator:
    mode: install
    customHelmValues:
      driver:
        enabled: ${DRIVER_ENABLED}
  prometheus:
    mode: install

externalConnection:
  type: ingress
  ingress:
    className: nginx
EOF
chown "${USER_NAME}:${USER_NAME}" "${STATE_DIR}/config.yaml"

log "Waiting for the node and ingress controller."
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=300s || \
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s

log "Running installer preflight."
"${INSTALLER}" install \
  --config "${STATE_DIR}/config.yaml" \
  --preflight-only \
  --logs-dir "${STATE_DIR}/logs"

if [[ "${APPLY}" -eq 0 ]]; then
  echo
  echo "Preflight finished. Kubernetes context: ${USER_HOME}/.kube/config"
  echo "Installer config: ${STATE_DIR}/config.yaml"
  echo "To install NVIDIA Run:ai, rerun this script with --apply."
  exit 0
fi

"${INSTALLER}" install \
  --config "${STATE_DIR}/config.yaml" \
  --logs-dir "${STATE_DIR}/logs"

echo
echo "UI: https://${DOMAIN}"
kubectl get pods -n runai-backend
kubectl get pods -n runai
echo "Admin user:"
kubectl get configmap runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_USERNAME}'; echo
echo "Admin password:"
kubectl get secret runai-backend-gen-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d; echo
