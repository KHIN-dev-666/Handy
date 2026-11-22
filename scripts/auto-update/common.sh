# Shared helpers for the Handy fork auto-update scripts. Source, don't run.
# shellcheck shell=bash

export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

AU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${HANDY_REPO_DIR:-$(cd "$AU_DIR/../.." && pwd)}"
LOG_DIR="$HOME/Library/Logs/handy-auto-update"
STATE_DIR="$HOME/Library/Application Support/handy-auto-update"
APP_NAME="Handy"
APP_PATH="${HANDY_APP_PATH:-/Applications/Handy.app}"
BUNDLE_ID="com.pais.handy"
MINI_HOST="${HANDY_MINI_HOST:-my-mac}"
mkdir -p "$LOG_DIR" "$STATE_DIR"

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${LOG_TAG:-handy}" "$*" >>"$LOG_FILE"; }

# notify "title" "message" — Mac notification (also logged).
notify() {
    log "NOTIFY: $1 — $2"
    [ "${HANDY_NO_NOTIFY:-0}" = 1 ] && return 0
    /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
    display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}

# run_logged "label" cmd... — run a command, append its output to the log.
run_logged() {
    local label="$1"; shift
    log "RUN [$label]: $*"
    if "$@" >>"$LOG_FILE" 2>&1; then
        log "OK  [$label]"
        return 0
    else
        local rc=$?
        log "FAIL [$label] exit $rc"
        return "$rc"
    fi
}

# Lock shared by both jobs so a sync never copies a half-installed app.
acquire_lock() {
    local lock="$STATE_DIR/lock"
    local i
    for i in $(seq 1 "${1:-1}"); do
        if mkdir "$lock" 2>/dev/null; then
            echo $$ >"$lock/pid"
            trap 'rm -rf "$STATE_DIR/lock"' EXIT
            return 0
        fi
        local pid
        pid=$(cat "$lock/pid" 2>/dev/null || true)
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            rm -rf "$lock"; continue
        fi
        sleep 30
    done
    return 1
}

screen_locked() {
    /usr/sbin/ioreg -n Root -d1 -a | /usr/bin/grep -A1 CGSSessionScreenIsLocked | /usr/bin/grep -q '<true/>'
}

app_cdhash() { /usr/bin/codesign -dvvv "$1" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p'; }
app_version() { /usr/bin/defaults read "$1/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null; }

quit_handy() {
    /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 20); do
        /usr/bin/pgrep -f "$APP_PATH/Contents/MacOS/" >/dev/null || return 0
        sleep 0.5
    done
    /usr/bin/pkill -f "$APP_PATH/Contents/MacOS/" || true
    sleep 1
}

# --- Code signing ---------------------------------------------------------
# A fixed self-signed certificate ("Handy Local Signing") in a dedicated keychain.
# Its designated requirement is `identifier "com.pais.handy" and certificate leaf = H"..."`,
# so every rebuild signed with it keeps the Accessibility grant (ad-hoc pins the cdhash,
# which changes on every build). Created once by setup-signing.sh.
SIGN_DIR="$STATE_DIR/signing"
SIGN_KEYCHAIN="$SIGN_DIR/handy-signing.keychain-db"
SIGN_NAME="Handy Local Signing"

sign_app() {
    local app="$1" id
    [ -f "$SIGN_KEYCHAIN" ] || { log "No signing keychain; run setup-signing.sh"; return 1; }
    /usr/bin/security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_KEYCHAIN" || return 1
    id=$(/usr/bin/security find-identity -p codesigning "$SIGN_KEYCHAIN" | /usr/bin/awk -v n="\"$SIGN_NAME\"" 'index($0,n){print $2; exit}')
    [ -n "$id" ] || { log "Identity $SIGN_NAME not found"; return 1; }
    /usr/bin/codesign --force --deep --options runtime \
        --entitlements "$REPO_DIR/src-tauri/Entitlements.plist" \
        --keychain "$SIGN_KEYCHAIN" --sign "$id" "$app" >>"$LOG_FILE" 2>&1 || return 1
    /usr/bin/codesign --verify --deep --strict "$app" >>"$LOG_FILE" 2>&1 || return 1
    /usr/bin/codesign -dvv "$app" 2>&1 | /usr/bin/grep -q "^Authority=$SIGN_NAME\$"
}

designated_requirement() { /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^.*designated => //p'; }

# After installing a new build locally. If the signing identity is unchanged the
# existing Accessibility grant still applies (TCC checks the designated requirement).
# Otherwise (first switch from ad-hoc) reset the stale entry, relaunch so Handy
# registers again, and ask the owner to switch it on once (macOS asks for a password).
# Returns 0 when the grant carries over, 1 when the owner has to act.
local_accessibility_after_install() {
    local old_app="$1" new_req old_req
    new_req=$(designated_requirement "$APP_PATH")
    if [ -d "$old_app" ] && /usr/bin/codesign --verify -R="$new_req" "$old_app" >/dev/null 2>&1 &&
        /usr/bin/codesign --verify -R="$(designated_requirement "$old_app")" "$APP_PATH" >/dev/null 2>&1; then
        log "Signing requirement unchanged ($new_req); Accessibility grant carries over"
        return 0
    fi
    old_req=$(designated_requirement "$old_app" 2>/dev/null)
    log "Signing requirement changed (old: ${old_req:-none}; new: $new_req); resetting local Accessibility entry"
    /usr/bin/tccutil reset Accessibility "$BUNDLE_ID" >>"$LOG_FILE" 2>&1 || true
    quit_handy
    /usr/bin/open -a "$APP_PATH"
    sleep 5
    /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
    return 1
}
