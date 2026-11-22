#!/bin/bash
# Copy /Applications/Handy.app from this MacBook to the Mac mini whenever it changes.
# Run by LaunchAgent local.handy.mini-sync: WatchPaths on Handy.app's Info.plist,
# plus every hour as a catch-up (mini asleep/offline, screen locked, ...).
# Settings and models on the mini (~/Library/Application Support/com.pais.handy) are never touched.
#
# Usage: sync-mini.sh [--force]   --force copies even if the mini already has this build
set -u
LOG_TAG=mini
. "$(dirname "$0")/common.sh"
LOG_FILE="$LOG_DIR/mini-sync.log"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
TITLE="Handy 同步 Mac mini"
SSH=(/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 "$MINI_HOST")
SYNCED_FILE="$STATE_DIR/mini-synced"
UNREACHABLE_FILE="$STATE_DIR/mini-unreachable-since"

if ! acquire_lock 40; then
    log "Lock still held after 20 minutes; next run will retry"
    exit 0
fi

[ -d "$APP_PATH" ] || { log "No $APP_PATH; nothing to sync"; exit 0; }

# Debounce: wait until the app bundle has been quiet for 60 s.
for _ in $(seq 1 40); do
    age=$(( $(date +%s) - $(stat -f %m "$APP_PATH/Contents/Info.plist") ))
    [ "$age" -ge 60 ] && break
    sleep 15
done

VERSION=$(app_version "$APP_PATH")
CDHASH=$(app_cdhash "$APP_PATH")
[ -n "$CDHASH" ] || { notify "$TITLE" "讀不到本機 Handy.app 的簽章"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP_PATH" >>"$LOG_FILE" 2>&1 ||
    { notify "$TITLE" "本機 Handy.app 簽章驗證失敗，不同步"; exit 1; }

# Mini reachable?
if ! "${SSH[@]}" true 2>>"$LOG_FILE"; then
    now=$(date +%s)
    [ -f "$UNREACHABLE_FILE" ] || echo "$now" >"$UNREACHABLE_FILE"
    since=$(cat "$UNREACHABLE_FILE")
    log "Mini unreachable (since $(date -r "$since" '+%F %T')); retry next hour"
    if [ $((now - since)) -ge 86400 ] && [ ! -f "$UNREACHABLE_FILE.notified" ]; then
        touch "$UNREACHABLE_FILE.notified"
        notify "$TITLE" "Mac mini 已超過一天連不上，Handy 沒同步（會繼續每小時重試）"
    fi
    exit 0
fi
rm -f "$UNREACHABLE_FILE" "$UNREACHABLE_FILE.notified"

# Remote state: version|cdhash|running|tcc  (tcc: 1 = auth_value 2 and the installed app
# satisfies the code requirement TCC stored; 0 = not granted / stale; - = no entry)
remote_state() {
    "${SSH[@]}" "bash -s" <<'REMOTE'
APP=/Applications/Handy.app
v=$(defaults read $APP/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
h=$(codesign -dvvv $APP 2>&1 | sed -n 's/^CDHash=//p')
r=0; pgrep -f "$APP/Contents/MacOS/" >/dev/null && r=1
q="select auth_value||' '||hex(csreq) from access where service='kTCCServiceAccessibility' and client='com.pais.handy'"
row=$(sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "$q" 2>/dev/null)
t=-
if [ -n "$row" ]; then
    t=0
    echo "${row#* }" | xxd -r -p >/tmp/handy-tcc-csreq.bin
    req=$(csreq -r /tmp/handy-tcc-csreq.bin -t 2>/dev/null)
    [ "${row%% *}" = 2 ] && [ -n "$req" ] && codesign --verify -R="$req" $APP 2>/dev/null && t=1
fi
echo "$v|$h|$r|$t"
REMOTE
}

STATE=$(remote_state)
log "Local $VERSION $CDHASH; mini state (version|cdhash|running|tcc) = $STATE"
IFS='|' read -r R_VERSION R_CDHASH R_RUNNING R_TCC <<<"$STATE"
PENDING_GRANT="$STATE_DIR/mini-needs-grant"

NEED_COPY=1
[ "$R_CDHASH" = "$CDHASH" ] && [ "$FORCE" = 0 ] && NEED_COPY=0
if [ "$NEED_COPY" = 0 ]; then
    echo "$VERSION $CDHASH" >"$SYNCED_FILE"
    if [ "$R_TCC" = 1 ]; then
        if [ -f "$PENDING_GRANT" ]; then
            rm -f "$PENDING_GRANT"
            "${SSH[@]}" "osascript -e 'tell application id \"com.pais.handy\" to quit'; sleep 3; open -a /Applications/Handy.app" || true
            notify "$TITLE" "Mac mini 的 Handy 輔助使用已打開（Handy ${VERSION}，已重開）"
        fi
        log "Mini already has this build and Accessibility is OK"
        exit 0
    fi
    if [ -f "$PENDING_GRANT" ]; then
        # Remind once a day while the owner hasn't switched it on yet.
        if [ $(( $(date +%s) - $(stat -f %m "$PENDING_GRANT") )) -ge 86400 ]; then
            touch "$PENDING_GRANT"
            notify "$TITLE" "提醒：Mac mini 的 Handy 輔助使用還沒打開（系統設定 > 隱私權與安全性 > 輔助使用，要密碼）"
        fi
        log "Waiting for the owner to switch Accessibility on on the mini"
        exit 0
    fi
fi

STAGE_DIR='$HOME/.handy-sync'
if [ "$NEED_COPY" = 1 ]; then
    log "Copying Handy $VERSION to $MINI_HOST"
    "${SSH[@]}" "rm -rf $STAGE_DIR/Handy.app && mkdir -p $STAGE_DIR" ||
        { notify "$TITLE" "無法在 mini 建暫存資料夾"; exit 1; }
    if ! /usr/bin/tar -C "$(dirname "$APP_PATH")" -cf - "$(basename "$APP_PATH")" |
        "${SSH[@]}" "tar -C $STAGE_DIR -xf -" 2>>"$LOG_FILE"; then
        "${SSH[@]}" "rm -rf $STAGE_DIR/Handy.app" || true
        notify "$TITLE" "複製 Handy.app 到 mini 失敗（mini 的舊版沒動）"
        exit 1
    fi
    STAGED=$("${SSH[@]}" "codesign -dvvv $STAGE_DIR/Handy.app 2>&1 | sed -n 's/^CDHash=//p'")
    [ "$STAGED" = "$CDHASH" ] || { notify "$TITLE" "複製到 mini 的檔案不完整（cdhash 不符），沒安裝"; exit 1; }
fi

# Install on the mini, restart Handy, check Accessibility against TCC.db.
OUT=$("${SSH[@]}" "bash -s $NEED_COPY" <"$AU_DIR/mini-install.sh" 2>&1)
RC=$?
echo "$OUT" | sed 's/^/    mini: /' >>"$LOG_FILE"
if [ "$RC" = 5 ]; then
    touch "$PENDING_GRANT"
    notify "$TITLE" "Mac mini 已裝 Handy ${VERSION}，但輔助使用要手動打開一次：在 mini 的系統設定 > 隱私權與安全性 > 輔助使用打開 Handy（要密碼）。之後每小時會檢查。"
    exit 0
elif [ "$RC" != 0 ]; then
    MSG=$(echo "$OUT" | sed -n 's/^ERROR //p' | tail -1)
    notify "$TITLE" "失敗：${MSG:-ssh 執行中斷 (exit $RC)}"
    exit 1
fi

STATE=$(remote_state)
log "After sync mini state = $STATE"
IFS='|' read -r R_VERSION R_CDHASH R_RUNNING R_TCC <<<"$STATE"
if [ "$R_CDHASH" = "$CDHASH" ] && [ "$R_RUNNING" = 1 ] && [ "$R_TCC" = 1 ]; then
    echo "$VERSION $CDHASH" >"$SYNCED_FILE"
    rm -f "$PENDING_GRANT"
    [ "$NEED_COPY" = 1 ] && notify "$TITLE" "Mac mini 已更新到 Handy ${VERSION}，正在執行、輔助使用沿用"
    log "Sync OK"
else
    notify "$TITLE" "同步後檢查不符：$STATE"
    exit 1
fi
