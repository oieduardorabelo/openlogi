#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    echo "usage: $0 <app-bundle>" >&2
    exit 64
fi

repo_dir="${0:A:h:h}"
app_dir="$1"
signing_dir="$repo_dir/.openlogi-signing"
keychain="$signing_dir/OpenLogi.keychain-db"
password_file="$signing_dir/keychain-password"
certificate="$signing_dir/OpenLogi.cer"
private_key="$signing_dir/OpenLogi.key"
identity_archive="$signing_dir/OpenLogi.p12"
identity_name="OpenLogi Local Development"

mkdir -p "$signing_dir"
chmod 700 "$signing_dir"

if [[ ! -f "$keychain" ]]; then
    openssl rand -hex -out "$password_file" 32
    chmod 600 "$password_file"
    signing_password="$(<"$password_file")"

    openssl req \
        -x509 \
        -newkey rsa:2048 \
        -nodes \
        -days 3650 \
        -config "$repo_dir/Resources/LocalCodeSigning.cnf" \
        -keyout "$private_key" \
        -out "$certificate"

    openssl pkcs12 \
        -export \
        -legacy \
        -inkey "$private_key" \
        -in "$certificate" \
        -name "$identity_name" \
        -passout "pass:$signing_password" \
        -out "$identity_archive"

    security create-keychain -p "$signing_password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$signing_password" "$keychain"
    security import "$identity_archive" \
        -k "$keychain" \
        -P "$signing_password" \
        -T /usr/bin/codesign
    security add-trusted-cert \
        -d \
        -r trustRoot \
        -p codeSign \
        -k "$keychain" \
        "$certificate"
    security set-key-partition-list \
        -S apple-tool:,apple: \
        -s \
        -k "$signing_password" \
        -l "$identity_name" \
        -t private \
        "$keychain"
else
    signing_password="$(<"$password_file")"
    security unlock-keychain -p "$signing_password" "$keychain"
fi

identity_hash="$(security find-certificate -c "$identity_name" -Z "$keychain" | awk '/SHA-1 hash:/{print $3; exit}')"
if [[ -z "$identity_hash" ]]; then
    echo "OpenLogi signing identity not found" >&2
    exit 1
fi

existing_keychains=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"([^"]+)".*/\1/')}")
restore_keychain_search() {
    security list-keychains -d user -s "${existing_keychains[@]}"
}
trap restore_keychain_search EXIT

security list-keychains -d user -s "${existing_keychains[@]}" "$keychain"
codesign \
    --force \
    --deep \
    --sign "$identity_hash" \
    --timestamp=none \
    "$app_dir"

restore_keychain_search
trap - EXIT
