# QuarkFS for macOS

QuarkFS 是一个非官方的 macOS 菜单栏工具，把夸克网盘以只读方式提供给 Finder、Infuse 和其他支持本地文件的播放器。它包含两条互相独立的读取路径：

```text
Finder / 其他本地文件应用 ──► macFUSE 挂载 ──► QuarkFS 内置 rclone 引擎 ──► 夸克
Infuse ───────────────────► 127.0.0.1:8686 只读 WebDAV ──► 同一个引擎 ──► 夸克
```

第二条路径解决了 Infuse 不接受 macFUSE 本地目录作为媒体来源的问题。WebDAV 只绑定到本机回环地址，不对局域网开放；QuarkFS 退出时会关闭桥接进程。

## 现在能做什么

- 菜单栏常驻入口，使用 macOS 原生 `atom` 符号，避免图标白边和过度拥挤。
- 只读 macFUSE 挂载，默认目录为 `~/Quark`。
- 自动启动本机只读 WebDAV：`http://127.0.0.1:8686`，供 Infuse 读取。
- 扫码登录或粘贴 Cookie；登录信息只存储在 macOS 钥匙串，不写入仓库或普通明文配置。
- “零残留 / 平衡 / 高性能”三档缓存策略，以及专用缓存清理。
- 默认快捷键：`⌥⌘O` 显示窗口、`⌥⌘E` 挂载/卸载、`⌥⌘F` 打开 Finder、`⌥⌘R` 重新检查、`⌥⌘K` 清理缓存。
- Bob 风格的快捷键录制页：点击组合框后直接按键，修饰键高亮；Esc 取消、Delete 清除、重复组合拒绝保存。
- 应用和内置引擎均可生成 `arm64 + x86_64` 通用版本。

## 最快开始

### 直接使用发布包

1. 使用 macOS 14 或更高版本。
2. 安装 [macFUSE](https://macfuse.github.io/)，按“隐私与安全性”中的提示允许系统扩展，必要时重启。
3. 下载 `QuarkFS-macOS-universal.zip`，解压后把 `QuarkFS.app` 拖入“应用程序”。
4. 第一次打开若被 Gatekeeper 拦截，在 Finder 中右键 App，选择“打开”。当前包为本地 ad-hoc 签名，尚未使用 Apple Developer ID 公证。
5. 打开 QuarkFS，扫码登录夸克；待检查项变绿后点击“挂载 Quark”。
6. 在 Infuse 中添加 WebDAV：服务器 `127.0.0.1`，端口 `8686`，路径 `/`，用户名和密码留空。也可以只使用 Finder 中的 `~/Quark`。

### 从源码构建

源码构建需要：

- macOS 14 或更高版本；
- Xcode Command Line Tools（提供 Swift 6 工具链）；
- Go 1.22 或更高版本（只在构建内置引擎时需要）；
- macFUSE（要使用 Finder/macFUSE 挂载时需要；没有它仍可构建和运行 WebDAV 读取路径）。

在 Finder 中按顺序双击：

1. `Scripts/01 构建引擎.command`：下载已锁定并校验的 rclone 源码，构建两个架构并合并为通用引擎；
2. `Scripts/02 打包应用.command`：运行核心冒烟测试，编译两个架构，签名并生成 `.build/QuarkFS.app`；
3. `Scripts/03 生成发布包.command`：生成通用 ZIP 和 SHA-256 校验文件。

也可以在终端运行同名脚本。若只需单架构调试，可设置 `QUARKFS_ARCHS="arm64"` 或 `QUARKFS_ARCHS="x86_64"`。

## Infuse 配置

QuarkFS 运行并完成登录后，会自动启动只读 WebDAV。Infuse 的字段填写如下：

| 字段 | 值 |
| --- | --- |
| 类型 | WebDAV |
| 地址 | `127.0.0.1` |
| 端口 | `8686` |
| 路径 | `/` |
| HTTPS | 关闭 |
| 用户名 / 密码 | 留空 |

如果 Infuse 看不到目录，先回到 QuarkFS 确认“Infuse 本机连接”显示“已就绪”，再点“重新启动”；不要把 `~/Quark` 当作 Infuse 的网络地址。

## 缓存与安全边界

QuarkFS 只读挂载和只读 WebDAV 都会把写入操作拒绝给上游网盘。零残留模式关闭视频磁盘缓存；平衡和高性能模式只使用应用自己的目录：

```text
~/Library/Application Support/com.holmes.QuarkFS/Cache
~/Library/Application Support/com.holmes.QuarkFS/Runtime/rclone.conf
```

运行期配置在进程退出时删除，缓存清理器会校验目录必须位于上述应用支持目录内，不会递归删除用户的其他文件。Cookie 由 macOS 钥匙串保护；日志可能包含网络错误和文件路径，请在提交 Issue 前自行检查并脱敏。

## 项目结构

```text
Package.swift                 Swift Package 入口
Sources/QuarkFS               SwiftUI 窗口、菜单栏、快捷键与生命周期
Sources/QuarkFSCore           挂载计划、钥匙串、缓存、引擎定位
Sources/QuarkFSSmokeTests     不依赖账号的核心冒烟测试
Resources/                    App 图标、Info.plist
Scripts/01 构建引擎.command   下载校验并构建 rclone（arm64/x86_64）
Scripts/02 打包应用.command   测试、编译、合并、签名 App
Scripts/03 生成发布包.command 生成 ZIP 与 SHA-256
.github/workflows/ci.yml      GitHub 上的双架构编译检查
```

## 开源致谢

本项目的 SwiftUI 控制面板、缓存边界、钥匙串封装、Infuse WebDAV 生命周期和打包脚本是本仓库原创代码；挂载和网盘访问能力来自独立的 rclone 引擎构建。QuarkFS 不属于 Quark、Infuse、rclone 或 macFUSE 官方项目。

- [rclone/rclone](https://github.com/rclone/rclone)：命令行文件同步工具及其通用 VFS/FUSE/WebDAV 能力。
- [Quark Drive backend PR #9662](https://github.com/rclone/rclone/pull/9662)：夸克后端的公开讨论和实现来源；该 PR 在本项目锁定时仍为 Draft。
- [zly2006/rclone@47a62e1](https://github.com/zly2006/rclone/tree/47a62e1b6081b5b65664e5e8f2fa7477eba9bd6f)：本项目实际构建的固定提交。构建脚本同时校验归档 SHA-256，避免无意跟随变化的分支。
- [Cgofuse](https://github.com/winfsp/cgofuse)：rclone 在 macOS 上使用的 FUSE 绑定，遵循其 MIT 许可证。
- [macFUSE](https://github.com/macfuse/macfuse)：用户自行安装的系统扩展，本项目不重新分发，也不绕过 macOS 的系统扩展安全策略。

完整组件说明和许可证链接见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；本仓库原创代码采用 [MIT License](LICENSE)；风险与责任边界见 [04 免责声明.md](04%20免责声明.md)。

## 已知限制

- Quark Drive 后端依赖夸克网页端接口和完整浏览器 Cookie；接口、风控或账号策略变化可能导致重新登录或暂时不可用。
- 上游 Quark 后端仍处于 Draft PR 讨论阶段，因此版本被固定；更新前应重新阅读上游许可证和变更。
- macFUSE 的系统扩展审批由 macOS 控制。QuarkFS 无法替用户批准扩展，也不能替代 Apple 的 Developer ID 签名和公证。
- 快捷键是 App 内菜单快捷键，不注册全局事件监听；只有 QuarkFS 处于前台/激活状态时生效，因此不会抢占其他 App 的全局快捷键。

## 许可证

原创代码采用 MIT。发布包中的 rclone 引擎是独立的 GPLv3 组件，必须同时遵守其许可证；不要把 QuarkFS 的 MIT 许可误解为对 rclone 代码的再许可。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
