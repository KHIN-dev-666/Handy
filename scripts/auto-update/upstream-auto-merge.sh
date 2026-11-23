#!/bin/bash
# Weekly job: when cjpais/Handy publishes a new release, merge it into the fork's
# target branch, run the checks, build the macOS app (ad-hoc signed), install it
# to /Applications and push. The fixed certificate keeps the
# Accessibility grant across rebuilds (ad-hoc signatures don't). Anything fails => undo the
# merge, install nothing, Mac notification, details in the log.
#
# Usage: upstream-auto-merge.sh [options]
#   --branch NAME   target branch (default: $HANDY_TARGET_BRANCH or cloud-stt)
#   --tag TAG       use this upstream tag instead of the latest release
#   --ref REF       merge an arbitrary ref instead of an upstream tag (testing)
#   --dry-run       merge + checks + build, then reset the branch; no install, no push
#   --skip-tests    skip the checks (testing only)
#   --no-push       install but don't push
set -u
LOG_TAG=merge
. "$(dirname "$0")/common.sh"
LOG_FILE="$LOG_DIR/upstream-auto-merge.log"

BRANCH="${HANDY_TARGET_BRANCH:-cloud-stt}"
TAG=""
REF=""
DRY_RUN=0
SKIP_TESTS=0
NO_PUSH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) BRANCH="$2"; shift ;;
        --tag) TAG="$2"; shift ;;
        --ref) REF="$2"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        --skip-tests) SKIP_TESTS=1 ;;
        --no-push) NO_PUSH=1 ;;
        *) echo "unknown option $1" >&2; exit 64 ;;
    esac
    shift
done

TITLE="Handy 自動更新"
[ "$DRY_RUN" = 1 ] && TITLE="Handy 自動更新（演練）"

log "===== start branch=$BRANCH tag=${TAG:-latest} ref=${REF:-} dry_run=$DRY_RUN ====="

if ! acquire_lock 40; then
    log "Another auto-update job holds the lock; exiting"
    exit 0
fi

cd "$REPO_DIR" || { notify "$TITLE" "找不到 repo：$REPO_DIR"; exit 1; }

ORIG_BRANCH=$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)
PRE_MERGE=""
MERGED=0
HANDY_STOPPED=0

restore() {
    # Undo a finished merge commit (local only, never pushed) and go back to the original branch.
    if [ "$MERGED" = 1 ] && [ -n "$PRE_MERGE" ]; then
        git reset -q --hard "$PRE_MERGE" && log "Reset $BRANCH back to $PRE_MERGE"
    fi
    if [ "$(git symbolic-ref --quiet --short HEAD || true)" != "$ORIG_BRANCH" ]; then
        git checkout -q "$ORIG_BRANCH" && log "Checked out $ORIG_BRANCH again"
    fi
}

fail() {
    # fail "where it stopped" "detail"
    log "FAILED at: $1 — $2"
    restore
    # If Handy was already stopped for the install, bring the installed app back up.
    if [ "$HANDY_STOPPED" = 1 ] && [ -d "$APP_PATH" ]; then /usr/bin/open -a "$APP_PATH" || true; fi
    notify "$TITLE 卡住" "$1：$2（細節見 ~/Library/Logs/handy-auto-update/upstream-auto-merge.log）"
    log "===== end (failed) ====="
    exit 1
}

# 1. Which release?
if [ -n "$REF" ]; then
    MERGE_REF="$REF"
    LABEL="$REF"
else
    if [ -z "$TAG" ]; then
        TAG=$(/usr/bin/curl -fsSL --retry 2 --max-time 30 https://api.github.com/repos/cjpais/Handy/releases/latest |
            /usr/bin/plutil -extract tag_name raw -o - - 2>/dev/null) ||
            { log "Could not read the latest release from GitHub; will try next week"; log "===== end ====="; exit 0; }
    fi
    git check-ref-format "refs/tags/$TAG" || fail "讀版本號" "官方 tag 名稱不合法：$TAG"
    run_logged "fetch upstream tag" git fetch --no-tags upstream "refs/tags/$TAG:refs/tags/$TAG" ||
        fail "抓官方版本" "git fetch upstream $TAG 失敗"
    MERGE_REF="refs/tags/$TAG"
    LABEL="$TAG"
fi

# 2. Working tree must be clean (tracked files) before we touch anything.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    fail "開始前檢查" "$REPO_DIR 有未 commit 的修改，沒有動作"
fi

if [ "$ORIG_BRANCH" != "$BRANCH" ]; then
    git checkout -q "$BRANCH" || fail "切換分支" "無法切到 $BRANCH"
fi

if git merge-base --is-ancestor "$MERGE_REF" HEAD; then
    log "$BRANCH already contains $LABEL; nothing to do"
    restore
    log "===== end (current) ====="
    exit 0
fi

# 3. Keep the local branch in step with origin (fast-forward only).
if [ "$DRY_RUN" = 0 ] && git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    run_logged "fetch origin" git fetch origin "$BRANCH" || fail "抓 fork" "git fetch origin $BRANCH 失敗"
    if git rev-parse --verify -q "origin/$BRANCH" >/dev/null; then
        if ! git merge-base --is-ancestor "origin/$BRANCH" HEAD; then
            git merge -q --ff-only "origin/$BRANCH" >>"$LOG_FILE" 2>&1 ||
                fail "同步 fork" "本機 $BRANCH 與 origin/$BRANCH 分岔，需要手動處理"
        fi
    fi
fi

PRE_MERGE=$(git rev-parse HEAD)
log "Merging $LABEL into $BRANCH at $PRE_MERGE"

# 4. Merge. Conflicts are never resolved automatically.
if ! git merge --no-edit -m "Merge upstream release $LABEL into $BRANCH" "$MERGE_REF" >>"$LOG_FILE" 2>&1; then
    CONFLICTS=$(git diff --name-only --diff-filter=U | head -5 | tr '\n' ' ')
    git diff --name-only --diff-filter=U >>"$LOG_FILE"
    git merge --abort >>"$LOG_FILE" 2>&1
    fail "合併 $LABEL 有衝突" "要手動處理的檔案：${CONFLICTS:-（見 log）}，已 merge --abort，什麼都沒裝"
fi
MERGED=1
log "Merged: $(git rev-parse HEAD)"

# 5. Checks (same as the repo's CI: code-quality.yml + test.yml).
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# A Command Line Tools update moves clang's resource dir, but cargo keeps the
# cached build.rs output (link-search for libclang_rt.osx.a) pointing at the old
# one. If any cached link-search path of the handy crate is gone, rebuild it.
for profile in debug release; do
    for out in "$REPO_DIR"/src-tauri/target/$profile/build/handy/*/run/stdout "$REPO_DIR"/src-tauri/target/$profile/build/handy-[0-9a-f]*/output; do
        [ -f "$out" ] || continue
        if sed -n 's/^cargo:rustc-link-search=native=//p' "$out" | while read -r d; do [ -d "$d" ] || exit 1; done; then :; else
            log "Stale toolchain path in $out; cleaning handy ($profile)"
            flag=""; [ "$profile" = release ] && flag="--release"
            (cd src-tauri && cargo clean -p handy $flag) >>"$LOG_FILE" 2>&1
            break
        fi
    done
done
run_logged "bun install" bun install --frozen-lockfile || fail "安裝套件" "bun install 失敗"
if [ "$SKIP_TESTS" = 0 ]; then
    for check in check:translations check:model-languages check:catalog test:keyboard lint format:check; do
        run_logged "$check" bun run "$check" || fail "測試" "bun run $check 失敗"
    done
    (cd src-tauri && run_logged "cargo test" cargo test) || fail "測試" "cargo test 失敗"
fi

# 6. Build the .app only (no updater artifacts: they need upstream's signing key).
run_logged "tauri build" bun run tauri build --bundles app --config '{"bundle":{"createUpdaterArtifacts":false}}' ||
    fail "編譯" "tauri build 失敗"
BUILT="$REPO_DIR/src-tauri/target/release/bundle/macos/Handy.app"
[ -d "$BUILT" ] || fail "編譯" "找不到 $BUILT"
sign_app "$BUILT" || fail "簽章" "用「Handy Local Signing」簽章失敗（先跑 scripts/auto-update/setup-signing.sh）"
NEW_VERSION=$(app_version "$BUILT")
log "Built $NEW_VERSION cdhash=$(app_cdhash "$BUILT")"

# The first install of a certificate-signed build changes the signing identity, so the
# owner has to switch Accessibility on once (password). Until they've done that switch
# deliberately (touch "$STATE_DIR/signing-switched"), behave like a dry run.
if [ "$DRY_RUN" = 0 ] && [ ! -f "$STATE_DIR/signing-switched" ] &&
    ! /usr/bin/codesign -dvv "$APP_PATH" 2>&1 | grep -q "^Authority=$SIGN_NAME\$"; then
    log "Installed app is not signed with $SIGN_NAME and the switch isn't done yet; not installing"
    restore
    notify "$TITLE" "官方 $LABEL 已合併、測試、編譯都通過，但還沒切換到本機憑證簽章，所以沒安裝（下週再試）"
    log "===== end (waiting for signing switch) ====="
    exit 0
fi

if [ "$DRY_RUN" = 1 ]; then
    log "Dry run: merge, checks and build passed; not installing or pushing"
    restore
    notify "$TITLE" "演練成功：$LABEL 合併、測試、編譯都通過（未安裝、未 push）"
    log "===== end (dry run ok) ====="
    exit 0
fi

# 7. Install: quit Handy, keep one backup, copy the new app in.
BACKUP="$STATE_DIR/backup/Handy.app"
mkdir -p "$STATE_DIR/backup"
quit_handy
HANDY_STOPPED=1
if [ -d "$APP_PATH" ]; then
    rm -rf "$BACKUP"
    /usr/bin/ditto "$APP_PATH" "$BACKUP" || fail "備份舊版" "無法備份 $APP_PATH"
    log "Backed up old app ($(app_version "$BACKUP")) to $BACKUP"
fi
STAGE="$APP_PATH.new"
rm -rf "$STAGE"
if ! /usr/bin/ditto "$BUILT" "$STAGE" || ! rm -rf "$APP_PATH" || ! mv "$STAGE" "$APP_PATH"; then
    rm -rf "$STAGE"
    [ -d "$APP_PATH" ] || /usr/bin/ditto "$BACKUP" "$APP_PATH"
    fail "安裝" "複製到 $APP_PATH 失敗，已還原舊版"
fi
MERGED=0 # installed; from here on the merge is kept
log "Installed $NEW_VERSION to $APP_PATH"
/usr/bin/open -a "$APP_PATH"
sleep 3

# 8. Accessibility: carried over unless the signing identity changed.
if local_accessibility_after_install "$BACKUP"; then
    AX_MSG="輔助使用權限沿用"
else
    AX_MSG="簽章身分換了，請到「系統設定 > 隱私權與安全性 > 輔助使用」把 Handy 打開一次（要密碼）"
    notify "$TITLE" "$AX_MSG"
fi

# 9. Push (fast-forward only, never forced).
PUSH_MSG="已 push"
if [ "$NO_PUSH" = 1 ]; then
    PUSH_MSG="未 push（--no-push）"
elif ! run_logged "push" git push origin "$BRANCH"; then
    PUSH_MSG="push 失敗，請手動 git push origin $BRANCH"
    notify "$TITLE" "$PUSH_MSG"
fi

restore
notify "$TITLE" "已合併並安裝 ${LABEL}（${NEW_VERSION}）。${AX_MSG}；${PUSH_MSG}"
log "===== end (installed) ====="
