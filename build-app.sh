#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
build_dir="$(swift build -c release --show-bin-path)"
app_path="$PWD/../MusicFlow.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$build_dir/MusicFlow" "$app_path/Contents/MacOS/MusicFlow"
ditto "$build_dir/MusicFlow_MusicFlow.bundle" "$app_path/Contents/Resources/MusicFlow_MusicFlow.bundle"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.musicflow.reconstruction</string>
<key>CFBundleExecutable</key><string>MusicFlow</string>
<key>CFBundleName</key><string>MusicFlow</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_path"
echo "$app_path"
