#!/bin/bash
#
# Builds PodSwitch in release configuration and assembles a minimal
# PodSwitch.app bundle (LSUIElement agent) around the executable.
#
# Usage: ./Scripts/package.sh
# Output: build/PodSwitch.app
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="PodSwitch"
BUNDLE_ID="com.podswitch"
BUILD_DIR="${ROOT_DIR}/build"
APP_DIR="${BUILD_DIR}/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "==> Building ${APP_NAME} (release)…"
swift build --package-path "${ROOT_DIR}" -c release --product "${APP_NAME}"

BIN_PATH="$(swift build --package-path "${ROOT_DIR}" -c release --product "${APP_NAME}" --show-bin-path)/${APP_NAME}"
if [ ! -f "${BIN_PATH}" ]; then
    echo "error: built executable not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "==> Assembling ${APP_NAME}.app…"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RES_DIR}"

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# App icon (.icns) + menu-bar template (PDF), generated from brand/master/*.svg
cp "${ROOT_DIR}/Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
cp "${ROOT_DIR}/Resources/MenuBarIcon.pdf" "${RES_DIR}/MenuBarIcon.pdf"

# MediaRemote adapter: mediaremote-adapter.pl + MediaRemoteAdapter.framework.
# Run by /usr/bin/perl to read the system Now Playing state on macOS 14.4+
# (never linked against). ditto preserves the framework's symlinks + ad-hoc
# signature. Absent -> AudioMonitor falls back to the process-output signal.
if [ -d "${ROOT_DIR}/Resources/MediaRemoteAdapter" ]; then
    ditto "${ROOT_DIR}/Resources/MediaRemoteAdapter" "${RES_DIR}/MediaRemoteAdapter"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>PodSwitch connects to your paired Bluetooth device when audio starts.</string>
    <!--
      The peer API uses plain HTTP only inside the encrypted Tailscale WireGuard
      network. Scope the ATS exception to Tailscale MagicDNS names (*.ts.net);
      all other hosts continue to require HTTPS.
    -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>ts.net</key>
            <dict>
                <key>NSIncludesSubdomains</key>
                <true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

# Validate the generated bundle metadata before signing.
plutil -lint "${APP_DIR}/Contents/Info.plist"

# Ad-hoc sign inside-out (framework, then bundle) so the signature seals
# resources. Without it the unsealed bundle reads as "damaged" once quarantined.
echo "==> Code signing (ad-hoc)…"
FRAMEWORK="${RES_DIR}/MediaRemoteAdapter/MediaRemoteAdapter.framework"
if [ -d "${FRAMEWORK}" ]; then
    codesign --force --sign - "${FRAMEWORK}"
fi
codesign --force --sign - "${APP_DIR}"
codesign --verify --strict --verbose=2 "${APP_DIR}"

echo "==> Done: ${APP_DIR}"
