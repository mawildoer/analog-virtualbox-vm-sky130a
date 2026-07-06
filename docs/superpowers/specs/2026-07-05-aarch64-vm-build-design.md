# aarch64 VM built alongside the x86-64 VM — Design

**Date:** 2026-07-05
**Status:** Implemented, with a build-venue change (see Addendum)

> ## Addendum (2026-07-06): arm64 build moved from CI to a local Mac build
>
> **What changed and why.** The design assumed CI would build the arm64 image on a
> free `ubuntu-24.04-arm` runner with native KVM. On first CI run, the `build-arm64`
> job failed immediately at "Enable KVM group perms": **GitHub's free arm64 hosted
> runners do not expose `/dev/kvm`** (no nested virtualization on arm64 runners; only
> x86 runners have it). So QEMU could only fall back to slow TCG emulation, which for
> a full autoinstall + from-source tool builds would likely exceed the 6-hour job cap.
>
> **New approach (chosen by the user).** The arm64 qcow2 is now built **locally on an
> Apple Silicon Mac** using QEMU + Hypervisor.framework (`accel=hvf`, native speed).
> - `image.pkr.hcl`: the qemu source is parameterized with `var.qemu_accel` (default
>   `hvf`) and `var.efi_code_path` (default the Homebrew edk2 path), so it works on the
>   Mac and can still target an arm64-Linux-with-KVM host via `-var` overrides.
> - `scripts/build_arm64_local.sh`: wrapper that locates the edk2 firmware, prepares
>   the writable NVRAM (`AAVMF_VARS.fd`), and runs `packer build -only=qemu…`.
> - CI: the `build-arm64` job and the publish job's arm64 lines were **removed**; CI
>   again builds only the x86 OVA. A comment in the workflow documents how to restore
>   the CI job if GitHub ever enables KVM on arm64 runners.
> - Everything else in this design (the qemu source shape, UEFI/ESP autoinstall,
>   LibreLane, guest tools, arch-aware KLayout) is unchanged — only the *venue* moved.
>
> The sections below describe the original design; read them with the venue change above
> in mind (CI ARM runner → local Mac HVF build).

## Goal

Produce an **aarch64 (arm64) Linux VM image** that runs natively on Apple Silicon
Macs, built **alongside** the existing x86-64 VirtualBox OVA. The x86-64 build must
remain untouched and proven; all changes are additive.

## Locked decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Target hypervisor on the Mac | **UTM (QEMU)** | Free, native ARM64 via macOS Virtualization framework, imports a qcow2 directly. |
| ARM build format | **qcow2** via Packer `qemu` builder | Native UTM import; the qemu builder is the standard way to produce ARM guests. |
| CI build host | **GitHub `ubuntu-24.04-arm` runner** | Free for public repos; native KVM → build time comparable to the current x86 build (~30 min) instead of many hours under emulation. |
| Digital flow on ARM | **LibreLane** (native Nix), replacing OpenLane | `efabless/openlane` Docker image is amd64-only; LibreLane officially supports `aarch64-linux` via Nix with the FOSSi binary cache, avoiding Docker/amd64 emulation. |
| LibreLane scope | **ARM image only** | Keep the proven x86-64 OpenLane flow unchanged; narrow blast radius. |
| Guest tooling on ARM | `qemu-guest-agent` + `spice-vdagent` | Replaces VirtualBox Guest Additions, which do not meaningfully support ARM Linux guests. |

## Why not "just duplicate the source block"

The current pipeline uses the Packer `virtualbox-iso` builder → OVA. VirtualBox is
effectively x86-only (the Apple Silicon build is an immature dev preview with no real
ARM Guest Additions), and the builder itself depends on VirtualBox on the build host.
An aarch64 guest therefore requires a **different builder (`qemu`), a different disk
format (qcow2), different guest tooling, and a different CI runner** — not a duplicated
`source` block.

## Architecture — Packer structure

**One `image.pkr.hcl`** with two `source` blocks and a single `build` block. Divergent
provisioners are gated with Packer's `only`. This keeps the expensive, shared content
(version pins + from-source tool builds) as a single source of truth.

```hcl
locals {
  cpus       = 4
  memory     = 8192
  disk_size  = 32768
  # ...ssh creds, boot_command, shutdown_command, http_directory shared values
}

source "virtualbox-iso" "tinytapeout_analog_vm"      { ... }   # UNCHANGED behavior
source "qemu"           "tinytapeout_analog_vm_arm64" { ... }   # NEW

build {
  sources = [
    "source.virtualbox-iso.tinytapeout_analog_vm",
    "source.qemu.tinytapeout_analog_vm_arm64",
  ]

  # --- shared provisioners (no `only`) ---
  #   apt update/upgrade + ubuntu-desktop-minimal
  #   vminfo.json, wallpaper
  #   env { all version pins } scripts = [ install_pdk, install_verilator,
  #        install_klayout (arch-aware), install_magic, install_netgen,
  #        install_ngspice, install_xschem, install_gaw,
  #        terminal_icon, set_wallpaper ]

  # --- x86-64 only ---
  provisioner "shell" {
    only    = ["virtualbox-iso.tinytapeout_analog_vm"]
    scripts = ["scripts/install_virtualbox_tools.sh", "scripts/install_openlane.sh"]
  }

  # --- arm64 only ---
  provisioner "shell" {
    only    = ["qemu.tinytapeout_analog_vm_arm64"]
    scripts = ["scripts/install_qemu_tools.sh", "scripts/install_librelane.sh"]
  }
}
```

### What is shared vs duplicated

- **Shared, single copy:** all version pins (`env`), all from-source install scripts
  (magic, netgen, ngspice, xschem, gaw, verilator, pdk, terminal_icon, set_wallpaper),
  the arch-aware KLayout script, desktop/wallpaper/vminfo provisioners.
- **Divergent, irreducible:** the two `source` blocks (different builders — common
  values hoisted to `locals`, ~15 divergent lines each), one guest-tools script per
  image, OpenLane vs LibreLane, and the arm64 `user-data` storage stanza (UEFI ESP vs
  BIOS `bios_grub`).

## Component detail

### 1. `qemu` source block (new)

- `qemu_binary   = "qemu-system-aarch64"`
- `machine_type  = "virt"` (arm64 has no PC machine type)
- `accelerator   = "kvm"` (native on the ARM runner; the ARM Mac later uses HVF via UTM)
- **UEFI firmware:** arm64 boots via UEFI → supply edk2/AAVMF pflash
  (`/usr/share/AAVMF/AAVMF_CODE.fd` + a writable vars copy) via `efi_boot`/`qemuargs`.
- `format = "qcow2"`, `disk_interface = "virtio"`, `net_device = "virtio-net-pci"`.
- `cpus`, `memory`, `disk_size`, `ssh_*`, `http_directory`, `shutdown_command` pulled
  from `locals`.
- **ISO:** `ubuntu-22.04.x-live-server-arm64.iso` (from `old-releases.ubuntu.com`, to
  match the pinned 22.04 line). Exact point release + SHA256 confirmed at implementation.
- `boot_command`: adapted from the existing GRUB `autoinstall` command for UEFI GRUB.
- `vm_name = "tinytapeout_analog_vm_arm64"`, output → `output-.../....qcow2`.

### 2. Guest tooling — `scripts/install_qemu_tools.sh` (new, ~10 lines)

```sh
sudo apt-get install -y qemu-guest-agent spice-vdagent
sudo systemctl enable qemu-guest-agent spice-vdagentd
```

Gives clipboard/display integration under UTM; replaces VBox Guest Additions.

### 3. Arch-aware KLayout — `scripts/install_klayout.sh` (edit)

Current script hardcodes `klayout_$KLAYOUT_VERSION-1_amd64.deb`. Make it branch on
`dpkg --print-architecture`:
- **amd64:** unchanged (download the pinned `_amd64.deb`).
- **arm64:** install KLayout for ARM. Preferred: the official arm64 `.deb` at the
  pinned version if published; fallback: the Ubuntu `apt` package (`klayout`), noting
  the version may differ from the pin. Exact source confirmed at implementation.

### 4. LibreLane — `scripts/install_librelane.sh` (new)

Replaces `install_openlane.sh` on ARM. Steps:
1. Install Nix non-interactively **with the FOSSi cache preconfigured**:
   ```sh
   curl --proto '=https' --tlsv1.2 -fsSL https://artifacts.nixos.org/nix-installer | \
     sh -s -- install --no-confirm --extra-conf \
     "extra-substituters = https://nix-cache.fossi-foundation.org
      extra-trusted-public-keys = nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=
      extra-experimental-features = nix-command flakes"
   ```
2. `git clone` LibreLane at a pinned tag (new `LIBRELANE_VERSION` env var).
3. Warm the tool cache (e.g. `nix-shell --run true` in the repo) so first launch in the
   VM is fast, and add a desktop/terminal entry to enter the LibreLane shell.

**Verification gate (implementation):** confirm the FOSSi cache serves `aarch64-linux`
binaries (their headline "native Apple Silicon" is `aarch64-darwin`, which is *not* a
Linux ARM guest). If `aarch64-linux` is **not** cached, Nix would build OpenROAD/Yosys/
etc. from source (hours). Fallback in that case: run OpenLane via Docker amd64
emulation on the ARM image (the original "include, emulated" option).

### 5. Autoinstall — `http/user-data` + `http-arm64/user-data` (new arm64 variant)

arm64 is UEFI, so the arm64 `user-data` storage stanza replaces the `bios_grub`
partition with an **EFI System Partition** (fat32, mounted at `/boot/efi`). Everything
else (identity, packages, ssh, late-commands) is identical. Kept as a second file
rather than a templated one — the UEFI-vs-BIOS layout is a genuine semantic difference
and templating cloud-init YAML is error-prone. The qemu `source` points
`http_directory` at `http-arm64/`.

### 6. CI — `.github/workflows/build_vm.yml`

- **Existing `build` job (x86):** unchanged except the build command becomes
  `packer build -only=virtualbox-iso.tinytapeout_analog_vm ./image.pkr.hcl` so the new
  qemu source is not attempted on the x86 runner. Output/artifact names unchanged.
- **New `build-arm64` job:** `runs-on: ubuntu-24.04-arm`. Steps: enable KVM perms,
  free disk space, `apt-get install qemu-system-arm qemu-utils` + edk2/AAVMF firmware,
  setup packer, `packer init`, write `vminfo.json`, then
  `packer build -only=qemu.tinytapeout_analog_vm_arm64 ./image.pkr.hcl`. Optionally
  `qemu-img convert -c` to compress the qcow2. Upload as artifact
  `tt_analog_qemu_qcow2`.
- **`publish` job:** additionally downloads the arm64 artifact, generates its SHA256,
  and uploads `tinytapeout_analog_vm_arm64.qcow2` (+ `.json` + `.sha256`) to the same R2
  bucket alongside the OVA.

### 7. Docs — `README.md`

Add an "Apple Silicon / arm64" section: download link for the qcow2, and UTM import
steps (New VM → Virtualize → Linux → import existing qcow2, or open the disk image).
Note the same `ttuser` / `magic` credentials.

## Testing / verification

- **CI is the integration test:** both jobs must produce their artifacts. A green
  `build-arm64` job proves the ARM autoinstall + all tool installs succeed end-to-end.
- **Manual smoke test (documented, run by maintainer):** import the qcow2 into UTM on an
  Apple Silicon Mac, boot, and confirm the desktop launches and Magic / KLayout / Xschem
  / ngspice open. LibreLane: confirm `nix-shell` enters and a trivial flow runs (or, in
  the fallback path, that emulated OpenLane pulls).
- The x86-64 OVA build is unchanged; its existing green build is the regression guard.

## Risks

1. **FOSSi cache `aarch64-linux` coverage** (highest) — mitigated by the verification
   gate + emulated-OpenLane fallback above.
2. **KLayout arm64 packaging** — pinned `.deb` may not exist for arm64; fallback to the
   distro package with a possible version drift, documented in the script.
3. **ARM runner availability/quotas** — `ubuntu-24.04-arm` is free for public repos;
   if the repo were private this would incur cost (not the case here).
4. **arm64 UEFI boot_command drift** — the autoinstall GRUB interaction may need tuning
   vs the BIOS path; caught by the CI job failing fast.

## Out of scope

- Migrating the x86-64 image to LibreLane.
- Packaging the ARM image as a `.utm` bundle (qcow2 + import instructions is sufficient).
- VMware Fusion / Parallels / VirtualBox-ARM targets.
