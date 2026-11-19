#!/bin/sh
# Check the latest stable release against the tags included in this fork.
set -eu
cd "$(dirname "$0")/.."
tag=$(/usr/bin/curl -fsSL --retry 2 --max-time 30 https://api.github.com/repos/cjpais/Handy/releases/latest | /usr/bin/plutil -extract tag_name raw -o - -)
/usr/bin/git check-ref-format "refs/tags/$tag"
if /usr/bin/git merge-base --is-ancestor "refs/tags/$tag" HEAD 2>/dev/null; then
    echo "Handy is current with upstream release $tag"
else
    echo "Review upstream release https://github.com/cjpais/Handy/releases/tag/$tag"
    /usr/bin/osascript - "$tag" <<'APPLESCRIPT'
on run argv
    display notification ("官方已發布 " & item 1 of argv & "，可查看版本說明並評估合併。") with title "Handy 更新"
end run
APPLESCRIPT
fi
