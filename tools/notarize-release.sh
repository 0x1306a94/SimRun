#!/bin/bash
# CI entry point. Secrets must be supplied through the environment, never xtrace.
set -euo pipefail
set +x
umask 077

APP=${1:?Usage: notarize-release.sh path/to/SimRun.app output.zip}
OUTPUT=${2:?Supply the final zip path}
: "${DEVELOPER_ID_P12_BASE64:?Missing signing certificate}"
: "${DEVELOPER_ID_P12_PASSWORD:?Missing certificate password}"
: "${APPLE_API_KEY_P8:?Missing notarization key}"
: "${APPLE_API_KEY_ID:?Missing notarization key ID}"
: "${APPLE_API_ISSUER_ID:?Missing notarization issuer ID}"
: "${SIGNING_IDENTITY:?Missing signing identity}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG_DIR="$ROOT/build/notarization"
mkdir -p "$LOG_DIR"
rm -f "$LOG_DIR/submission.json" "$LOG_DIR/result.json" "$LOG_DIR/log.json"
PRIVATE_DIR=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/simrun-signing.XXXXXX")
SIGNING_KEYCHAIN="$PRIVATE_DIR/release.keychain-db"
export SIGNING_KEYCHAIN
cleanup() {
    /usr/bin/security delete-keychain "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
    rm -rf "$PRIVATE_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s' "$DEVELOPER_ID_P12_BASE64" | /usr/bin/base64 -D > "$PRIVATE_DIR/certificate.p12"
printf '%s\n' "$APPLE_API_KEY_P8" > "$PRIVATE_DIR/AuthKey.p8"
KEYCHAIN_PASSWORD=$(/usr/bin/openssl rand -hex 32)
/usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
/usr/bin/security set-keychain-settings -lut 3600 "$SIGNING_KEYCHAIN"
/usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN"
/usr/bin/security import "$PRIVATE_DIR/certificate.p12" -k "$SIGNING_KEYCHAIN" \
    -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s \
    -k "$KEYCHAIN_PASSWORD" "$SIGNING_KEYCHAIN" >/dev/null
rm "$PRIVATE_DIR/certificate.p12"
unset DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD APPLE_API_KEY_P8 KEYCHAIN_PASSWORD

bash "$ROOT/tools/sign-release.sh" "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" "$PRIVATE_DIR/submission.zip"
AUTH=(--key "$PRIVATE_DIR/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
# Submit separately from waiting so a timeout still leaves the submission ID.
xcrun notarytool submit "$PRIVATE_DIR/submission.zip" "${AUTH[@]}" \
    --output-format json > "$LOG_DIR/submission.json"
SUBMISSION_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$LOG_DIR/submission.json")
echo "Notarization submission: $SUBMISSION_ID"
wait_status=0
xcrun notarytool wait "$SUBMISSION_ID" "${AUTH[@]}" --timeout 30m \
    --output-format json > "$LOG_DIR/result.json" || wait_status=$?
# Preserve Apple's diagnostics for both successful and rejected submissions.
xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" "$LOG_DIR/log.json" || true
if [[ $wait_status -ne 0 ]]; then
    echo "Notarization did not finish successfully; see build/notarization." >&2
    exit "$wait_status"
fi
python3 - "$LOG_DIR/result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    sys.exit("Notarization was not accepted: " + str(result.get("status")))
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
if ! /usr/sbin/spctl --assess --type execute --verbose=4 "$APP"; then
    # Keep the exact rejected bundle and a more specific system-policy diagnosis.
    /usr/bin/syspolicy_check distribution --verbose "$APP" > "$LOG_DIR/gatekeeper.txt" 2>&1 || true
    cat "$LOG_DIR/gatekeeper.txt"
    /usr/bin/ditto -c -k --keepParent "$APP" "$LOG_DIR/rejected-app.zip"
    exit 1
fi
# The distributed zip must contain the stapled app, not the submission archive.
rm -f "$OUTPUT"
/usr/bin/ditto -c -k --keepParent "$APP" "$OUTPUT"
