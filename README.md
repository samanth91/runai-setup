# NVIDIA Run:ai host installer

`make` reads the OS and installs Run:ai with that family's package commands.

```bash
make
make check
make local
```

`make` lists the targets. `make check` prints the detected OS, whether an NVIDIA GPU and driver are present, and which install it would run. It does not change the machine.

## MacBook

`make local` on macOS installs Homebrew packages and a Kind cluster with simulated GPUs. Real GPU passthrough from this installer is Linux-only.

1. Install Homebrew from https://brew.sh.
2. If `make` is missing, install the Xcode Command Line Tools: `xcode-select --install`.
3. Open Docker Desktop. In Settings → Resources, give the VM at least 12 GB of memory and 20 GB of free disk. Apple silicon builds linux/amd64 images, so the first run is slow.

```bash
make check
make local
```

`make prerequisites` installs `git`, `python3`, `kubectl`, `helm`, `kind`, and `k9s` with Homebrew, and Docker Desktop if `docker` is not already on the PATH. Start Docker Desktop, then run `make local` again.

`make production` stops on macOS. The kubeadm packages are automated for Debian-family and RHEL-family hosts.

## What the OS check selects

| Detected family | Examples | Packages | Run:ai |
|---|---|---|---|
| debian | Ubuntu, Debian, Pop!_OS, Linux Mint | apt, Docker's Ubuntu or Debian repo | Kind plus the host GPU when `nvidia-smi` works |
| rhel | RHEL, Fedora, Rocky, Alma, Amazon Linux | dnf or yum | Same local install |
| suse | openSUSE, SLES | zypper | Same local install |
| arch | Arch, Manjaro | pacman | Same local install |
| macos | macOS | Homebrew | Kind with simulated GPUs |

A Linux machine with an NVIDIA GPU and a working driver gets `local-dev.sh --gpu-operator`, which keeps the host driver. A machine without a GPU, and every Mac, gets simulated GPUs. If a GPU is present and `nvidia-smi` fails, the script stops so it does not install a second driver.

## Other targets

```bash
make test
make prerequisites
make production
make production-apply
make teardown
```

`production` is the single-node kubeadm path. It refuses to start while the Kind cluster `runai-local` is still up, because both want ports 80 and 443 and the same GPU. Run `make teardown` before `make production`.

`PARALLEL=2 make local` forces two image builds at a time. Hosts under about 24 GB of RAM do that on their own.
