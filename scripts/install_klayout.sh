#!/bin/sh

set -e

ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" = "amd64" ]; then
  curl -o /tmp/klayout.deb "https://www.klayout.org/downloads/Ubuntu-22/klayout_$KLAYOUT_VERSION-1_amd64.deb"
  sudo apt-get install -y /tmp/klayout.deb
  rm /tmp/klayout.deb
elif [ "$ARCH" = "arm64" ]; then
  # Prefer the pinned arm64 .deb if KLayout publishes one; otherwise fall back to
  # the distro package (version may differ from the pin — confirmed no arm64 .deb
  # exists at klayout.org for this version).
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

# Add icon to the desktop
mkdir -p ~/Desktop
cat << EOF > ~/Desktop/klayout.desktop
[Desktop Entry]
Exec=klayout %f
Name=KLayout
Comment=Layout Viewer
Icon=klayout
Type=Application
Categories=Development;Engineering;Electronics;
EOF
gio set ~/Desktop/klayout.desktop metadata::trusted true
chmod a+x ~/Desktop/klayout.desktop
