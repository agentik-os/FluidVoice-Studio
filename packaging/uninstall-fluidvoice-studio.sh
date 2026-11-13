#!/bin/bash
# Remove FluidVoice Studio: quit, login item, pairing file, and the app bundle.
# Settings live in the app's defaults domain and are removed with it.
set -euo pipefail

osascript -e 'tell application "FluidVoice" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application "FluidVoice Debug" to quit' >/dev/null 2>&1 || true
sleep 1

# The app is the login item (SMAppService.mainApp). This is the supported
# fallback when the app is already gone and cannot unregister itself.
osascript -e 'tell application "System Events" to delete login item "FluidVoice"' >/dev/null 2>&1 || true
osascript -e 'tell application "System Events" to delete login item "FluidVoice Debug"' >/dev/null 2>&1 || true
uid="$(id -u)"
launchctl bootout "gui/${uid}/com.FluidApp.app" >/dev/null 2>&1 || true
launchctl bootout "gui/${uid}/com.FluidApp.app.debug" >/dev/null 2>&1 || true

rm -rf "/Applications/FluidVoice.app" "/Applications/FluidVoice Debug.app"
rm -f "${HOME}/Library/Application Support/FluidVoice/studio-identity.json"
defaults delete com.FluidApp.app >/dev/null 2>&1 || true
defaults delete com.FluidApp.app.debug >/dev/null 2>&1 || true

cat <<EOF
FluidVoice Studio was removed.

If an older microphone-share experiment is still installed, unload it too.
Those LaunchAgents are not part of this app:
  launchctl bootout gui/$(id -u)/com.moonbase.mic-share
  launchctl bootout gui/$(id -u)/com.agentik.mic-share
  launchctl bootout gui/$(id -u)/com.moonbase.fluidvoice-hotkey-bridge
EOF
