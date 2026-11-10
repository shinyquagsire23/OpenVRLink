#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Build the visionOS app (optimised: an unoptimised build runs the headset hot)
# and, when a headset is reachable, install and launch it.
#
#   ./run.sh              build for the device, install, launch
#   ./run.sh --build      build only
#
# The headset must be paired with this Mac for development (Xcode > Devices)
# and awake on the same network.
set -euo pipefail
cd "$(dirname "$0")"

python3 gen_xcodeproj.py
DERIVED=build/derived
xcodebuild -project OpenVRLink.xcodeproj -scheme OpenVRLink -configuration Release \
    -destination 'generic/platform=visionOS' -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates build | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true
APP="$DERIVED/Build/Products/Release-xros/OpenVRLink.app"
[ -d "$APP" ] || { echo "build failed"; exit 1; }
[ "${1:-}" = "--build" ] && exit 0

DEVICE=$(xcrun devicectl list devices 2>/dev/null | awk '/Vision Pro/ && /physical/ && /available|connected/ {print}' \
    | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1 || true)
if [ -z "$DEVICE" ]; then
    echo "no reachable Vision Pro; the app is at $APP"
    exit 1
fi
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" --console "$BUNDLE_ID"
