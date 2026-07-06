# Tiny Tapeout Analog Design VM with Skywater 130 PDK

![](../../workflows/build_vm/badge.svg)

This repository contains the necessary files to build a virtual machine (VM) for analog design using the Skywater 130nm PDK. 

The VM is based on Ubuntu 22.04 and includes the following tools:

- [Magic](http://opencircuitdesign.com/magic/)
- [KLayout](https://www.klayout.de/)
- [Xschem](https://xschem.sourceforge.io/stefan/index.html)
- [netgen](http://opencircuitdesign.com/netgen/)
- [ngspice](http://ngspice.sourceforge.net/)
- [gaw](https://gaw.tuxfamily.org/)
- [Skywater 130nm PDK](https://github.com/google/skywater-pdk)
- [OpenLane](https://openlane.readthedocs.io/en/latest/)
- [Verilator](https://www.veripool.org/verilator/)

## Getting the VM

You can download the latest version of the VM from the following link:

- [VirtualBox Machine - tinytapeout_analog_vm.ova](https://sky130-vm.tinytapeout.com/tinytapeout_analog_vm.ova) (x86-64)
- **Apple Silicon (arm64) / UTM:** built locally — see [Running on Apple Silicon Macs](#running-on-apple-silicon-macs-utm) below.

The VM is about 5 GB in size and requires about 20 GB of disk space to import. You can import the OVA file into [VirtualBox](https://www.virtualbox.org/wiki/Downloads) by going to `File -> Import Appliance` and selecting the OVA file.

You can also import the OVA file into [VMware Workstation Player](https://www.vmware.com/products/workstation-player.html), by going to `Player -> File -> Open...` and selecting the OVA file. When importing into VMware, you will see a warning about "virtual hardware compliance". Click "Retry" to continue.

### Running on Apple Silicon Macs (UTM)

On an Apple Silicon Mac you run the **arm64** image with [UTM](https://mac.getutm.app/) (free).
The arm64 image is **built locally** rather than downloaded: GitHub's free arm64 CI
runners have no hardware virtualization (`/dev/kvm`), so it can't be built in CI. Building
it on your Mac uses QEMU's Hypervisor.framework, which is native speed (no emulation).

**1. Build the image** (one time, ~30–60 min; downloads a ~2 GB Ubuntu ISO):

```bash
brew install qemu packer
scripts/build_arm64_local.sh
```

This produces `output-tinytapeout_analog_vm_arm64/tinytapeout_analog_vm_arm64.qcow2`.

**2. Import into UTM:**

1. In UTM: **Create a New Virtual Machine → Virtualize → Linux**.
2. Skip the boot ISO. Under **Drives**, remove the default drive and **Import** the `.qcow2` from step 1.
3. Set the VM to at least 4 CPUs and 8 GB RAM, then start it.

Log in with username `ttuser` and password `magic`. The digital flow uses
[LibreLane](https://librelane.readthedocs.io/) (open a "LibreLane Shell" from the desktop)
instead of the OpenLane Docker image used on x86.

### Verifying the download

To verify the integrity of the OVA file using the [SHA256 hash](https://sky130-vm.tinytapeout.com/tinytapeout_analog_vm.ova.sha256). Then run the following command in the directory where the OVA file is located:

```bash
sha256sum -c tinytapeout_analog_vm.ova.sha256
```

### Older versions and metadata

To file the build date / commit hash from which the VM was built, download the [JSON metadata file](https://sky130-vm.tinytapeout.com/tinytapeout_analog_vm.ova.json). The metadata file is also present inside the machine, under `/home/ttuser/vminfo.json`.

To download earlier versions of the VM, go to the [actions](https://github.com/TinyTapeout/analog-virtualbox-vm-sky130a/actions) tab, click on one of the workflow runs, and download the tt_analog_virtualbox_ova from the "Artifacts" section (note that downloading GitHub artifacts is usually slower than downloading from the link above).

## Using the VM

The default username for the VM is `ttuser` and the password is `magic`. You can change the password by running the `passwd` command.

The desktop includes shortcuts to start Magic, KLayout, and Xschem. The Skywater 130nm PDK is installed in the `/home/tt_user/pdk` directory.

### Troubleshooting

In case of issues with the graphics (e.g. texts do not appear inside Xschem), try disabling 3D acceleration by opening the VM settings in Virtual Box, going to the "Display" tab, and unchecking "Enable 3D Acceleration" at the bottom of the window.

## Building the VM locally

### x86-64 (VirtualBox OVA)

To build the x86-64 VM locally, you need to have [Packer](https://www.packer.io/) and [VirtualBox](https://www.virtualbox.org/) installed. Then, run the following command:

```bash
packer init image.pkr.hcl
packer build -only=virtualbox-iso.tinytapeout_analog_vm image.pkr.hcl
```

Building the VM takes about 30 minutes, depending on your internet connection and hardware. The resulting OVA file will be in the `output-tinytapeout_analog_vm` directory.

### arm64 (Apple Silicon, qcow2 for UTM)

The arm64 image is built on an Apple Silicon Mac using QEMU + Hypervisor.framework. It is **not** built in CI because GitHub's free arm64 runners lack `/dev/kvm`. Run:

```bash
brew install qemu packer
scripts/build_arm64_local.sh
```

The wrapper locates the edk2 UEFI firmware, prepares a writable NVRAM file, and runs `packer build -only=qemu.tinytapeout_analog_vm_arm64`. The result is `output-tinytapeout_analog_vm_arm64/tinytapeout_analog_vm_arm64.qcow2`. (On an arm64 Linux host with KVM you can instead run Packer directly with `-var qemu_accel=kvm -var efi_code_path=/usr/share/AAVMF/AAVMF_CODE.fd`.)

## Customizing the VM

You can customize the VM by modifying the `image.pkr.hcl` file. For example, you can change the amount of memory, number of CPUs, or the size of the disk.

If you wish to install additional software, you add new scripts to the `scripts` directory and include them in the `image.pkr.hcl` file, in the `scripts` list of the `provisioner` block.

## License

This project is licensed under the terms of the [Apache License 2.0](LICENSE).
