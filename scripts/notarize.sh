#!/bin/sh
# Builds, signs with Developer ID, notarizes and staples build/OpenSimulator.app, then zips it for
# distribution as build/OpenSimulator.zip.
#
# Credentials come from the environment or from a .env file in the repository root, which is git
# ignored (copy .env.example to start). The first of these that is set is used:
#   - An App Store Connect API key, given by APPLE_API_KEY_PATH, APPLE_API_KEY_ID and
#     APPLE_API_ISSUER_ID.
#   - An Apple ID, given by APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD (an app-specific
#     password from account.apple.com).
#   - A keychain profile stored once with:
#       xcrun notarytool store-credentials OpenSimulator \
#           --apple-id <your Apple ID> --team-id <TEAMID> --password <app-specific password>
#
# Usage: scripts/notarize.sh
# Overrides: CODESIGN_IDENTITY (defaults to the first Developer ID Application identity),
#            NOTARY_PROFILE (defaults to OpenSimulator).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/OpenSimulator.app"
ZIP="$ROOT/build/OpenSimulator.zip"

if [ -f "$ROOT/.env" ]; then
    set -a
    . "$ROOT/.env"
    set +a
fi
PROFILE="${NOTARY_PROFILE:-OpenSimulator}"

if [ -n "${APPLE_API_KEY_PATH:-}" ]; then
    : "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required with APPLE_API_KEY_PATH}"
    : "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required with APPLE_API_KEY_PATH}"
    set -- --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID"
elif [ -n "${APPLE_ID:-}" ]; then
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required with APPLE_ID}"
    : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required with APPLE_ID}"
    set -- --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
else
    set -- --keychain-profile "$PROFILE"
fi

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$CODESIGN_IDENTITY" ]; then
    echo "No Developer ID Application certificate in the keychain." >&2
    exit 1
fi
export CODESIGN_IDENTITY

"$ROOT/scripts/build-app.sh" release
codesign --verify --strict --deep --verbose=2 "$APP"

# notarytool takes a zip; ditto keeps the bundle's metadata intact.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "$@" --wait

# Staple the ticket so the app opens without a network check, then zip the stapled copy.
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

spctl --assess --type execute --verbose=2 "$APP"
echo "Notarized: $ZIP"
