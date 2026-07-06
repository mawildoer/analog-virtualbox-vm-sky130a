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
Exec=gnome-terminal --working-directory=/home/ttuser/librelane -- bash -lc nix-shell
Icon=utilities-terminal
Terminal=false
Categories=Development;
EOF
gio set "$HOME/Desktop/librelane.desktop" metadata::trusted true || true
chmod a+x "$HOME/Desktop/librelane.desktop"
