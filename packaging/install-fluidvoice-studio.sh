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
mounted=0
cleanup() {
    if [ "$mounted" = "1" ]; then
        hdiutil detach "$work/mnt" >/dev/null 2>&1 || hdiutil detach "$work/mnt" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT

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
mounted=1
app="$(find "$work/mnt" -maxdepth 2 -name '*.app' -print -quit)"
if [ -z "$app" ]; then
    echo "The DMG does not contain an app." >&2
    exit 1
fi
name="$(basename "$app")"
destination="/Applications/$name"
staging="/Applications/.${name}.installing"
rm -rf "$staging"
cp -R "$app" "$staging"
if [ -d "$destination" ]; then
    rm -rf "${destination}.previous"
    mv "$destination" "${destination}.previous"
fi
if ! mv "$staging" "$destination"; then
    if [ -d "${destination}.previous" ]; then
        mv "${destination}.previous" "$destination"
    fi
    echo "Could not replace $destination" >&2
    exit 1
fi
rm -rf "${destination}.previous"
xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true
echo "Installed $destination"
open -a "${name%.app}" || true
