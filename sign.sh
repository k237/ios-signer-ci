#!/bin/bash
set -eu -o pipefail -E
curl="curl -sfL"

echo "Obtaining files..."
# remove trailing slash and space
# shellcheck disable=SC2001
SECRET_URL=$(echo "$SECRET_URL" | sed 's|[/ ]*$||')
$curl -S -H "Authorization: Bearer $SECRET_KEY" "$SECRET_URL/jobs" | tar -x
cert_pass=$(cat cert_pass.txt)
sign_args=$(cat args.txt)
job_id=$(cat id.txt)
user_bundle_id=$(cat user_bundle_id.txt)
team_id=$(cat team_id.txt)
keychain_id=$(hexdump -n 8 -v -e '/1 "%02X"' /dev/urandom)
keychain_id="ios-signer-$keychain_id"

echo "Creating keychain..."
function cleanup() {
    error_code=$?
    set +e
    if [ $error_code -ne 0 ]; then
        $curl -S -H "Authorization: Bearer $SECRET_KEY" "$SECRET_URL/jobs/$job_id/fail"
    fi
    echo "Cleaning up..."
    # remove the $keychain_id entry from the keychain list, using its short name to match the full path
    # TODO: could there be a race condition between multiple instances of this script?
    # shellcheck disable=SC2001
    # shellcheck disable=SC2046
    eval security list-keychains -d user -s $(security list-keychains -d user | sed "s/\".*$keychain_id.*\"//")
    security delete-keychain "$keychain_id"
}
trap cleanup SIGINT SIGTERM EXIT
security create-keychain -p "1234" "$keychain_id"
security unlock-keychain -p "1234" "$keychain_id"
# shellcheck disable=SC2046
eval security list-keychains -d user -s $(security list-keychains -d user) "$keychain_id"

echo "Importing certificate..."
security import "cert.p12" -P "$cert_pass" -A -k "$keychain_id"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "1234" "$keychain_id" >/dev/null
identity=$(security find-identity -p appleID -v "$keychain_id" | head -n 1 | grep -o '".*"' | cut -d '"' -f 2)
if [ -z "$identity" ]; then
    echo "No valid code signing certificate found, aborting." >&2
    exit 1
fi

if [ ! -f "prov.mobileprovision" ]; then
    if [ ! -f "account_name.txt" ] || [ ! -f "account_pass.txt" ]; then
        echo "No provisioning profile found and no account provided, aborting." >&2
        exit 1
    fi
    if [ -z "$user_bundle_id" ]; then
        echo "Account found but no app bundle id provided, aborting." >&2
        exit 1
    fi

    killall Xcode >/dev/null 2>&1 || true
    rm "$HOME/Library/MobileDevice/Provisioning Profiles/"* >/dev/null 2>&1 || true

    echo "Logging in (1/2)..."
    echo >dummy.developerprofile
    # force Xcode to open the Accounts screen
    open -a "/Applications/Xcode.app" dummy.developerprofile
    ACCOUNT_NAME=$(cat account_name.txt)
    ACCOUNT_PASS=$(cat account_pass.txt)
    export ACCOUNT_NAME ACCOUNT_PASS
    osascript login1.applescript

    echo "Logging in (2/2)..."
    echo "If you receive a two-factor authentication (2FA) code, please submit it to the web service."
    i=0
    code_entered=0
    while true; do
        if [ $i -gt 60 ]; then
            echo "Operation timed out" >&2
            exit 1
        elif osascript login3.applescript >/dev/null 2>&1; then
            echo "Logged in!"
            break
        elif [ $code_entered -eq 0 ] && $curl -H "Authorization: Bearer $SECRET_KEY" "$SECRET_URL/jobs/$job_id/2fa" -o account_2fa.txt; then
            echo "Entering 2FA code..."
            ACCOUNT_2FA="$(cat account_2fa.txt)"
            export ACCOUNT_2FA
            osascript login2.applescript
            code_entered=1
        fi
        sleep 1
        ((i++))
    done

    killall Xcode

    sed -i "" -e "s/BUNDLE_ID_HERE_V9KP12/$user_bundle_id/g" SimpleApp/SimpleApp.xcodeproj/project.pbxproj
    sed -i "" -e "s/DEV_TEAM_HERE_J8HK5C/$team_id/g" SimpleApp/SimpleApp.xcodeproj/project.pbxproj
    open -a "/Applications/Xcode.app" SimpleApp/SimpleApp.xcodeproj

    echo "Waiting for provisioning profile to appear..."
    i=0
    while true; do
        if [ $i -gt 15 ]; then
            echo "Operation timed out. Possible reasons:" >&2
            echo "- You haven't registered your device's UDID with the developer account" >&2
            echo "- You used an invalid or already existing bundle id" >&2
            echo "- You exceeded the 10 app ids per 7 days limit on free accounts" >&2
            exit 1
        elif ls "$HOME/Library/MobileDevice/Provisioning Profiles/"* >/dev/null 2>&1; then
            break
        fi
        sleep 1
        ((i++))
    done

    killall Xcode
    mv "$HOME/Library/MobileDevice/Provisioning Profiles/"* "prov.mobileprovision"
fi

echo "Signing..."
# shellcheck disable=SC2086
./xresign.sh -i unsigned.ipa -c "$identity" -p "prov.mobileprovision" $sign_args
mv unsigned-xresign.ipa file.ipa
rm unsigned.ipa

echo "Uploading..."
$curl -S -H "Authorization: Bearer $SECRET_KEY" -F "file=@file.ipa" -F "bundle_id=$(cat bundle_id.txt)" "$SECRET_URL/jobs/$job_id/signed"
