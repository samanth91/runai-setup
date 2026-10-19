#!/bin/bash
# Build open-source NVIDIA Run:ai into a local Kind cluster.
# On Linux with a working NVIDIA driver, the host GPU is passed into one worker.
# Otherwise the upstream local-dev.sh simulated GPUs are used.
#
# Run as your desktop user, not as root:
#   make local
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/os.sh"
detect_os
# shellcheck disable=SC1091
. "${HERE}/lib/common.sh"

if [[ "$(id -u)" -eq 0 ]]; then
  die "Run this script as your desktop user. It will call sudo when it needs root."
fi
require_supported_family
print_os
runai_plan

if has_nvidia_gpu && ! has_nvidia_driver; then
  die "Install the NVIDIA driver for ${OS_PRETTY} before continuing."
fi

BIN="${HOME}/.local/bin"
SRC="${RUNAI_SRC:-${HOME}/src/run-ai}"
PARALLEL="${PARALLEL:-}"
DOMAIN="${RUNAI_DOMAIN:-runai.local}"
mkdir -p "${BIN}" "${HOME}/src"
export PATH="${BIN}:${PATH}"

if [[ -z "${PARALLEL}" ]]; then
  PARALLEL="$(default_parallel)"
fi

if [[ "${OS_FAMILY}" == "macos" ]]; then
  bash "${HERE}/01-prerequisites.sh"
else
  sudo bash "${HERE}/01-prerequisites.sh"
fi

if ! docker info >/dev/null 2>&1; then
  if [[ "${OS_FAMILY}" == "macos" ]]; then
    die "Docker is not reachable. Open Docker Desktop, wait until it is running, then run: make local"
  fi
  if id -nG | grep -qw docker; then
    die "Docker is installed and you are in the docker group, but the daemon is not reachable. Start it and rerun."
  fi
  die "This shell cannot talk to Docker yet. Open a new login shell, or run: sg docker -c 'make -C ${HERE} local'"
fi

download() {
  local dest="$1" url="$2"
  if [[ -x "${dest}" ]]; then
    return 0
  fi
  curl -fsSL -o "${dest}" "${url}"
  chmod +x "${dest}"
}

case "${OS_KERNEL}" in
  Linux) KIND_OS="linux"; HELM_OS="linux"; K9S_OS="Linux" ;;
  Darwin) KIND_OS="darwin"; HELM_OS="darwin"; K9S_OS="Darwin" ;;
  *) die "Unsupported kernel ${OS_KERNEL}" ;;
esac

download "${BIN}/kind" "https://kind.sigs.k8s.io/dl/v0.33.0/kind-${KIND_OS}-${OS_ARCH}"
if ! command -v kubectl >/dev/null 2>&1; then
  kver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  download "${BIN}/kubectl" "https://dl.k8s.io/release/${kver}/bin/${KIND_OS}/${OS_ARCH}/kubectl"
fi
if ! command -v helm >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/helm.tgz" "https://get.helm.sh/helm-v3.19.0-${HELM_OS}-${OS_ARCH}.tar.gz"
  tar -xzf "${tmp}/helm.tgz" -C "${tmp}" "${HELM_OS}-${OS_ARCH}/helm"
  mv "${tmp}/${HELM_OS}-${OS_ARCH}/helm" "${BIN}/helm"
  chmod +x "${BIN}/helm"
  rm -rf "${tmp}"
fi
if ! command -v k9s >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/k9s.tar.gz" "https://github.com/derailed/k9s/releases/download/v0.51.0/k9s_${K9S_OS}_${OS_ARCH}.tar.gz"
  tar -xzf "${tmp}/k9s.tar.gz" -C "${tmp}" k9s
  mv "${tmp}/k9s" "${BIN}/k9s"
  chmod +x "${BIN}/k9s"
  rm -rf "${tmp}"
fi

touch "${HOME}/.gitconfig"
if [[ ! -x "${SRC}/local-dev.sh" ]]; then
  git clone --depth 1 https://github.com/dsx-ai-factory/run-ai.git "${SRC}"
fi

if ! grep -qF "${DOMAIN}" /etc/hosts; then
  echo "127.0.0.1 ${DOMAIN}" | sudo tee -a /etc/hosts >/dev/null
fi

cd "${SRC}"
if [[ "${OS_FAMILY}" != "macos" ]] && has_nvidia_driver; then
  log "Using the host NVIDIA driver. The GPU Operator will not replace it."
  exec ./local-dev.sh --gpu-operator --parallel "${PARALLEL}" --domain "${DOMAIN}"
fi
log "Using simulated GPUs."
exec ./local-dev.sh --parallel "${PARALLEL}" --domain "${DOMAIN}"
