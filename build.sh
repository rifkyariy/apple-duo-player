#!/bin/sh
# Builds "build/Duo Player.app" (release, ad-hoc signed) with YOUR Spotify client ID.
# The ID comes from $SPOTIFY_CLIENT_ID, else .spotify-client-id (git-ignored), else it asks once and saves it there.
# Use your own Spotify app: rate limits are per client ID, so sharing one means sharing its limit.
set -e
cd "$(dirname "$0")"

ID="${SPOTIFY_CLIENT_ID:-}"
[ -z "$ID" ] && [ -f .spotify-client-id ] && ID=$(tr -d '[:space:]' < .spotify-client-id)
if [ -z "$ID" ]; then
    if [ -t 0 ]; then
        echo "No Spotify client ID yet. Create one: https://developer.spotify.com/dashboard (see README, 'Set up your Spotify app')."
        printf "Paste your Client ID: "
        read -r ID
    else
        echo "error: set SPOTIFY_CLIENT_ID or put it in .spotify-client-id (see README)." >&2
        exit 1
    fi
fi
case "$ID" in
    *[!0-9a-fA-F]* | "") echo "error: '$ID' doesn't look like a Spotify client ID (32 hex characters)." >&2; exit 1 ;;
esac
[ ${#ID} -eq 32 ] || { echo "error: a Spotify client ID is 32 characters; got ${#ID}." >&2; exit 1; }
echo "$ID" > .spotify-client-id

swift build -c release
APP="build/Duo Player.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DuoPlayer "$APP/Contents/MacOS/"
cp Sources/DuoPlayer/Info.plist "$APP/Contents/"
plutil -insert SpotifyClientID -string "$ID" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP (client ID ${ID%"${ID#????}"}…)"
