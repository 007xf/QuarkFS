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
- 自动启动本机只读 WebDAV，默认 `http://127.0.0.1:8686`；支持独立启动/停止、自定义端口、复制连接信息及打开 Infuse。
- 连接会先完成真实 WebDAV 目录检查，再显示“已就绪”；端口占用和登录失败会显示错误。
- 挂载目录支持选择器和显式应用，拒绝包含文件或覆盖应用数据的位置；输入过程不创建文件夹。
- 扫码登录或粘贴 Cookie；登录信息只存储在 macOS 钥匙串，不写入仓库或普通明文配置。
- “零残留 / 平衡 / 高性能”三档缓存策略，以及专用缓存清理。
- 默认快捷键：`⌥⌘O` 显示窗口、`⌥⌘E` 挂载/卸载、`⌥⌘F` 打开 Finder、`⌥⌘R` 重新检查、`⌥⌘K` 清理缓存。
- Bob 风格的快捷键录制页：点击组合框后直接按键，修饰键高亮；Esc 取消、Delete 清除、重复组合拒绝保存。
- 应用和内置引擎均可生成 Apple Silicon（arm64）版本。

## 最快开始

### 直接使用发布包

1. 使用 Apple Silicon（M 系列芯片）Mac，系统为 macOS 14 或更高版本。
2. 如果需要 Finder 本地磁盘挂载，安装 [macFUSE](https://macfuse.github.io/)，按系统提示允许扩展并重启；只使用 Infuse 本机连接可以跳过。
3. 从 [GitHub Releases](https://github.com/007xf/QuarkFS/releases/latest) 下载 `QuarkFS-macOS-arm64.zip`，解压后把 `QuarkFS.app` 拖入“应用程序”。
4. 第一次打开若被 Gatekeeper 拦截，在 Finder 中右键 App，选择“打开”。当前包为本地 ad-hoc 签名，尚未使用 Apple Developer ID 公证。
5. 打开 QuarkFS，扫码登录夸克。Infuse 连接会自动启动；使用 Finder 时，待运行条件通过后点击“挂载 Quark”。
6. 在 Infuse 中添加 WebDAV：服务器 `127.0.0.1`，端口 `8686`，路径 `/`，用户名和密码留空。也可以只使用 Finder 中的 `~/Quark`。

### 从源码构建

源码构建需要：

- macOS 14 或更高版本；
- Xcode Command Line Tools（提供 Swift 6 工具链）；
- Go 1.22 或更高版本（只在构建内置引擎时需要）；
- macFUSE（要使用 Finder/macFUSE 挂载时需要；没有它仍可构建和运行 WebDAV 读取路径）。

在 Finder 中按顺序双击：

1. `Scripts/01 构建引擎.command`：下载已锁定并校验的 rclone 源码，构建Apple Silicon 引擎；
2. `Scripts/02 打包应用.command`：运行核心冒烟测试，编译 Apple Silicon 版本，签名并生成 `.build/QuarkFS.app`；
3. `Scripts/03 生成发布包.command`：生成Apple Silicon ZIP 和 SHA-256 校验文件。

也可以在终端运行同名脚本。当前版本仅支持 Apple Silicon（M 系列芯片），不再构建 Intel 包。

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

在连接区域可以点击“复制连接信息”和“打开 Infuse”。端口被占用时，输入 1024–65535 之间的新端口并点击“应用端口”，随后同步修改 Infuse 的连接设置。点击“停止”仅关闭 Infuse 连接，不影响 Finder 挂载。重新打开窗口会保留本次运行中的停止状态；重新启动 App 后会自动连接。

如果 Infuse 看不到目录，先回到 QuarkFS 确认“Infuse 本机连接”显示“已就绪”，再点“重新启动”；不要把 `~/Quark` 当作 Infuse 的网络地址。

如果看到“文件系统引擎已退出（代码 1）”，先点“重新检查”。应用会识别旧版或手动启动留下的同一挂载点并接管状态，避免再次重复挂载；需要卸载时先停止播放器，再点“卸载 Quark”。

## 缓存与安全边界

QuarkFS 只读挂载和只读 WebDAV 都会把写入操作拒绝给上游网盘。两条读取路径使用相互独立的缓存子目录，分别应用“平衡约 5 GB / 高性能约 20 GB”的软上限，内存预读按每个打开文件计算。正在读取的文件可能超过软上限；修改缓存策略时，本机 WebDAV 会自动安全重启并应用新参数：

```text
~/Library/Application Support/com.holmes.QuarkFS
├── Cache
│   ├── Mount
│   └── Infuse
└── Runtime
    └── rclone.conf
```

运行期配置保存在仅当前用户可访问的目录中，正常退出后删除；开启自动清理或零残留模式时，退出也会清理磁盘缓存。缓存清理器会拒绝根目录或中间目录上的符号链接，避免越界删除。挂载磁盘仍在使用、无法卸载时，App 会取消退出并保留连接。扫码期间使用独立的内存 Cookie 存储，完成网盘会话校验后才保存到 macOS 钥匙串；日志可能包含网络错误和文件路径，请在提交 Issue 前自行检查并脱敏。

钥匙串第一次询问时，请输入 Mac 登录密码并选择“始终允许”。应用会在同一次运行中复用已转换的凭据，挂载、卸载、重新挂载不会重复读取钥匙串。ad-hoc 签名的开发包在升级后可能被 macOS 视为新应用并再次询问一次。

## 项目结构

```text
Package.swift                 Swift Package 入口
Sources/QuarkFS               SwiftUI 窗口、菜单栏、快捷键与生命周期
Sources/QuarkFSCore           挂载计划、钥匙串、缓存、引擎定位
Sources/QuarkFSSmokeTests     不依赖账号的核心冒烟测试
Resources/                    App 图标、Info.plist
Scripts/01 构建引擎.command   下载校验并构建 rclone（arm64）
Scripts/02 打包应用.command   测试、编译、签名 App
Scripts/03 生成发布包.command 生成 ZIP 与 SHA-256
.github/workflows/ci.yml      GitHub 上的Apple Silicon编译检查
```

## 开源致谢

本项目的 SwiftUI 控制面板、缓存边界、钥匙串封装、Infuse WebDAV 生命周期和打包脚本是本仓库原创代码；挂载和网盘访问能力来自独立的 rclone 引擎构建。QuarkFS 不属于 Quark、Infuse、rclone 或 macFUSE 官方项目。

- [rclone/rclone](https://github.com/rclone/rclone)：命令行文件同步工具及其通用 VFS/FUSE/WebDAV 能力。
- [Quark Drive backend PR #9662](https://github.com/rclone/rclone/pull/9662)：夸克后端的公开讨论和实现来源；该 PR 在本项目锁定时仍为 Draft。
- [zly2006/rclone@47a62e1](https://github.com/zly2006/rclone/tree/47a62e1b6081b5b65664e5e8f2fa7477eba9bd6f)：本项目实际构建的固定提交。构建脚本同时校验归档 SHA-256，避免无意跟随变化的分支。
- [Cgofuse](https://github.com/winfsp/cgofuse)：rclone 在 macOS 上使用的 FUSE 绑定，遵循其 MIT 许可证。
- [macFUSE](https://github.com/macfuse/macfuse)：用户自行安装的系统扩展，本项目不重新分发，也不绕过 macOS 的系统扩展安全策略。

完整组件说明和许可证链接见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)；本仓库原创代码采用 [MIT License](LICENSE)；风险与责任边界见 [04 免责声明.md](04%20免责声明.md)。

## 开发验证

- `swift run --disable-sandbox --build-system native QuarkFSSmokeTests`：进程大输出/超时、缓存符号链接、挂载路径、旧设置迁移、WebDAV 响应与登录失败回归。
- `Scripts/04 检查应用行为.command`：使用本机测试服务验证启动、停止、端口切换、清理缓存、退出登录和 App 退出；不使用真实账号。
- 构建引擎后可运行 `python3 Tests/QuarkFSCoreTests/EngineIntegration.py .build/engine/rclone --mount`，使用临时文件检查真实 WebDAV 分段读取、只读保护及 macFUSE 挂载。
- GitHub CI 同时执行无账号回归检查并编译 Apple Silicon 版本。

更新内容见 [05 更新记录.md](05%20更新记录.md)。

## 已知限制

- Quark Drive 后端依赖夸克网页端接口和完整浏览器 Cookie；接口、风控或账号策略变化可能导致重新登录或暂时不可用。
- 上游 Quark 后端仍处于 Draft PR 讨论阶段，因此版本被固定；更新前应重新阅读上游许可证和变更。
- macFUSE 的系统扩展审批由 macOS 控制。QuarkFS 无法替用户批准扩展，也不能替代 Apple 的 Developer ID 签名和公证。
- 快捷键是 App 内菜单快捷键，不注册全局事件监听；只有 QuarkFS 处于前台/激活状态时生效，因此不会抢占其他 App 的全局快捷键。

## 许可证

原创代码采用 MIT。发布包中的 rclone 引擎是独立的 GPLv3 组件，必须同时遵守其许可证；不要把 QuarkFS 的 MIT 许可误解为对 rclone 代码的再许可。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
