# 第三方组件与开源致谢

QuarkFS 的 SwiftUI 控制面板、缓存安全边界、钥匙串封装、Infuse WebDAV 生命周期和打包脚本是本仓库原创代码，采用 MIT License。下面的组件由其他项目提供，QuarkFS 不主张拥有其版权，也不代表这些项目的官方立场。

## 1. rclone 与 Quark Drive 后端

- 项目：[rclone/rclone](https://github.com/rclone/rclone)
- Quark 后端讨论：[PR #9662 — quark: add Quark Drive backend](https://github.com/rclone/rclone/pull/9662)
- 实际构建来源：[zly2006/rclone@47a62e1b6081b5b65664e5e8f2fa7477eba9bd6f](https://github.com/zly2006/rclone/tree/47a62e1b6081b5b65664e5e8f2fa7477eba9bd6f)
- 源码归档地址：`https://codeload.github.com/zly2006/rclone/tar.gz/47a62e1b6081b5b65664e5e8f2fa7477eba9bd6f`
- 归档 SHA-256：`fce696c6ee13a26f38fa1b1a2ece9479eec771e765f868cd213151cd24e9d596`
- 许可证：[MIT License](https://github.com/zly2006/rclone/blob/47a62e1b6081b5b65664e5e8f2fa7477eba9bd6f/COPYING)（全文见下）

QuarkFS 的构建脚本不会从漂移的分支拉取代码，而是下载上面的固定提交并校验 SHA-256。发布包中的 `Contents/Resources/Engine/rclone` 是独立的可执行组件，版权归 rclone 的作者所有，采用 rclone 自己的 MIT 许可证；它没有和 QuarkFS 的 Swift 代码链接成一个库，QuarkFS 的许可证不改变 rclone 的版权归属。

要取得对应源码，可以直接打开固定提交页面或运行构建脚本重新下载。若重新分发包含 rclone 的二进制包，请保留下面的 rclone 版权声明和许可声明。引擎还包含它依赖的 Go 模块，各自的许可证以锁定提交的 `go.mod` 所列模块为准。本项目没有对 rclone 源码做本地修改。

rclone 的许可证原文（锁定提交的 `COPYING`）：

```text
Copyright (C) 2012 by Nick Craig-Wood http://www.craig-wood.com/nick/

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

Quark 后端目前来自一个仍在公开讨论中的 Draft PR，使用夸克网页端接口和完整会话 Cookie。它不是夸克官方 SDK，也不代表夸克或 rclone 官方保证长期兼容。

## 2. Cgofuse

- 项目：[winfsp/cgofuse](https://github.com/winfsp/cgofuse)
- 版本来源：由锁定的 rclone 提交通过 Go module 引入；具体版本以该提交的 `go.mod` 为准。
- 许可证：[MIT License](https://github.com/winfsp/cgofuse/blob/master/License.txt)

Cgofuse 为 rclone 的 macOS `cmount` 提供 FUSE 绑定。QuarkFS 不直接修改或单独再发布 Cgofuse 源码。

## 3. macFUSE

- 项目：[macFUSE](https://github.com/macfuse/macfuse)
- 用户安装入口：[macFUSE 官网](https://macfuse.github.io/)
- 许可证和系统扩展条款以 macFUSE 发布包随附文件为准。

macFUSE 是用户在系统层面独立安装的组件，QuarkFS 不将其打包进 App、不复制其系统扩展，也不尝试绕过 macOS 的“隐私与安全性”审批。QuarkFS 只在检测到 macFUSE 后启用只读 `cmount`。

## 4. Apple / Swift 运行时

QuarkFS 使用 Apple 的 Swift、SwiftUI、AppKit、Security 和 CoreImage 系统框架。它们由 macOS 提供，不随本仓库重新分发；使用和再分发受 Apple SDK 与系统许可约束。

## 5. 归属和问题反馈

“QuarkFS”是本项目用于描述本地桥接工具的名称。本项目与 Quark（夸克）、Infuse、rclone、macFUSE 及其维护者没有隶属、赞助或官方合作关系。发现第三方归属或许可证信息需要修正时，请提交 Issue，并附上具体文件、版本和上游链接；请不要在 Issue 或日志中上传 Cookie、二维码或私人媒体路径。
