#!/usr/bin/env bash
#
# Build the aarch64 (arm64) Tiny Tapeout analog VM image locally on an
# Apple Silicon Mac, using QEMU + Hypervisor.framework (accel=hvf) for native
# speed. This exists because GitHub's free arm64 hosted runners do not provide
# /dev/kvm, so the arm64 image cannot be built in CI (see .github/workflows/build_vm.yml).
#
# Output: output-tinytapeout_analog_vm_arm64/tinytapeout_analog_vm_arm64.qcow2
# which you import into UTM (see README.md).
#
# Usage:
#   scripts/build_arm64_local.sh
#
# Requirements (install with Homebrew):
#   brew install qemu packer
#
set -euo pipefail

# Run from the repo root so relative paths (image.pkr.hcl, http-arm64/, ./AAVMF_VARS.fd)
# resolve the way Packer's qemu source expects.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

# --- Preconditions -----------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || err "This wrapper targets macOS (Apple Silicon). On an arm64 Linux host with KVM, run packer directly with -var qemu_accel=kvm -var efi_code_path=/usr/share/AAVMF/AAVMF_CODE.fd."

if [ "$(sysctl -n kern.hv_support 2>/dev/null || echo 0)" != "1" ]; then
  err "Hypervisor.framework (HVF) is not available on this machine (kern.hv_support != 1)."
fi

command -v qemu-system-aarch64 >/dev/null 2>&1 || err "qemu-system-aarch64 not found. Install it with: brew install qemu"
command -v packer >/dev/null 2>&1 || err "packer not found. Install it with: brew install packer"

# --- Locate the edk2 (UEFI) firmware that Homebrew's qemu ships --------------
# Homebrew qemu provides edk2-aarch64-code.fd (the read-only firmware) and
# edk2-arm-vars.fd (a writable NVRAM template) under its share/qemu directory.
QEMU_SHARE=""
for d in \
  "$(brew --prefix qemu 2>/dev/null)/share/qemu" \
  "$(brew --prefix 2>/dev/null)/share/qemu" \
  "/opt/homebrew/share/qemu" \
  "/usr/local/share/qemu"; do
  if [ -f "$d/edk2-aarch64-code.fd" ]; then
    QEMU_SHARE="$d"
    break
  fi
done
[ -n "$QEMU_SHARE" ] || err "Could not find edk2-aarch64-code.fd in any qemu share directory. Is qemu installed via Homebrew?"

EFI_CODE="$QEMU_SHARE/edk2-aarch64-code.fd"
EFI_VARS_TEMPLATE="$QEMU_SHARE/edk2-arm-vars.fd"
[ -f "$EFI_VARS_TEMPLATE" ] || err "Found firmware code but not the vars template ($EFI_VARS_TEMPLATE)."

# Packer's qemu source references a writable ./AAVMF_VARS.fd in the working dir.
echo "Preparing writable UEFI vars from $EFI_VARS_TEMPLATE ..."
cp "$EFI_VARS_TEMPLATE" ./AAVMF_VARS.fd

echo "Using firmware code: $EFI_CODE"

# vminfo.json is baked into the image; the CI provides a richer one, but for a
# local build a minimal placeholder is fine if one isn't already present.
if [ ! -f vminfo.json ]; then
  printf '{ "arch": "arm64", "build": "local" }\n' > vminfo.json
fi

# --- Build -------------------------------------------------------------------
echo "Initializing Packer plugins ..."
packer init ./image.pkr.hcl

echo "Building the arm64 image with QEMU/HVF (this downloads a ~2 GB ISO and takes ~30-60 min) ..."
packer build \
  -only=qemu.tinytapeout_analog_vm_arm64 \
  -var "qemu_accel=hvf" \
  -var "efi_code_path=$EFI_CODE" \
  ./image.pkr.hcl

echo ""
echo "Done. Image at: output-tinytapeout_analog_vm_arm64/tinytapeout_analog_vm_arm64.qcow2"
echo "Import it into UTM (see README.md: 'Running on Apple Silicon Macs')."
