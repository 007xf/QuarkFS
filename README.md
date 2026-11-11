# QuarkFS for macOS

English | [简体中文](README.zh-CN.md)

QuarkFS is an unofficial macOS menu-bar app that makes Quark Drive (夸克网盘) available, read-only, to Finder, Infuse and other players that open local files. It has two independent read paths:

```text
Finder / other local-file apps ──► macFUSE mount ──► bundled rclone engine ──► Quark
Infuse ─────────────────────────► read-only WebDAV on 127.0.0.1:8686 ──► same engine ──► Quark
```

The second path exists because Infuse does not accept a macFUSE folder as a media source. The WebDAV server binds to the loopback address only, so it is not reachable from the local network. It requires a user name and a password generated on this Mac, so other users, sandboxed apps and web pages cannot read it anonymously. QuarkFS stops the bridge process when it quits, and stops a leftover bridge the next time it starts after a crash.

> **Security notice:** versions 1.0.0 to 1.1.2 served the local WebDAV without authentication. Upgrade to 1.1.3 or later. See [GHSA-vv59-62m4-xmr6](https://github.com/007xf/QuarkFS/security/advisories/GHSA-vv59-62m4-xmr6).

## Features

- Menu-bar app using the native macOS `atom` symbol.
- Read-only macFUSE mount, at `~/Quark` by default.
- Read-only local WebDAV that starts automatically, at `http://127.0.0.1:8686` by default. It can be started and stopped on its own, the port can be changed, and there are buttons to copy the connection details and to open Infuse.
- A connection shows "Ready" only after a real WebDAV directory check passes. A busy port or a failed login is reported as an error. During playback, a download refused by Quark (for example code 23018, the download size limit), an expired login or repeated read failures are shown in the connection area, the menu bar and the activity log.
- The mount folder is chosen with a picker and applied explicitly. Folders that contain files, or that overlap the app's own data, are refused. No folder is created while you type.
- "First-time setup" is shown only while a component or the account is not ready, and hides once everything is fine. "Components & account" in the top-right corner opens it again, and is where you log out.
- Log in by scanning a QR code or by pasting a Cookie. The login is stored only in the macOS Keychain, never in the repository or in a plain-text configuration file.
- Three cache policies, "No residue", "Balanced" and "High performance", plus a dedicated cache cleaner.
- Default shortcuts: `⌥⌘O` show window, `⌥⌘E` mount/unmount, `⌥⌘F` open in Finder, `⌥⌘R` re-check, `⌥⌘K` clear cache.
- A shortcut recorder: click the field and press the keys. Esc cancels, Delete clears, and a combination already in use is refused.
- The app and the bundled engine are built for Apple Silicon (arm64).

The app's interface is in Simplified Chinese. The Chinese labels are given in parentheses below where you need to find a button.

## Quick start

### Use the release package

1. You need an Apple Silicon (M-series) Mac running macOS 14 or later.
2. For the Finder mount, install [macFUSE](https://macfuse.github.io/), allow the system extension when macOS asks, and restart. Skip this step if you only use the Infuse connection.
3. Download `QuarkFS-macOS-arm64.zip` from [GitHub Releases](https://github.com/007xf/QuarkFS/releases/latest), unzip it, and drag `QuarkFS.app` into Applications.
4. The package is ad-hoc signed and not notarized with an Apple Developer ID, so Gatekeeper blocks the first launch. On macOS 15 and later: double-click the app once, then go to System Settings → Privacy & Security, click "Open Anyway" at the bottom and confirm (right-click → Open no longer works from macOS 15). On macOS 14: right-click the app in Finder and choose Open.
5. Open QuarkFS and scan the QR code to log in to Quark. The Infuse connection starts automatically. For Finder, click "Mount Quark" (挂载 Quark) once the checks pass.
6. In Infuse, add a WebDAV share: server `127.0.0.1`, port `8686`, path `/`, user name `quarkfs`, and the password from "Copy connection info" (复制连接信息) in QuarkFS. You can also just use `~/Quark` in Finder.

### Build from source

Requirements:

- macOS 14 or later;
- Xcode Command Line Tools (for the Swift 6 toolchain);
- Go 1.22 or later (only to build the bundled engine);
- macFUSE (only for the Finder mount; the WebDAV path builds and runs without it).

Double-click these in Finder, in order, or run them in a terminal:

1. `Scripts/01 构建引擎.command` downloads the pinned, checksum-verified rclone source and builds the Apple Silicon engine.
2. `Scripts/02 打包应用.command` runs the core smoke tests, compiles the app, signs it and produces `.build/QuarkFS.app`.
3. `Scripts/03 生成发布包.command` produces the ZIP and its SHA-256 file.

To install or upgrade on your own Mac, run `Scripts/05 安全安装升级.command`. It checks that the app has quit, verifies the new package, saves the old version as a ZIP that is compared after extraction, and then replaces `/Applications/QuarkFS.app`. Do not keep an unpacked old copy such as `QuarkFS 1.x.app` in Documents, Downloads or a backup folder, because Spotlight will index it as a second launch target. The ZIPs in `01 升级备份` at the project root can be used to roll back. They survive build cleaning and are not committed to Git. Your account and settings stay where they were.

Only Apple Silicon is supported. Intel builds are no longer produced.

## Infuse setup

Once QuarkFS is running and logged in, the read-only WebDAV starts automatically. Fill in Infuse as follows:

| Field | Value |
| --- | --- |
| Type | WebDAV |
| Address | `127.0.0.1` |
| Port | `8686` |
| Path | `/` |
| HTTPS | Off |
| User name / password | `quarkfs` / from "Copy connection info" (generated at random on first launch on each Mac, and unchanged afterwards) |

The connection area has "Copy connection info" and "Open Infuse" buttons. The copied text contains the user name and the password. The password is stored only in `~/Library/Application Support/com.holmes.QuarkFS/WebDAV-Credentials.json`, readable by the current user only. It is passed to the engine through environment variables, so it does not appear in the process arguments.

If the port is taken, enter another port between 1024 and 65535, click "Apply port" (应用端口), and change the port in Infuse to match. A port already used by another program is refused before the running connection is touched. "Stop" (停止) closes only the Infuse connection and leaves the Finder mount alone. Reopening the window keeps the stopped state for the current run. The connection starts again the next time the app launches.

If Infuse shows no folders, check that "Infuse local connection" in QuarkFS says "Ready", then click "Restart". Do not enter `~/Quark` as a network address in Infuse.

### Large files

Quark refuses to serve large files through this download interface (code 23018, "download file size limit"). QuarkFS reports this with the file name instead of failing silently. **Such files cannot be read through QuarkFS for now.** If the login has expired, log out under "Components & account" and scan the QR code again.

### Mount failures

Since 1.1.1, a failed mount is explained from the engine's output and the new log lines. On a macFUSE "Resource busy / error 16", QuarkFS retries once after a short wait, and only when it has confirmed that the engine has exited and nothing is mounted at the target. If that fails as well, the message stays on screen. If the engine has exited but the Quark mount is still present, the app says that action is needed: close the windows or players using the disk, click "Unmount Quark" (卸载 Quark), then mount again. Unmounting waits until the system confirms the mount is gone and the engine has exited. While the mount state cannot be read, mounting, cache cleaning and quitting are paused. The app never force-unmounts other disks and never deletes files in the mount folder.

Since 1.1.1, a second QuarkFS instance is blocked before any connection is set up; opening the app again only activates the running one. A macFUSE "resource busy" error can also be a temporary system state. If it persists after re-checking and retrying, quit the app and restart the Mac.

## Cache and security boundaries

Both the mount and the WebDAV server are read-only and refuse writes to the drive. The two read paths use separate cache folders. Each applies its own soft limit, about 5 GB for "Balanced" and about 20 GB for "High performance", and read-ahead memory is counted per open file. A file being read can exceed the soft limit. When the cache policy changes, the local WebDAV restarts safely with the new settings.

```text
~/Library/Application Support/com.holmes.QuarkFS
├── Cache
│   ├── Mount
│   └── Infuse
└── Runtime
    └── rclone.conf
```

- The runtime configuration is kept in a folder only the current user can access. It is deleted on a normal quit, and on the next launch after a crash.
- With automatic cleaning or the "No residue" policy, the disk cache is cleared on quit as well.
- The cache cleaner refuses symbolic links at the root or in intermediate folders, so it cannot delete outside its own directory.
- If the mounted disk is in use and cannot be unmounted, the app cancels quitting and keeps the connection.
- During QR login the cookies are held in a separate in-memory store. They are saved to the Keychain only after the drive session has been verified.
- Engine logs record NOTICE level and above. Each log rotates at 10 MB and keeps one backup. Logs can contain network errors and file paths, so check and redact them before attaching them to an issue.

The first time the Keychain asks, enter your Mac login password and choose "Always Allow". The app reuses the converted credential for the rest of the run, so mounting, unmounting and remounting do not read the Keychain again. After an upgrade, macOS may treat an ad-hoc signed build as a new app and ask once more.

## Project layout

```text
Package.swift                 Swift Package entry point
Sources/QuarkFS               SwiftUI window, menu bar, shortcuts, lifecycle
Sources/QuarkFSCore           Mount plans, Keychain, cache, engine lookup
Sources/QuarkFSSmokeTests     Core smoke tests that need no account
Resources/                    App icon, Info.plist
Scripts/01 构建引擎.command   Download, verify and build rclone (arm64)
Scripts/02 打包应用.command   Test, compile and sign the app
Scripts/03 生成发布包.command Produce the ZIP and SHA-256
.github/workflows/ci.yml      Apple Silicon build check on GitHub
```

## Acknowledgements

The SwiftUI control panel, cache boundaries, Keychain wrapper, Infuse WebDAV lifecycle and packaging scripts are original code in this repository. Mounting and drive access come from a separately built rclone engine. QuarkFS is not an official project of Quark, Infuse, rclone or macFUSE.

- [rclone/rclone](https://github.com/rclone/rclone): the command-line sync tool and its VFS, FUSE and WebDAV features.
- [Quark Drive backend PR #9662](https://github.com/rclone/rclone/pull/9662): the public discussion and source of the Quark backend. The PR was still a draft when this project pinned it.
- [zly2006/rclone@47a62e1](https://github.com/zly2006/rclone/tree/47a62e1b6081b5b65664e5e8f2fa7477eba9bd6f): the exact commit this project builds. The build script also verifies the archive's SHA-256, so it never follows a moving branch.
- [Cgofuse](https://github.com/winfsp/cgofuse): the FUSE binding rclone uses on macOS, under its MIT license.
- [macFUSE](https://github.com/macfuse/macfuse): a system extension you install yourself. This project does not redistribute it and does not bypass the macOS system-extension security policy.

Component details and license links are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) (Chinese). The original code is under the [MIT License](LICENSE). Risks and responsibilities are described in the [disclaimer](04%20免责声明.md) (Chinese).

## Development checks

- `swift run --disable-sandbox --build-system native QuarkFSSmokeTests`: large process output and timeouts, cache symbolic links, mount paths, migration of old settings, WebDAV responses and login-failure regressions.
- `Scripts/04 检查应用行为.command`: uses a local test server to check start, stop, port change, cache cleaning, logout and app quit. No real account is used.
- `Scripts/06 检查单实例.command`: uses separate processes to check the simultaneous-launch guard, lock recovery after a crash, normal release and refusal of symbolic links.
- `zsh Tests/QuarkFSCoreTests/ScriptChecks.zsh`: in a temporary folder, checks that the test scripts link only current sources, that the release script refuses an engine without `cmount`, the installer's validation messages and interrupt recovery, and the Gatekeeper instructions. It does not run the installer itself.
- After building the engine, `python3 Tests/QuarkFSCoreTests/EngineIntegration.py .build/engine/rclone --mount` uses temporary files to check runtime-configuration parsing, WebDAV authentication, ranged reads, read-only protection, log options and the macFUSE mount.
- On a Mac with macFUSE installed and allowed, you can also run `QUARKFS_TEST_REAL_ENGINE_PATH="$PWD/.build/engine/rclone" QUARKFS_TEST_BUSY_FIRST=1 "Scripts/04 检查应用行为.command"`. It mounts temporary local files with the real engine through AppModel and checks reading, unmounting, remounting, repeated-click exclusion, the single EBUSY retry, and error capture across six quick failures in a row. It does not read a real Quark account, mounts only the temporary folder it created, and tries a normal exit first on failure.
- GitHub CI runs the account-free regression checks and compiles the Apple Silicon build.

Changes are listed in the [changelog](05%20更新记录.md) (Chinese).

## Known limitations

- Large files that Quark refuses with code 23018 cannot be read (see [Large files](#large-files)).
- The Quark Drive backend depends on Quark's web interface and a full browser Cookie. Changes to the interface, to risk control or to account policy can force a new login or make the drive unavailable for a while.
- The upstream Quark backend is still a draft PR, which is why the version is pinned. Re-read the upstream license and changes before updating it.
- Approval of the macFUSE system extension is controlled by macOS. QuarkFS cannot approve it for you, and it is not a substitute for Apple Developer ID signing and notarization.
- Shortcuts are in-app menu shortcuts. No global event monitor is registered, so they work only while QuarkFS is the active app and never take over another app's global shortcuts.

## License

The original code is under the MIT License. The rclone engine in the release package is a separate component, copyright its authors and under rclone's own MIT license. Keep its copyright and permission notice when you redistribute the package. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
