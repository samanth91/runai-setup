#!/bin/bash
# Helpers shared by the install scripts. Source lib/os.sh first.

if [[ -z "${OS_FAMILY:-}" ]]; then
  echo "Source lib/os.sh and call detect_os before sourcing lib/common.sh." >&2
  return 1 2>/dev/null || exit 1
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}

target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
    return
  fi
  local name
  name="$(logname 2>/dev/null || true)"
  if [[ -n "${name}" && "${name}" != "root" ]]; then
    echo "${name}"
    return
  fi
  echo "${USER:-root}"
}

target_home() {
  local user="$1"
  if command -v getent >/dev/null 2>&1; then
    getent passwd "${user}" | cut -d: -f6
    return
  fi
  # macOS has no getent. Production install does not run there.
  dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
}

# Kind image builds are heavy. Under about 24 GB of RAM, build two at a time.
host_mem_kb() {
  local bytes
  if [[ "${OS_KERNEL}" == "Darwin" ]]; then
    bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    echo $(( bytes / 1024 ))
    return 0
  fi
  awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0
}

default_parallel() {
  local mem_kb
  mem_kb="$(host_mem_kb)"
  if [[ "${mem_kb}" -gt 0 && "${mem_kb}" -lt 24000000 ]]; then
    echo 2
    return 0
  fi
  echo 4
}

runai_plan() {
  local gpu="no" driver="no" mode="local-simulated"
  if has_nvidia_gpu; then
    gpu="yes"
  fi
  if has_nvidia_driver; then
    driver="yes"
  fi

  if [[ "${OS_FAMILY}" == "macos" ]]; then
    mode="local-simulated"
  elif [[ "${gpu}" == "yes" && "${driver}" == "yes" ]]; then
    mode="local-host-gpu"
  elif [[ "${gpu}" == "yes" ]]; then
    mode="blocked-no-driver"
  else
    mode="local-simulated"
  fi

  echo "GPU present: ${gpu}"
  echo "NVIDIA driver working: ${driver}"
  echo "Selected Run:ai install: ${mode}"
  case "${mode}" in
    local-host-gpu)
      echo "  Docker and the NVIDIA Container Toolkit, then a Kind cluster using the host driver."
      ;;
    local-simulated)
      echo "  Container runtime and a Kind cluster with simulated GPUs."
      if [[ "${OS_FAMILY}" == "macos" ]]; then
        echo "  Real GPU passthrough from local-dev.sh is Linux-only."
      fi
      ;;
    blocked-no-driver)
      echo "  An NVIDIA GPU was found, and nvidia-smi does not work."
      echo "  Install the driver from the OS vendor, then rerun this installer."
      ;;
  esac
}
