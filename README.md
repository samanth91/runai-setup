# NVIDIA Run:ai host installer

One entry script reads the OS and installs Run:ai with that family's package commands.

```bash
./install.sh --check
./install.sh
```

`--check` prints the detected OS, whether an NVIDIA GPU and driver are present, and which install it would run. It does not change the machine.

## What the OS check selects

| Detected family | Examples | Packages | Run:ai |
|---|---|---|---|
| debian | Ubuntu, Debian, Pop!_OS, Linux Mint | apt, Docker's Ubuntu or Debian repo | Kind plus the host GPU when `nvidia-smi` works |
| rhel | RHEL, Fedora, Rocky, Alma, Amazon Linux | dnf or yum | Same local install |
| suse | openSUSE, SLES | zypper | Same local install |
| arch | Arch, Manjaro | pacman | Same local install |
| macos | macOS | Homebrew | Kind with simulated GPUs |

A Linux machine with an NVIDIA GPU and a working driver gets `local-dev.sh --gpu-operator`, which keeps the host driver. A machine without a GPU, and every Mac, gets simulated GPUs. If a GPU is present and `nvidia-smi` fails, the script stops so it does not install a second driver.

## Other modes

```bash
./install.sh --mode prerequisites
./install.sh --mode local
sudo ./install.sh --mode production
sudo ./install.sh --mode production --apply
```

`production` is the single-node kubeadm path. Its Kubernetes packages are automated for Debian-family and RHEL-family hosts. It refuses to start while the Kind cluster `runai-local` is still up, because both want ports 80 and 443 and the same GPU.

Run `./local-dev.sh --teardown` from the cloned Run:ai source tree before the production path.
