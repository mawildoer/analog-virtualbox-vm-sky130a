#! /bin/sh

set -e

# Guest integration for QEMU/UTM: replaces VirtualBox Guest Additions on arm64.
# - qemu-guest-agent: graceful shutdown, host/guest coordination
# - spice-vdagent:    clipboard sharing and dynamic display resize under UTM
sudo apt-get install -y qemu-guest-agent spice-vdagent

sudo systemctl enable qemu-guest-agent
sudo systemctl enable spice-vdagentd

# Verify the agent binary is present
command -v qemu-ga || true
