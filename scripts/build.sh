#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
swift build -c "$configuration" --product MicPriority
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$project_root/dist/MicPriority.app"
mkdir -p "$project_root/dist"
staging_root="$(mktemp -d "$project_root/dist/.build.XXXXXX")"
cleanup() {
    if [ ! -e "$app_path" ] && [ -d "$staging_root/previous.app" ]; then
        mv "$staging_root/previous.app" "$app_path"
    fi
    rm -rf "$staging_root"
}
trap cleanup EXIT
staged_app="$staging_root/MicPriority.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/MicPriority" "$staged_app/Contents/MacOS/MicPriority"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
xcrun swiftc -parse-as-library Sources/MicPriority/BrandArtwork.swift scripts/render-icons.swift -o "$staging_root/render-icons"
"$staging_root/render-icons" "$staged_app/Contents/Resources"
/usr/bin/iconutil -c icns "$staged_app/Contents/Resources/AppIcon.iconset" -o "$staged_app/Contents/Resources/AppIcon.icns"
rm -rf "$staged_app/Contents/Resources/AppIcon.iconset"
/usr/bin/plutil -lint "$staged_app/Contents/Info.plist"
/usr/bin/codesign --force --sign "${MIC_PRIORITY_SIGN_IDENTITY:--}" --options runtime "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"
# Replace the bundle without truncating an executable that may still be running.
if [ -e "$app_path" ]; then mv "$app_path" "$staging_root/previous.app"; fi
mv "$staged_app" "$app_path"
echo "$app_path"
