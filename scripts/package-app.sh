#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
app_dir="$repo_dir/dist/OpenLogi.app"
if [[ -d "$app_dir" ]]; then
    mkdir -p "$repo_dir/tmp"
    previous_app_dir="$(mktemp -d "$repo_dir/tmp/previous-app.XXXXXX")"
    mv "$app_dir" "$previous_app_dir/OpenLogi.app"
fi
swift build -c release --package-path "$repo_dir"
binary_dir="$(swift build -c release --show-bin-path --package-path "$repo_dir")"

mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "$binary_dir/OpenLogi" "$app_dir/Contents/MacOS/OpenLogi"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/Resources/OpenLogi.icns" "$app_dir/Contents/Resources/OpenLogi.icns"
resource_bundle_dir="$app_dir/Contents/Resources/OpenLogi_OpenLogi.bundle"
mkdir -p "$resource_bundle_dir"
cp "$binary_dir/OpenLogi_OpenLogi.bundle/DMSans-Variable.ttf" "$resource_bundle_dir/DMSans-Variable.ttf"
"$repo_dir/scripts/sign-app.sh" "$app_dir"

echo "$app_dir"
