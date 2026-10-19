#!/bin/bash
# Install the container runtime, and the NVIDIA Container Toolkit when this
# machine has a working NVIDIA driver. Package commands follow the detected OS.
#
#   sudo bash 01-prerequisites.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/os.sh"
detect_os
# shellcheck disable=SC1091
. "${HERE}/lib/common.sh"
print_os
require_supported_family

if [[ "${OS_ARCH}" == "unsupported" ]]; then
  die "Unsupported CPU architecture: ${OS_MACHINE}"
fi

if [[ "${OS_FAMILY}" != "macos" && "$(id -u)" -ne 0 ]]; then
  die "Run this script with sudo."
fi

install_debian() {
  export DEBIAN_FRONTEND=noninteractive
  if [[ -z "${DOCKER_CODENAME}" ]]; then
    die "Could not determine the ${DOCKER_CHANNEL_DISTRO} codename from /etc/os-release."
  fi
  apt-get update
  apt-get install -y ca-certificates curl gnupg python3
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${DOCKER_CHANNEL_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_CHANNEL_DISTRO} ${DOCKER_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_nvidia_apt() {
  rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
}

install_rhel() {
  ${PKG_MGR} -y install ca-certificates curl
  if ! ${PKG_MGR} config-manager --add-repo "https://download.docker.com/linux/${DOCKER_CHANNEL_DISTRO}/docker-ce.repo"; then
    ${PKG_MGR} config-manager addrepo --from-repofile="https://download.docker.com/linux/${DOCKER_CHANNEL_DISTRO}/docker-ce.repo"
  fi
  ${PKG_MGR} -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_nvidia_rpm() {
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
    -o /etc/yum.repos.d/nvidia-container-toolkit.repo
  ${PKG_MGR} -y install nvidia-container-toolkit
}

install_suse() {
  zypper --non-interactive refresh
  zypper --non-interactive install -y curl ca-certificates docker python3
  systemctl enable docker
}

install_nvidia_suse() {
  zypper addrepo --refresh https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo nvidia-container-toolkit || true
  zypper --non-interactive --gpg-auto-import-keys refresh
  zypper --non-interactive install -y nvidia-container-toolkit
}

install_arch() {
  pacman -Sy --noconfirm --needed docker curl ca-certificates python
  systemctl enable docker
}

install_nvidia_arch() {
  pacman -Sy --noconfirm --needed nvidia-container-toolkit
}

install_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    die "Homebrew is required on macOS. Install it from https://brew.sh and rerun."
  fi
  brew install kubectl helm kind k9s
  if ! command -v docker >/dev/null 2>&1; then
    brew install --cask docker
    echo "Start Docker Desktop, then rerun the local install."
  fi
}

configure_nvidia_docker() {
  nvidia-ctk runtime configure --runtime=docker --set-as-default
  nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place
  python3 - <<'PY'
import json
from pathlib import Path
p = Path("/etc/docker/daemon.json")
cfg = json.loads(p.read_text()) if p.exists() else {}
cfg.setdefault("features", {})["containerd-snapshotter"] = True
p.write_text(json.dumps(cfg, indent=2) + "\n")
PY
}

raise_kind_sysctls() {
  cat > /etc/sysctl.d/99-runai-kind.conf <<'EOF'
kernel.keys.maxkeys = 800
kernel.keys.maxbytes = 200000
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
  sysctl --system >/dev/null
}

USER_NAME="$(target_user)"

case "${OS_FAMILY}" in
  macos)
    install_macos
    echo "macOS prerequisites are ready. Real GPU passthrough is Linux-only."
    exit 0
    ;;
  debian) install_debian ;;
  rhel) install_rhel ;;
  suse) install_suse ;;
  arch) install_arch ;;
esac

if has_nvidia_gpu && ! has_nvidia_driver; then
  die "An NVIDIA GPU is present, but nvidia-smi failed. Install the ${OS_PRETTY} NVIDIA driver, then rerun."
fi

if has_nvidia_driver; then
  log "Installing the NVIDIA Container Toolkit for ${OS_FAMILY}."
  case "${OS_FAMILY}" in
    debian) install_nvidia_apt ;;
    rhel) install_nvidia_rpm ;;
    suse) install_nvidia_suse ;;
    arch) install_nvidia_arch ;;
  esac
  configure_nvidia_docker
else
  log "No working NVIDIA driver. Skipping the NVIDIA Container Toolkit."
fi

if [[ "${USER_NAME}" != "root" ]]; then
  usermod -aG docker "${USER_NAME}"
fi
raise_kind_sysctls
if ! grep -qF 'runai.local' /etc/hosts; then
  echo '127.0.0.1 runai.local' >> /etc/hosts
fi
systemctl enable docker
systemctl restart docker

if has_nvidia_driver; then
  docker run --rm --gpus all ubuntu:24.04 nvidia-smi
fi
echo "Prerequisites ready on ${OS_PRETTY}."
echo "Open a new shell so the docker group applies, or run commands with: sg docker -c '...'"
