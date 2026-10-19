# NVIDIA Run:ai installer.
# This file stays compatible with GNU make and the macOS BSD make.
# Do not add GNU-only syntax such as ifeq or $(shell).
#
#   make
#   make check
#   make local

.PHONY: help check test install prerequisites local production production-apply teardown

RUNAI_SRC ?= $(HOME)/src/run-ai

help:
	@echo "NVIDIA Run:ai installer"
	@echo ""
	@echo "  make check               Show the OS and the install that would run"
	@echo "  make test                Run the OS detection tests"
	@echo "  make local               Install the local Kind cluster"
	@echo "  make prerequisites       Install the container runtime for this OS"
	@echo "  make install             Same as make local"
	@echo "  make production          Preflight the single-node kubeadm path"
	@echo "  make production-apply    Install the single-node kubeadm path"
	@echo "  make teardown            Remove the local Kind cluster"
	@echo ""
	@echo "On a MacBook: make check"
	@echo "              make local"

check:
	./install.sh --check

test:
	bash tests/detect_os_test.sh

install: local

prerequisites:
	./install.sh --mode prerequisites

local:
	./install.sh --mode local

production:
	./install.sh --mode production

production-apply:
	./install.sh --mode production --apply

teardown:
	cd "$(RUNAI_SRC)" && ./local-dev.sh --teardown
