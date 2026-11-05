# 第三方组件声明

[English](third-party-notices.en.md)

## plinth（MIT）

macOS FileProvider 代码（`macos/Extension`、`macos/App`）基于 Amur Labs LLC 的 [plinth](https://github.com/ytomasch/plinth) 修改，按 MIT License 使用。许可证副本见 `macos/LICENSE`。

与 FileProvider 框架行为相关的上游实现经验保留在源码和原项目中。

## AList（AGPL-3.0）

本项目不链接、嵌入或派生自 AList。AList 作为独立本地服务运行，CloudWeft 各平台前端通过 HTTP/WebDAV API 与其通信。

AList 仍受其自身 AGPL-3.0 许可证约束。CloudWeft 安装脚本下载官方 AList 二进制并作为运行时依赖启动；使用和分发时应遵守 AList 自身许可证。

## Rclone（MIT）

Linux 前端使用独立的 [Rclone](https://github.com/rclone/rclone) FUSE/VFS 进程管理缓存、按需读取及写回。Rclone 由用户系统提供，CloudWeft 不包含修改后的 Rclone 发行包。

## Wusel 图标（Apache-2.0）

Linux Nautilus 状态角标复用 [Wusel](https://github.com/itbh-at/wusel) 的 SVG 资源，版权归 IT Beratung Hermann GmbH 及原作者所有。原始 SVG 与完整 Apache-2.0 许可证见 `linux/nautilus/emblems/` 和 `linux/nautilus/APACHE-2.0.txt`。CloudWeft 的状态查询与菜单代码为独立实现。

## Node.js（MIT）

bridge（`macos/server/alist-bridge.js`）运行于 Node.js。

## Windows Cloud Files API

Windows 前端使用 Microsoft Windows Cloud Files API（CFAPI）。开发与行为验证参考了 Microsoft 官方文档以及公开 CFAPI 示例，包括：

- [Microsoft Cloud Files API](https://learn.microsoft.com/windows/win32/cfapi/cloud-files-api-portal)
- [PrimalZed/CloudSync](https://github.com/PrimalZed/CloudSync)
- [pure01fx/cfapi](https://github.com/pure01fx/cfapi)

项目实现不直接复制这些第三方示例的受版权源代码。
