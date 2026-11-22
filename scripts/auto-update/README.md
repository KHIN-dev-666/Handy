# Fork auto-update (MacBook → Mac mini)

Personal automation for this fork. Not part of upstream Handy.

| LaunchAgent                    | When                                                                  | Script                                              | Log                                                        |
| ------------------------------ | --------------------------------------------------------------------- | --------------------------------------------------- | ---------------------------------------------------------- |
| `local.handy.upstream-release` | Mondays 10:00                                                         | `upstream-auto-merge.sh`                            | `~/Library/Logs/handy-auto-update/upstream-auto-merge.log` |
| `local.handy.mini-sync`        | `/Applications/Handy.app/Contents/Info.plist` changes, and every hour | `sync-mini.sh` (runs `mini-install.sh` on the mini) | `~/Library/Logs/handy-auto-update/mini-sync.log`           |

**upstream-auto-merge.sh**: when there's a new cjpais/Handy release tag, it merges it into the target branch (`HANDY_TARGET_BRANCH`, default `cloud-stt`). Then it runs the CI checks (`check:*`, `test:keyboard`, `lint`, `format:check`, `cargo test`) and builds the `.app`. It signs the app with the local "Handy Local Signing" certificate, installs it to `/Applications` (the previous app is kept in `~/Library/Application Support/handy-auto-update/backup/`), relaunches Handy and pushes to origin.

If the merge conflicts, or a check or the build fails, it runs `merge --abort` (or resets the branch to the commit before the merge), installs nothing and sends a Mac notification. Conflicts are never resolved automatically.

**sync-mini.sh**: copies `Handy.app` to `my-mac` with tar. It doesn't touch the mini's settings or models. It then removes the quarantine attribute, restarts Handy and checks the Accessibility grant in the mini's TCC.db. If the mini is offline, the hourly run tries again.

## Why a local signing certificate

An ad-hoc signature's designated requirement is the cdhash, which changes on every build, so macOS drops the Accessibility grant each time. Switching that grant on in System Settings always asks for a password, so it can't be automated.

A fixed self-signed certificate gives the requirement `identifier "com.pais.handy" and certificate leaf = H"…"`, which every rebuild satisfies. The grant then only has to be switched on once per Mac.

Run `setup-signing.sh` once to create it. It lives in `~/Library/Application Support/handy-auto-update/signing/`; back that folder up.

## Testing

```sh
# full pipeline on a scratch branch, without installing or pushing
scripts/auto-update/upstream-auto-merge.sh --branch some-test-branch --ref <ref> --dry-run
scripts/auto-update/sync-mini.sh --force   # re-copy even if the mini already has this build
```

## Disable

```sh
launchctl bootout gui/$(id -u)/local.handy.upstream-release
launchctl bootout gui/$(id -u)/local.handy.mini-sync
```

Re-enable with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<label>.plist`. The plists are copies of `launchagents/`.
