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

# --- aarch64 build tuning ---
# The aarch64 image is built LOCALLY on an Apple Silicon Mac using QEMU's
# Hypervisor.framework (accel=hvf), because GitHub's free arm64 hosted runners
# do NOT provide /dev/kvm (no nested virtualization on arm64 runners). Use the
# scripts/build_arm64_local.sh wrapper, which sets these for your machine.
# To build on an arm64 Linux host that has KVM instead, override:
#   -var 'qemu_accel=kvm' -var 'efi_code_path=/usr/share/AAVMF/AAVMF_CODE.fd'
variable "qemu_accel" {
  type    = string
  default = "hvf"
}

variable "efi_code_path" {
  type    = string
  default = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
}

locals {
  cpus                   = 4
  memory                 = 8192
  disk_size              = 32768
  ssh_username           = "ttuser"
  ssh_password           = "magic"
  ssh_read_write_timeout = "600s"
  ssh_timeout            = "120m"
  shutdown_command       = "sudo shutdown -h now"
  # Shared GRUB autoinstall sequence. Reused by the UEFI arm64 qemu source;
  # its keystroke timing is verified by the local arm64 build (build_arm64_local.sh).
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

source "virtualbox-iso" "tinytapeout_analog_vm" {
  format                 = "ova"
  vm_name                = "tinytapeout_analog_vm"
  boot_command           = local.boot_command
  boot_wait              = "1s"
  cpus                   = local.cpus
  disk_size              = local.disk_size
  guest_os_type          = "Ubuntu_64"
  headless               = true
  http_directory         = "./http"
  iso_checksum           = "a4acfda10b18da50e2ec50ccaf860d7f20b389df8765611142305c0e911d16fd"
  iso_url                = "https://old-releases.ubuntu.com/releases/22.04/ubuntu-22.04.3-live-server-amd64.iso"
  guest_additions_url    = "https://download.virtualbox.org/virtualbox/7.0.14/VBoxGuestAdditions_7.0.14.iso"
  guest_additions_sha256 = "0efbcb9bf4722cb19292ae00eba29587432e918d3b1f70905deb70f7cf78e8ce"
  memory                 = local.memory
  gfx_controller         = "vmsvga"
  gfx_vram_size          = 128
  gfx_accelerate_3d      = true
  shutdown_command       = local.shutdown_command
  ssh_password           = local.ssh_password
  ssh_port               = 22
  ssh_read_write_timeout = local.ssh_read_write_timeout
  ssh_timeout            = local.ssh_timeout
  ssh_username           = local.ssh_username
  vboxmanage = [
    ["modifyvm", "{{ .Name }}", "--cpu-profile", "host"],
  ]
  vrdp_bind_address = "0.0.0.0"
  vrdp_port_max     = 6000
  vrdp_port_min     = 5900
}

source "qemu" "tinytapeout_analog_vm_arm64" {
  vm_name                = "tinytapeout_analog_vm_arm64.qcow2"
  qemu_binary            = "qemu-system-aarch64"
  machine_type           = "virt"
  accelerator            = var.qemu_accel
  format                 = "qcow2"
  disk_interface         = "virtio"
  disk_size              = local.disk_size
  net_device             = "virtio-net-pci"
  cpus                   = local.cpus
  memory                 = local.memory
  headless               = true
  http_directory         = "./http-arm64"
  iso_url                = "https://old-releases.ubuntu.com/releases/22.04/ubuntu-22.04.3-live-server-arm64.iso"
  iso_checksum           = "sha256:5702372d25111e24d59596de62ae24daef873018cbf63c9dd9ff12292a57aca9"
  boot_wait              = "5s"
  boot_command           = local.boot_command
  shutdown_command       = local.shutdown_command
  ssh_username           = local.ssh_username
  ssh_password           = local.ssh_password
  ssh_timeout            = local.ssh_timeout
  ssh_read_write_timeout = local.ssh_read_write_timeout
  # NOTE: a -machine entry in qemuargs replaces Packer's default -machine wholesale,
  # so the accelerator (var.qemu_accel, default hvf) must be repeated here or it is
  # silently lost. AAVMF_VARS.fd is a writable copy of the edk2 vars template that
  # scripts/build_arm64_local.sh places in the working directory before the build.
  qemuargs = [
    ["-cpu", "host"],
    ["-machine", "virt,gic-version=max,accel=${var.qemu_accel}"],
    ["-drive", "if=pflash,format=raw,readonly=on,file=${var.efi_code_path}"],
    ["-drive", "if=pflash,format=raw,file=AAVMF_VARS.fd"],
    ["-device", "virtio-gpu-pci"]
  ]
}

build {
  sources = [
    "source.virtualbox-iso.tinytapeout_analog_vm",
    "source.qemu.tinytapeout_analog_vm_arm64",
  ]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get upgrade -y",
      "sudo apt-get install -y ubuntu-desktop-minimal build-essential",
      "sudo apt-get remove -y --autoremove gnome-initial-setup",
      "mkdir -p /home/ttuser/Pictures"
    ]
  }

  provisioner "file" {
    source      = "vminfo.json"
    destination = "/home/ttuser/vminfo.json"
  }

  provisioner "file" {
    source      = "assets/ttwallpaper.png"
    destination = "/home/ttuser/Pictures/ttwallpaper.png"
  }

  provisioner "shell" {
    env = {
      PDK_ROOT          = "/home/ttuser/pdk"
      PDK_VERSION       = "bdc9412b3e468c102d01b7cf6337be06ec6e9c9a"
      KLAYOUT_VERSION   = "0.30.3"
      MAGIC_VERSION     = "8.3.576"
      NETGEN_VERSION    = "1.5.270"
      OPENLANE_TAG      = "2024.05.09"
      VERILATOR_VERSION = "v5.024"
      NGSPICE_VERSION   = "44"
      XSCHEM_VERSION    = "e55c8294c2a89c4a6f45923abd5e20c40e4ffe86"
    }
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
  }

  provisioner "shell" {
    only = ["virtualbox-iso.tinytapeout_analog_vm"]
    scripts = [
      "scripts/install_virtualbox_tools.sh",
      "scripts/install_openlane.sh",
    ]
  }

  provisioner "shell" {
    only = ["qemu.tinytapeout_analog_vm_arm64"]
    env = {
      LIBRELANE_VERSION = "3.0.4"
    }
    scripts = [
      "scripts/install_qemu_tools.sh",
      "scripts/install_librelane.sh",
    ]
  }
}
