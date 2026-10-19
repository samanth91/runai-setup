#!/bin/bash
# Detect the OS, then install NVIDIA Run:ai with the matching package commands.
#
#   make check
#   make local
#   make prerequisites
#   make production
#   make production-apply
#
# The same entry points work without make:
#   ./install.sh --check
#   ./install.sh --mode local
#   ./install.sh --mode production --apply
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/os.sh"
detect_os
# shellcheck disable=SC1091
. "${HERE}/lib/common.sh"

MODE="local"
CHECK_ONLY=0
APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      sed -n '4,13p' "$0"
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

case "${MODE}" in
  local|prerequisites|production) ;;
  *) die "Mode must be local, prerequisites, or production." ;;
esac

echo "NVIDIA Run:ai installer"
print_os
require_supported_family
runai_plan

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  echo "Check only. Nothing was installed."
  exit 0
fi

if has_nvidia_gpu && ! has_nvidia_driver && [[ "${MODE}" != "production" ]]; then
  die "Install the NVIDIA driver for ${OS_PRETTY}, then rerun ./install.sh"
fi

case "${MODE}" in
  prerequisites)
    if [[ "${OS_FAMILY}" == "macos" ]]; then
      bash "${HERE}/01-prerequisites.sh"
    else
      sudo bash "${HERE}/01-prerequisites.sh"
    fi
    ;;
  local)
    exec bash "${HERE}/02-local-kind-cluster.sh"
    ;;
  production)
    if [[ "${OS_FAMILY}" != "debian" && "${OS_FAMILY}" != "rhel" ]]; then
      die "Production kubeadm packages are automated for Debian/Ubuntu/Pop and RHEL/Fedora. This host is ${OS_PRETTY} (${OS_FAMILY}). On this machine run: make local"
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
      if [[ "${APPLY}" -eq 1 ]]; then
        exec bash "${HERE}/03-production-single-node.sh" --apply
      fi
      exec bash "${HERE}/03-production-single-node.sh"
    fi
    if [[ "${APPLY}" -eq 1 ]]; then
      exec sudo bash "${HERE}/03-production-single-node.sh" --apply
    fi
    exec sudo bash "${HERE}/03-production-single-node.sh"
    ;;
esac
