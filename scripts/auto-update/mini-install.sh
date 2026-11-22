#!/bin/bash
# Runs ON the Mac mini (sent over ssh by sync-mini.sh): install the staged Handy.app,
# restart it and check its Accessibility grant in TCC.db.
# Arg 1: 1 = install ~/.handy-sync/Handy.app first, 0 = only check/restart.
# Exit: 0 ok, 5 owner must switch Accessibility on once (macOS asks for a password), other = error.
set -u
NEED_COPY=$1
APP=/Applications/Handy.app
S=$HOME/.handy-sync
TCC="/Library/Application Support/com.apple.TCC/TCC.db"
Q="select auth_value||' '||hex(csreq) from access where service='kTCCServiceAccessibility' and client='com.pais.handy'"
say() { echo "STEP $*"; }
quit_handy() {
    osascript -e 'tell application id "com.pais.handy" to quit' >/dev/null 2>&1
    for _ in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/" >/dev/null || return 0; sleep 0.5; done
    pkill -f "$APP/Contents/MacOS/"; sleep 1
}
# Prints granted / denied / stale / missing
tcc_state() {
    local row req
    row=$(sqlite3 "$TCC" "$Q") || { echo unreadable; return; }
    [ -n "$row" ] || { echo missing; return; }
    echo "${row#* }" | xxd -r -p >/tmp/handy-tcc-csreq.bin
    req=$(csreq -r /tmp/handy-tcc-csreq.bin -t 2>/dev/null)
    if [ -z "$req" ] || ! codesign --verify -R="$req" $APP 2>/dev/null; then echo stale; return; fi
    [ "${row%% *}" = 2 ] && echo granted || echo denied
}

quit_handy
if [ "$NEED_COPY" = 1 ]; then
    rm -rf "$S/Handy.app.prev"
    if [ -d $APP ]; then mv $APP "$S/Handy.app.prev" || { echo "ERROR 無法移走舊版"; exit 1; }; fi
    if ! mv "$S/Handy.app" $APP; then
        [ -d "$S/Handy.app.prev" ] && mv "$S/Handy.app.prev" $APP
        open -a $APP; echo "ERROR 無法安裝新版，已還原舊版"; exit 1
    fi
    xattr -dr com.apple.quarantine $APP 2>/dev/null
    say "installed $(defaults read $APP/Contents/Info.plist CFBundleShortVersionString) ($(codesign -dvv $APP 2>&1 | sed -n 's/^Authority=//p' | head -1))"
fi

state=$(tcc_state)
say "tcc before launch: $state"
if [ "$state" = stale ]; then
    # Entry was recorded for a different signature: drop it so Handy registers this build.
    tccutil reset Accessibility com.pais.handy
    say "tccutil reset (stale entry)"
fi
open -a $APP; sleep 6
pgrep -f "$APP/Contents/MacOS/" >/dev/null || { echo "ERROR Handy 沒有在跑"; exit 4; }
say "running"
state=$(tcc_state)
say "tcc after launch: $state"
case "$state" in
    granted) echo OK ;;
    unreadable) echo "ERROR 讀不到 mini 的 TCC.db"; exit 2 ;;
    *) open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
       echo "NEEDS_GRANT"; exit 5 ;;
esac
