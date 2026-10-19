#!/bin/bash
# Feed sample os-release files through the classifier. No root and no packages.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/../lib/os.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

write_release() {
  local name="$1"
  cat > "${tmp}/${name}"
}

expect() {
  local file="$1" family="$2" distro="$3" codename="$4"
  OS_RELEASE_FILE="${tmp}/${file}"
  unset ID ID_LIKE VERSION_CODENAME UBUNTU_CODENAME VERSION_ID PRETTY_NAME
  # shellcheck disable=SC1090
  . "${OS_RELEASE_FILE}"
  classify_linux_family "${ID}" "${ID_LIKE:-}" "${VERSION_CODENAME:-}" "${UBUNTU_CODENAME:-}"
  if [[ "${OS_FAMILY}" != "${family}" || "${DOCKER_CHANNEL_DISTRO}" != "${distro}" || "${DOCKER_CODENAME}" != "${codename}" ]]; then
    echo "FAIL ${file}: got family=${OS_FAMILY} distro=${DOCKER_CHANNEL_DISTRO} codename=${DOCKER_CODENAME}" >&2
    echo "     wanted family=${family} distro=${distro} codename=${codename}" >&2
    exit 1
  fi
  echo "ok ${file} -> ${OS_FAMILY} ${DOCKER_CHANNEL_DISTRO} ${DOCKER_CODENAME}"
}

write_release pop <<'EOF'
ID=pop
ID_LIKE="ubuntu debian"
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble
EOF
write_release ubuntu <<'EOF'
ID=ubuntu
ID_LIKE=debian
VERSION_CODENAME=jammy
UBUNTU_CODENAME=jammy
EOF
write_release debian <<'EOF'
ID=debian
ID_LIKE=
VERSION_CODENAME=bookworm
EOF
write_release fedora <<'EOF'
ID=fedora
ID_LIKE=
VERSION_CODENAME=
EOF
write_release rhel <<'EOF'
ID=rhel
ID_LIKE="fedora"
VERSION_CODENAME=
EOF
write_release arch <<'EOF'
ID=arch
ID_LIKE=
EOF
write_release suse <<'EOF'
ID=opensuse-tumbleweed
ID_LIKE="suse"
EOF

expect pop debian ubuntu noble
expect ubuntu debian ubuntu jammy
expect debian debian debian bookworm
expect fedora rhel fedora ""
expect rhel rhel centos ""
expect arch arch "" ""
expect suse suse "" ""

OS_RELEASE_FILE=/etc/os-release
detect_os
[[ "${OS_FAMILY}" != "unsupported" ]]
[[ "${OS_ARCH}" == "amd64" || "${OS_ARCH}" == "arm64" ]]
echo "live host: ${OS_PRETTY} family=${OS_FAMILY} arch=${OS_ARCH}"
echo "detect_os tests passed"
