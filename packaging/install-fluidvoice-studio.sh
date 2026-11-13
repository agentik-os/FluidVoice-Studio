#!/bin/bash
# Install FluidVoice Studio from this fork's GitHub release DMG.
# One line:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/agentik-os/FluidVoice-Studio/main/packaging/install-fluidvoice-studio.sh)"
set -euo pipefail

version="${1:-1.6.13}"
repo="agentik-os/FluidVoice-Studio"
asset="FluidVoice-Studio-${version}.dmg"
url="https://github.com/${repo}/releases/download/v${version}/${asset}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading ${url}"
if ! curl -fL --retry 3 --retry-delay 2 "$url" -o "$work/$asset"; then
    cat <<EOF
No GitHub release asset was found at
  ${url}

Build it on a Mac instead:
  git clone https://github.com/${repo}.git
  cd FluidVoice-Studio
  ./build.sh unsigned
The app is DerivedData/Build/Products/Debug/FluidVoice Debug.app
or, from CI, download the FluidVoice-Studio DMG artifact.
EOF
    exit 1
fi

hdiutil attach "$work/$asset" -nobrowse -mountpoint "$work/mnt" >/dev/null
app="$(find "$work/mnt" -maxdepth 2 -name '*.app' -print -quit)"
if [ -z "$app" ]; then
    echo "The DMG does not contain an app." >&2
    hdiutil detach "$work/mnt" >/dev/null || true
    exit 1
fi
rm -rf "/Applications/$(basename "$app")"
cp -R "$app" /Applications/
hdiutil detach "$work/mnt" >/dev/null || true
xattr -dr com.apple.quarantine "/Applications/$(basename "$app")" 2>/dev/null || true
echo "Installed /Applications/$(basename "$app")"
open -a "$(basename "$app" .app)" || true
