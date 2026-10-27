#!/bin/sh
# Builds Crescendo and installs it to /Applications. Set SIGN_IDENTITY to a certificate of your own
# to keep the Accessibility permission across rebuilds; ad-hoc builds lose it every time.
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x Crescendo || true
rm -rf /Applications/Crescendo.app
cp -R build/Crescendo.app /Applications/
open /Applications/Crescendo.app
echo "Installed. Allow Crescendo under System Settings > Privacy & Security > Accessibility if asked."
