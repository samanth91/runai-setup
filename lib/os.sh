#!/bin/bash
# OS and architecture detection shared by the Run:ai install scripts.
# Source this file. It does not change the machine.

detect_os() {
  OS_KERNEL="$(uname -s)"
  OS_MACHINE="$(uname -m)"
  case "${OS_MACHINE}" in
    x86_64|amd64) OS_ARCH="amd64" ;;
    aarch64|arm64) OS_ARCH="arm64" ;;
    *) OS_ARCH="unsupported" ;;
  esac

  OS_ID="unknown"
  OS_VERSION="unknown"
  OS_PRETTY="${OS_KERNEL} $(uname -r)"
  OS_FAMILY="unsupported"
  PKG_MGR="none"
  DOCKER_CHANNEL_DISTRO=""
  DOCKER_CODENAME=""

  if [[ "${OS_KERNEL}" == "Darwin" ]]; then
    OS_FAMILY="macos"
    OS_ID="macos"
    OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    OS_PRETTY="macOS ${OS_VERSION}"
    PKG_MGR="brew"
    return 0
  fi

  if [[ "${OS_KERNEL}" != "Linux" ]]; then
    return 0
  fi

  local release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  if [[ ! -r "${release_file}" ]]; then
    return 0
  fi

  # shellcheck disable=SC1090
  . "${release_file}"
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_PRETTY="${PRETTY_NAME:-${OS_ID}}"
  classify_linux_family "${OS_ID}" "${ID_LIKE:-}" "${VERSION_CODENAME:-}" "${UBUNTU_CODENAME:-}"
}

# Map an os-release ID / ID_LIKE pair onto a package family.
classify_linux_family() {
  local id="$1" like="$2" version_codename="$3" ubuntu_codename="$4"
  local blob="${id} ${like}"

  DOCKER_CHANNEL_DISTRO=""
  DOCKER_CODENAME=""

  if [[ "${blob}" == *debian* || "${blob}" == *ubuntu* || "${id}" == "pop" || "${id}" == "linuxmint" || "${id}" == "elementary" ]]; then
    OS_FAMILY="debian"
    PKG_MGR="apt"
    if [[ "${id}" == "debian" ]]; then
      DOCKER_CHANNEL_DISTRO="debian"
      DOCKER_CODENAME="${version_codename}"
    else
      # Pop!_OS, Mint, and elementary publish an Ubuntu codename and use Ubuntu archives.
      DOCKER_CHANNEL_DISTRO="ubuntu"
      DOCKER_CODENAME="${ubuntu_codename:-${version_codename}}"
    fi
  elif [[ "${blob}" == *fedora* || "${blob}" == *rhel* || "${id}" == "amzn" || "${id}" == "centos" || "${id}" == "rocky" || "${id}" == "almalinux" || "${id}" == "ol" ]]; then
    OS_FAMILY="rhel"
    if command -v dnf >/dev/null 2>&1; then
      PKG_MGR="dnf"
    else
      PKG_MGR="yum"
    fi
    if [[ "${id}" == "fedora" ]]; then
      DOCKER_CHANNEL_DISTRO="fedora"
    else
      DOCKER_CHANNEL_DISTRO="centos"
    fi
  elif [[ "${blob}" == *suse* || "${id}" == "opensuse-leap" || "${id}" == "opensuse-tumbleweed" || "${id}" == "sles" ]]; then
    OS_FAMILY="suse"
    PKG_MGR="zypper"
  elif [[ "${blob}" == *arch* || "${id}" == "manjaro" ]]; then
    OS_FAMILY="arch"
    PKG_MGR="pacman"
  else
    OS_FAMILY="unsupported"
    PKG_MGR="none"
  fi
}

print_os() {
  echo "OS: ${OS_PRETTY}"
  echo "  id=${OS_ID} family=${OS_FAMILY} arch=${OS_ARCH} packages=${PKG_MGR}"
  if [[ -n "${DOCKER_CHANNEL_DISTRO}" ]]; then
    echo "  docker_repo=${DOCKER_CHANNEL_DISTRO} ${DOCKER_CODENAME}"
  fi
}

has_nvidia_gpu() {
  if compgen -G /sys/bus/pci/devices/*/vendor >/dev/null 2>&1; then
    grep -qx '0x10de' /sys/bus/pci/devices/*/vendor 2>/dev/null
    return
  fi
  if command -v lspci >/dev/null 2>&1 && lspci -d 10de: >/dev/null 2>&1; then
    lspci -d 10de: | grep -qi nvidia
    return
  fi
  return 1
}

has_nvidia_driver() {
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

require_supported_family() {
  case "${OS_FAMILY}" in
    debian|rhel|suse|arch|macos) return 0 ;;
  esac
  echo "This OS is not supported by these scripts: ${OS_PRETTY} (family=${OS_FAMILY})." >&2
  echo "Supported families: Debian/Ubuntu/Pop!_OS, RHEL/Fedora, openSUSE, Arch, and macOS." >&2
  return 1
}
