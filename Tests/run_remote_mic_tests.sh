#!/bin/sh
# Discovery, pairing, framing, and Screen Sharing hotkey checks. No app host.
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-remote-mic-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
xcrun swiftc -O -parse-as-library \
    Sources/Fluid/RemoteMic/RemoteMicProtocol.swift \
    Sources/Fluid/RemoteMic/RemoteMicDiscovery.swift \
    Sources/Fluid/RemoteMic/RemoteMicSessionMachine.swift \
    Sources/Fluid/RemoteMic/RemoteMicPairing.swift \
    Sources/Fluid/RemoteMic/RemoteMicHotkeyMatch.swift \
    Sources/Fluid/RemoteMic/RemoteMicPermissions.swift \
    Tests/RemoteMicLogicTests.swift \
    -o "$task_test_dir/RemoteMicLogicTests"
"$task_test_dir/RemoteMicLogicTests"
