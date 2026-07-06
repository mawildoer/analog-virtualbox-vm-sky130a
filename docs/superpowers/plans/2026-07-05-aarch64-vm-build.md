# aarch64 VM Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an aarch64 (arm64) Ubuntu VM image — built with Packer's `qemu` builder into a qcow2 for UTM on Apple Silicon — alongside the existing, untouched x86-64 VirtualBox OVA.

**Architecture:** One `image.pkr.hcl` gains a second `qemu` source next to the existing `virtualbox-iso` source; shared tool-install provisioners stay single-source, while divergent provisioners (guest tools, digital flow) are gated with Packer's `only`. A new `ubuntu-24.04-arm` CI job builds the qcow2 natively (KVM), and the publish job uploads it to R2 next to the OVA. The digital flow on arm64 uses LibreLane (native Nix) instead of the amd64-only OpenLane Docker image.

**Tech Stack:** Packer (virtualbox + qemu plugins), QEMU/KVM, Ubuntu 22.04 autoinstall (cloud-init), Bash provisioner scripts, GitHub Actions (arm64 runner), Nix/LibreLane, Cloudflare R2.

**Domain note on "tests":** This is infrastructure. Local verification = `packer fmt`/`packer validate`, `sh -n` shell syntax checks, `python3 -c yaml.safe_load` for cloud-init, and `actionlint` for the workflow. Anything that actually boots an arm64 guest is only verifiable in the `ubuntu-24.04-arm` CI job (and a final manual UTM smoke test) — the plan marks those explicitly. Do **not** invent pytest-style unit tests; they do not fit this domain.

**Reference spec:** `docs/superpowers/specs/2026-07-05-aarch64-vm-build-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `image.pkr.hcl` | Modify | Add qemu plugin + `locals` + `qemu` source; gate divergent provisioners with `only`. |
| `http-arm64/user-data` | Create | arm64 autoinstall config (UEFI/ESP storage layout). |
| `http-arm64/meta-data` | Create | Empty cloud-init meta-data (mirrors `http/meta-data`). |
| `scripts/install_qemu_tools.sh` | Create | Install `qemu-guest-agent` + `spice-vdagent` (arm64 guest integration). |
| `scripts/install_klayout.sh` | Modify | Make arch-aware (amd64 `.deb` vs arm64). |
| `scripts/install_librelane.sh` | Create | Install Nix + FOSSi cache + LibreLane (arm64 digital flow). |
| `.github/workflows/build_vm.yml` | Modify | Constrain x86 job with `-only`; add `build-arm64` job; extend `publish`. |
| `README.md` | Modify | Add Apple Silicon / UTM download + import section. |

---

## Task 0: Resolve deferred external facts

**No files changed.** Record each result inline in the relevant later task (or in commit messages). These were deliberately deferred by the spec because they depend on external state.

- [ ] **Step 1: Confirm the arm64 ISO filename still resolves**

Run:
```bash
curl -sI https://old-releases.ubuntu.com/releases/22.04/ubuntu-22.04.4-live-server-arm64.iso | head -1
curl -s https://old-releases.ubuntu.com/releases/22.04/SHA256SUMS | grep arm64
```
Expected: `HTTP/... 200` and a SHA256SUMS line containing `ubuntu-22.04.4-live-server-arm64.iso`.
If 22.04.4 has been rotated out, pick the highest `ubuntu-22.04.*-live-server-arm64.iso` present in that directory and use it in Task 1 (the `file:` checksum reference auto-tracks it).

- [ ] **Step 2: Confirm the edk2/AAVMF firmware package + path on the arm runner**

The `build-arm64` job runs on `ubuntu-24.04-arm`. Verify the firmware package name and file path (used in Task 1 and Task 6):
```bash
# On an arm64 Ubuntu box (or note for the CI job to check):
apt-get download --print-uris qemu-efi-aarch64 2>/dev/null | head -1
dpkg -L qemu-efi-aarch64 2>/dev/null | grep -E 'AAVMF_(CODE|VARS)\.fd'
```
Expected: package `qemu-efi-aarch64` provides `/usr/share/AAVMF/AAVMF_CODE.fd` and `/usr/share/AAVMF/AAVMF_VARS.fd`. If the paths differ, update the `qemuargs` in Task 1 and the `cp` in Task 6 accordingly.

- [ ] **Step 3: Check KLayout arm64 packaging at the pinned version**

```bash
curl -sI "https://www.klayout.org/downloads/Ubuntu-22/klayout_0.30.3-1_arm64.deb" | head -1
```
If `200`: Task 4 uses that URL for arm64. If `404`: Task 4 falls back to the distro package (`apt-get install -y klayout`), accepting possible version drift from the `0.30.3` pin — this is expected and documented in the script.

- [ ] **Step 4: Verify the FOSSi Nix cache serves `aarch64-linux` (the key spec risk)**

```bash
curl -s https://nix-cache.fossi-foundation.org/nix-cache-info
# Then, once LibreLane is cloned in Task 5, from an arm64 box:
#   nix-shell --run 'true'  → should PULL binaries, not compile OpenROAD/yosys from source.
```
Expected: the cache responds. The definitive check is that `nix-shell` in the LibreLane repo on the arm64 runner pulls prebuilt tools rather than building from source (watch for `building '/nix/store/...openroad...'` lines = source build = FAIL).
**If aarch64-linux is NOT cached:** switch `install_librelane.sh` to the fallback documented in Task 5 (emulated amd64 OpenLane via Docker) and note it in the commit.

- [ ] **Step 5: Pick the LibreLane version tag**

```bash
gh release list --repo librelane/librelane --limit 5
```
Record the latest stable tag as `LIBRELANE_VERSION` for Task 1's `env` block and Task 5.

---

## Task 1: Add qemu plugin, shared locals, qemu source, and gated provisioners

**Files:**
- Modify: `image.pkr.hcl`

- [ ] **Step 1: Add the qemu plugin to `required_plugins`**

In `image.pkr.hcl`, replace the `packer { ... }` block with:
```hcl
packer {
  required_plugins {
    virtualbox = {
      source  = "github.com/hashicorp/virtualbox"
      version = "~> 1"
    }
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}
```

- [ ] **Step 2: Add a `locals` block with values shared by both sources**

Insert directly after the `packer { ... }` block:
```hcl
locals {
  cpus                   = 4
  memory                 = 8192
  disk_size              = 32768
  ssh_username           = "ttuser"
  ssh_password           = "magic"
  ssh_read_write_timeout = "600s"
  ssh_timeout            = "120m"
  shutdown_command       = "sudo shutdown -h now"
  boot_command = [
    "<wait5>c<wait>",
    "set gfxpayload=keep<enter><wait>",
    "linux /casper/vmlinuz <wait>",
    "autoinstall quiet fsck.mode=skip <wait>",
    "net.ifnames=0 biosdevname=0 systemd.unified_cgroup_hierarchy=0 <wait>",
    "ds=\"nocloud-net;s=http://{{.HTTPIP}}:{{.HTTPPort}}/\" <wait>",
    "---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<wait><enter><enter>"
  ]
}
```

- [ ] **Step 3: Point the existing virtualbox source at the shared locals (no behavior change)**

In `source "virtualbox-iso" "tinytapeout_analog_vm"`, replace the literal values for `cpus`, `disk_size`, `memory`, `shutdown_command`, `ssh_password`, `ssh_username`, `ssh_read_write_timeout`, `ssh_timeout`, and `boot_command` with `local.*` references. For example:
```hcl
  boot_command           = local.boot_command
  cpus                   = local.cpus
  disk_size              = local.disk_size
  memory                 = local.memory
  shutdown_command       = local.shutdown_command
  ssh_password           = local.ssh_password
  ssh_read_write_timeout = local.ssh_read_write_timeout
  ssh_timeout            = local.ssh_timeout
  ssh_username           = local.ssh_username
```
Leave everything else in the virtualbox source (iso_url, guest_additions, gfx_*, vboxmanage, vrdp_*, format, guest_os_type, http_directory, boot_wait) exactly as-is.

- [ ] **Step 4: Add the new qemu source block**

After the virtualbox source block, add:
```hcl
source "qemu" "tinytapeout_analog_vm_arm64" {
  vm_name          = "tinytapeout_analog_vm_arm64.qcow2"
  qemu_binary      = "qemu-system-aarch64"
  machine_type     = "virt"
  accelerator      = "kvm"
  format           = "qcow2"
  disk_interface   = "virtio"
  disk_size        = local.disk_size
  net_device       = "virtio-net-pci"
  cpus             = local.cpus
  memory           = local.memory
  headless         = true
  http_directory   = "./http-arm64"
  iso_url          = "https://old-releases.ubuntu.com/releases/22.04/ubuntu-22.04.4-live-server-arm64.iso"
  iso_checksum     = "file:https://old-releases.ubuntu.com/releases/22.04/SHA256SUMS"
  boot_wait        = "5s"
  boot_command     = local.boot_command
  shutdown_command = local.shutdown_command
  ssh_username     = local.ssh_username
  ssh_password     = local.ssh_password
  ssh_timeout      = local.ssh_timeout
  ssh_read_write_timeout = local.ssh_read_write_timeout
  qemuargs = [
    ["-cpu", "host"],
    ["-machine", "virt,gic-version=max"],
    ["-drive", "if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd"],
    ["-drive", "if=pflash,format=raw,file=AAVMF_VARS.fd"],
    ["-device", "virtio-gpu-pci"]
  ]
}
```
Note: `AAVMF_VARS.fd` is a writable copy created in the build working directory by the CI job (Task 6). `machine_type` + the `-machine` qemuarg overlap is intentional — the qemuarg sets `gic-version`.

- [ ] **Step 5: Update the `build` block to list both sources and gate divergent provisioners**

Change `sources` to:
```hcl
  sources = [
    "source.virtualbox-iso.tinytapeout_analog_vm",
    "source.qemu.tinytapeout_analog_vm_arm64",
  ]
```
Keep the shared provisioners (the apt `shell`, the two `file` provisioners, and the big `env`+`scripts` shell provisioner) **without** an `only`, but **remove** `install_virtualbox_tools.sh` and `install_openlane.sh` from that shared `scripts` list. The shared `scripts` list becomes:
```hcl
    scripts = [
      "scripts/install_pdk.sh",
      "scripts/install_verilator.sh",
      "scripts/install_klayout.sh",
      "scripts/install_magic.sh",
      "scripts/install_netgen.sh",
      "scripts/install_ngspice.sh",
      "scripts/install_xschem.sh",
      "scripts/install_gaw.sh",
      "scripts/terminal_icon.sh",
      "scripts/set_wallpaper.sh",
    ]
```
Add `LIBRELANE_VERSION = "<tag from Task 0 Step 5>"` to that provisioner's `env` map (alongside the existing version pins).

Then add two gated provisioners at the end of the `build` block:
```hcl
  provisioner "shell" {
    only    = ["virtualbox-iso.tinytapeout_analog_vm"]
    scripts = [
      "scripts/install_virtualbox_tools.sh",
      "scripts/install_openlane.sh",
    ]
  }

  provisioner "shell" {
    only = ["qemu.tinytapeout_analog_vm_arm64"]
    env = {
      LIBRELANE_VERSION = "<tag from Task 0 Step 5>"
    }
    scripts = [
      "scripts/install_qemu_tools.sh",
      "scripts/install_librelane.sh",
    ]
  }
```

- [ ] **Step 6: Format and validate**

Run:
```bash
packer fmt image.pkr.hcl
packer init image.pkr.hcl
packer validate image.pkr.hcl
```
Expected: `packer validate` prints `The configuration is valid.` (It validates HCL + plugin schema for both sources without booting anything. The `qemu-efi` firmware file need not exist locally for `validate` to pass.)

- [ ] **Step 7: Commit**

```bash
git add image.pkr.hcl
git commit -m "feat: add qemu arm64 source alongside virtualbox in packer config"
```

---

## Task 2: arm64 autoinstall config

**Files:**
- Create: `http-arm64/user-data`
- Create: `http-arm64/meta-data`

- [ ] **Step 1: Create the empty meta-data file**

`http-arm64/meta-data` — create it empty (matches `http/meta-data`):
```bash
: > http-arm64/meta-data
```

- [ ] **Step 2: Create the arm64 user-data (UEFI/ESP storage layout)**

Create `http-arm64/user-data`. It is identical to `http/user-data` **except** the `storage.config` list replaces the BIOS `bios_grub` partition with a fat32 EFI System Partition mounted at `/boot/efi`:
```yaml
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  refresh-installer:
      update: yes
  keyboard:
      layout: us
  network:
      network:
          version: 2
          ethernets:
              eth0:
                 dhcp4: yes
  apt:
      primary:
          - arches: [default]
            uri: http://ports.ubuntu.com/ubuntu-ports/
  storage:
      swap:
          size: 0
      config:
          - { type: disk, id: disk-0, ptable: gpt, wipe: superblock-recursive, grub_device: true }
          - { type: partition, id: partition-0, number: 1, device: disk-0, size: 512M, wipe: superblock, flag: boot, grub_device: true }
          - { type: partition, id: partition-1, number: 2, device: disk-0, size: 400M, wipe: superblock }
          - { type: partition, id: partition-2, number: 3, device: disk-0, size: 4096M, wipe: superblock, flag: swap }
          - { type: partition, id: partition-3, number: 4, device: disk-0, size: -1, wipe: superblock }
          - { type: format, id: format-efi, volume: partition-0, fstype: fat32 }
          - { type: format, id: format-boot, volume: partition-1, fstype: ext4 }
          - { type: format, id: format-swap, volume: partition-2, fstype: swap }
          - { type: format, id: format-root, volume: partition-3, fstype: ext4 }
          - { type: mount, id: mount-efi, device: format-efi, path: /boot/efi }
          - { type: mount, id: mount-boot, device: format-boot, path: /boot }
          - { type: mount, id: mount-swap, device: format-swap, path: none }
          - { type: mount, id: mount-root, device: format-root, path: / }
  identity:
      realname: 'Tiny Tapeout User'
      username: ttuser
      password: '$6$R0qxzPSbPU5Ynr$Gq2DzboPGHyQw8BmzjakviAK0fvdRS6c6V9WGmIqA5pI/bCWX782kHqGZcJs6vIbLtgVUlxLPH9zmW9eXpqej1'
      hostname: ubuntu-desktop
  ssh:
      install-server: yes
      authorized-keys: []
      allow-pw: yes
  packages:
      - ca-certificates
      - open-vm-tools
      - openssh-server
      - net-tools
      - curl
      - sudo
      - software-properties-common
      - apt-transport-https
      - lsb-release
  early-commands:
    - systemctl stop ssh.service
    - systemctl stop ssh.socket
  late-commands:
      - echo 'ttuser ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/ttuser
      - |
        cat > /target/etc/systemd/network/20-dhcp.network << EOF
        [Match]
        Name=enp*

        [Network]
        DHCP=ipv4
        EOF
      - |
        curtin in-target --target=/target -- /bin/bash -c ' \
            exit 0 \
        '
```
Notes baked in above: (a) arm64 uses `http://ports.ubuntu.com/ubuntu-ports/` as the apt primary instead of `archive.ubuntu.com`; (b) the ESP is fat32 with `flag: boot` and `grub_device: true`; (c) a separate `/boot` ext4 partition is retained to mirror the amd64 layout.

- [ ] **Step 3: Validate the YAML parses**

Run:
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('http-arm64/user-data')); print('user-data OK')"
```
Expected: `user-data OK`.

- [ ] **Step 4: Sanity-diff against the amd64 user-data**

Run:
```bash
diff <(grep -vE 'archive.ubuntu.com|ports.ubuntu.com' http/user-data) \
     <(grep -vE 'archive.ubuntu.com|ports.ubuntu.com' http-arm64/user-data) || true
```
Expected: the only differences are within the `storage.config` block (ESP vs bios_grub). Confirm identity/packages/ssh/late-commands are unchanged.

- [ ] **Step 5: Commit**

```bash
git add http-arm64/user-data http-arm64/meta-data
git commit -m "feat: add arm64 autoinstall config with UEFI ESP layout"
```

---

## Task 3: arm64 guest tools script

**Files:**
- Create: `scripts/install_qemu_tools.sh`

- [ ] **Step 1: Write the script**

Create `scripts/install_qemu_tools.sh`:
```sh
#! /bin/sh

set -e

# Guest integration for QEMU/UTM: replaces VirtualBox Guest Additions on arm64.
# - qemu-guest-agent: graceful shutdown, host/guest coordination
# - spice-vdagent:    clipboard sharing and dynamic display resize under UTM
sudo apt-get install -y qemu-guest-agent spice-vdagent

sudo systemctl enable qemu-guest-agent
sudo systemctl enable spice-vdagentd

# Verify the agent binary is present
command -v qemu-ga
```

- [ ] **Step 2: Syntax-check**

Run:
```bash
sh -n scripts/install_qemu_tools.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Commit**

```bash
git add scripts/install_qemu_tools.sh
git commit -m "feat: add qemu-guest-agent/spice guest tools script for arm64"
```

---

## Task 4: Make KLayout install arch-aware

**Files:**
- Modify: `scripts/install_klayout.sh`

- [ ] **Step 1: Replace the download lines with an arch branch**

In `scripts/install_klayout.sh`, replace these three lines:
```sh
curl -o /tmp/klayout.deb https://www.klayout.org/downloads/Ubuntu-22/klayout_$KLAYOUT_VERSION-1_amd64.deb
sudo apt-get install -y /tmp/klayout.deb
rm /tmp/klayout.deb
```
with:
```sh
ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" = "amd64" ]; then
  curl -o /tmp/klayout.deb "https://www.klayout.org/downloads/Ubuntu-22/klayout_$KLAYOUT_VERSION-1_amd64.deb"
  sudo apt-get install -y /tmp/klayout.deb
  rm /tmp/klayout.deb
elif [ "$ARCH" = "arm64" ]; then
  # Prefer the pinned arm64 .deb if KLayout publishes one (see Task 0 Step 3);
  # otherwise fall back to the distro package (version may differ from the pin).
  ARM_DEB_URL="https://www.klayout.org/downloads/Ubuntu-22/klayout_$KLAYOUT_VERSION-1_arm64.deb"
  if curl -fsIL "$ARM_DEB_URL" >/dev/null 2>&1; then
    curl -o /tmp/klayout.deb "$ARM_DEB_URL"
    sudo apt-get install -y /tmp/klayout.deb
    rm /tmp/klayout.deb
  else
    echo "No arm64 .deb for KLayout $KLAYOUT_VERSION; installing distro package instead."
    sudo apt-get install -y klayout
  fi
else
  echo "Unsupported architecture for KLayout: $ARCH" >&2
  exit 1
fi
```
Leave the desktop-icon section (everything after the download) unchanged.

- [ ] **Step 2: Syntax-check**

Run:
```bash
sh -n scripts/install_klayout.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Verify the amd64 branch is byte-equivalent behavior**

Confirm by reading that on `amd64` the exact original three commands run (same URL, same install, same cleanup) — this guarantees the untouched x86 build is unaffected.

- [ ] **Step 4: Commit**

```bash
git add scripts/install_klayout.sh
git commit -m "feat: make klayout install script arch-aware (amd64/arm64)"
```

---

## Task 5: LibreLane install script (arm64 digital flow)

**Files:**
- Create: `scripts/install_librelane.sh`

- [ ] **Step 1: Write the primary (native Nix) script**

Create `scripts/install_librelane.sh`:
```sh
#! /bin/sh

set -e

# LibreLane (successor to OpenLane 2) runs the EDA tools as native arm64 binaries
# via Nix + the FOSSi binary cache, avoiding amd64 Docker emulation.
# LIBRELANE_VERSION is provided by the packer provisioner env.

# 1. Install Nix non-interactively with the FOSSi cache preconfigured.
curl --proto '=https' --tlsv1.2 -fsSL https://artifacts.nixos.org/nix-installer | \
  sh -s -- install linux --no-confirm --extra-conf \
  "extra-substituters = https://nix-cache.fossi-foundation.org
   extra-trusted-public-keys = nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=
   extra-experimental-features = nix-command flakes"

# Make nix available in this non-login shell.
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

# 2. Clone LibreLane at the pinned tag.
git clone --depth=1 --branch "$LIBRELANE_VERSION" \
  https://github.com/librelane/librelane.git "$HOME/librelane"

# 3. Warm the tool cache so first use in the VM is fast (pulls prebuilt arm64 tools).
cd "$HOME/librelane"
nix-shell --run 'librelane --version || true'

# 4. Persist a convenience entry point.
echo 'export LIBRELANE_ROOT=$HOME/librelane' >> "$HOME/.profile"
cat > "$HOME/Desktop/librelane.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=LibreLane Shell
Comment=Open a terminal inside the LibreLane Nix environment
Exec=gnome-terminal --working-directory=/home/ttuser/librelane -- nix-shell
Icon=utilities-terminal
Terminal=false
Categories=Development;
EOF
gio set "$HOME/Desktop/librelane.desktop" metadata::trusted true || true
chmod a+x "$HOME/Desktop/librelane.desktop"
```

- [ ] **Step 2: Syntax-check**

Run:
```bash
sh -n scripts/install_librelane.sh && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 3: Record the fallback (only used if Task 0 Step 4 fails)**

If the FOSSi cache does **not** serve `aarch64-linux`, do NOT ship the Nix script above (it would compile every EDA tool from source — hours). Instead replace the body with the emulated-OpenLane fallback, which reuses the existing `install_openlane.sh` under Docker's amd64 emulation:
```sh
#! /bin/sh
set -e
# FALLBACK: FOSSi cache has no aarch64-linux binaries, so run the amd64 OpenLane
# image under Docker emulation (binfmt/qemu). Slower but functional.
sudo apt-get install -y qemu-user-static binfmt-support
export OPENLANE_TAG="${OPENLANE_TAG:-2024.05.09}"
# Reuse the existing OpenLane installer; Docker pulls the amd64 image and runs it emulated.
DOCKER_DEFAULT_PLATFORM=linux/amd64 sh "$(dirname "$0")/install_openlane.sh"
```
Decide between primary and fallback based on Task 0 Step 4's result and note the choice in the commit message.

- [ ] **Step 4: Commit**

```bash
git add scripts/install_librelane.sh
git commit -m "feat: add LibreLane install script for arm64 digital flow"
```

---

## Task 6: CI — constrain x86 job, add arm64 job, extend publish

**Files:**
- Modify: `.github/workflows/build_vm.yml`

- [ ] **Step 1: Constrain the existing x86 build to the virtualbox source only**

In the `build` job, change the `Build VM` step so the qemu source is not attempted on the x86 runner:
```yaml
      - name: Build VM
        run: 'packer build -only=virtualbox-iso.tinytapeout_analog_vm ./image.pkr.hcl'
```
Leave every other step in the `build` job (KVM perms, free disk, install virtualbox, packer setup/init, write vminfo, copy vminfo, upload-artifact) unchanged.

- [ ] **Step 2: Add the `build-arm64` job**

After the `build` job (and before `publish`), add:
```yaml
  build-arm64:
    runs-on: ubuntu-24.04-arm

    steps:
      - uses: actions/checkout@v4

      - name: Enable KVM group perms
        run: |
          echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules
          sudo udevadm control --reload-rules
          sudo udevadm trigger --name-match=kvm

      - name: Free Disk Space (Ubuntu)
        uses: jlumbroso/free-disk-space@main
        with:
          tool-cache: false

      - name: Install QEMU and UEFI firmware
        run: |
          sudo apt-get update
          sudo apt-get install -y qemu-system-arm qemu-utils qemu-efi-aarch64
          # Writable UEFI vars copy in the workspace (referenced by qemuargs in image.pkr.hcl)
          cp /usr/share/AAVMF/AAVMF_VARS.fd ./AAVMF_VARS.fd

      - name: Setup `packer`
        uses: hashicorp/setup-packer@main
        env:
          PACKER_GITHUB_API_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Configure packer
        run: 'packer init ./image.pkr.hcl'

      - name: 'Write vminfo.json'
        run: |
          cat > vminfo.json << EOF
          {
            "repo": "${{ github.server_url }}/${{ github.repository }}",
            "commit": "${{ github.sha }}",
            "tag": "${{ github.ref }}",
            "arch": "arm64",
            "build_time": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
          }
          EOF
          cat vminfo.json

      - name: Build VM
        run: 'packer build -only=qemu.tinytapeout_analog_vm_arm64 ./image.pkr.hcl'

      - name: Locate and compress qcow2
        run: |
          SRC=$(find output-* -name '*.qcow2' | head -1)
          qemu-img convert -O qcow2 -c "$SRC" tinytapeout_analog_vm_arm64.qcow2
          cp vminfo.json tinytapeout_analog_vm_arm64.qcow2.json

      - name: Upload VM image
        uses: actions/upload-artifact@v4
        with:
          name: tt_analog_qemu_qcow2
          path: |
            tinytapeout_analog_vm_arm64.qcow2
            tinytapeout_analog_vm_arm64.qcow2.json
```

- [ ] **Step 3: Extend the `publish` job to also publish the qcow2**

In the `publish` job: add `build-arm64` to `needs`, download the qcow2 artifact, hash it, and upload it to R2. Change `needs: build` to:
```yaml
    needs: [build, build-arm64]
```
Add a second download step after the existing `Download VM image` step:
```yaml
      - name: Download arm64 VM image
        uses: actions/download-artifact@v4
        with:
          name: tt_analog_qemu_qcow2
          path: artifacts
```
Add a hash step after the existing `Generate SHA256 hash` step:
```yaml
      - name: Generate arm64 SHA256 hash
        working-directory: artifacts
        run: sha256sum tinytapeout_analog_vm_arm64.qcow2 > tinytapeout_analog_vm_arm64.qcow2.sha256
```
And extend the R2 upload step's `s3cmd put` file list to include the three new files:
```yaml
      - name: Upload VM image to R2
        working-directory: artifacts
        run: |
          s3cmd put --multipart-chunk-size-mb=5000 --acl-public \
            tinytapeout_analog_vm.ova tinytapeout_analog_vm.ova.json tinytapeout_analog_vm.ova.sha256 \
            tinytapeout_analog_vm_arm64.qcow2 tinytapeout_analog_vm_arm64.qcow2.json tinytapeout_analog_vm_arm64.qcow2.sha256 \
            "s3://$BUCKET_NAME/"
        env:
          BUCKET_NAME: ${{ vars.R2_BUCKET_NAME }}
```

- [ ] **Step 4: Lint the workflow**

Run (install actionlint if available; otherwise at least YAML-parse it):
```bash
actionlint .github/workflows/build_vm.yml || \
  python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build_vm.yml')); print('yaml OK')"
```
Expected: no actionlint errors (or `yaml OK`).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build_vm.yml
git commit -m "ci: build and publish arm64 qcow2 on ubuntu-24.04-arm runner"
```

---

## Task 7: README — Apple Silicon / UTM section

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a download bullet for the arm64 image**

In the "Getting the VM" section, after the existing OVA bullet, add:
```markdown
- **Apple Silicon (arm64) / UTM:** [tinytapeout_analog_vm_arm64.qcow2](https://sky130-vm.tinytapeout.com/tinytapeout_analog_vm_arm64.qcow2)
```

- [ ] **Step 2: Add a UTM import subsection**

After the VirtualBox/VMware import paragraphs, add:
```markdown
### Running on Apple Silicon Macs (UTM)

On an Apple Silicon Mac, use the arm64 `qcow2` image with [UTM](https://mac.getutm.app/) (free):

1. Download `tinytapeout_analog_vm_arm64.qcow2`.
2. In UTM: **Create a New Virtual Machine → Virtualize → Linux**.
3. Skip the boot ISO. Under **Drives**, remove the default drive and **Import** the downloaded `.qcow2`.
4. Set the VM to at least 4 CPUs and 8 GB RAM, then start it.

The image runs natively on Apple Silicon (no emulation). Log in with username `ttuser`
and password `magic`. The digital flow uses [LibreLane](https://librelane.readthedocs.io/)
(open a "LibreLane Shell" from the desktop) instead of the OpenLane Docker image used on x86.
```

- [ ] **Step 3: Verify rendering**

Run:
```bash
grep -n "arm64" README.md
```
Expected: the new download bullet and UTM subsection appear.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document arm64 qcow2 image and UTM import"
```

---

## Task 8: End-to-end verification (CI + manual smoke test)

**No files changed.** This is the real integration test; earlier local checks only cover syntax/schema.

- [ ] **Step 1: Push the branch and open a PR to trigger CI**

```bash
git push -u origin feat/aarch64-vm
gh pr create --fill --title "Build aarch64 VM alongside x86-64"
```

- [ ] **Step 2: Watch both build jobs**

```bash
gh run watch
```
Expected: `build` (x86 OVA) stays green exactly as before, and `build-arm64` completes green, producing `tinytapeout_analog_vm_arm64.qcow2`.
If `build-arm64` fails, the most likely culprits and where to look:
- **Boot/autoinstall hang** → arm64 UEFI GRUB `boot_command` timing; adjust `boot_wait`/`<wait>` in `locals.boot_command` or the firmware `qemuargs`.
- **Firmware path** → confirm `/usr/share/AAVMF/AAVMF_{CODE,VARS}.fd` exist (Task 0 Step 2).
- **LibreLane building from source** (job runs for hours) → FOSSi cache lacks aarch64-linux; switch to the Task 5 fallback.

- [ ] **Step 3: Manual UTM smoke test (maintainer, on an Apple Silicon Mac)**

Download the qcow2 from the run artifact, import into UTM (README Task 7 steps), boot, and confirm:
- The GNOME desktop starts and you can log in as `ttuser`/`magic`.
- Magic, KLayout, and Xschem launch from the desktop icons.
- `ngspice --version` works in a terminal.
- The "LibreLane Shell" desktop entry enters the Nix env and `librelane --version` runs (or, in the fallback path, `docker run` pulls the emulated OpenLane image).

- [ ] **Step 4: Merge**

Once both CI jobs are green and the smoke test passes, use the `superpowers:finishing-a-development-branch` skill to complete the merge.

---

## Self-Review Notes

- **Spec coverage:** every spec section maps to a task — Packer structure → Task 1; qemu source → Task 1 Step 4; guest tooling → Task 3; arch-aware KLayout → Task 4; LibreLane (+ verification gate + fallback) → Task 0 Step 4 / Task 5; arm64 user-data → Task 2; CI → Task 6; README → Task 7; testing/verification → Task 8; the FOSSi-cache and KLayout risks → Task 0.
- **Deferred external facts** (ISO point release, firmware path, KLayout arm64 URL, cache coverage, LibreLane tag) are resolved in Task 0 with exact commands, then consumed by later tasks — these are real dependencies, not placeholders.
- **Names are consistent** across tasks: source `qemu.tinytapeout_analog_vm_arm64`, output `tinytapeout_analog_vm_arm64.qcow2`, artifact `tt_analog_qemu_qcow2`, env `LIBRELANE_VERSION`.
