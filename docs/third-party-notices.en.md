# Third-Party Notices

[中文](third-party-notices.md)

## plinth (MIT)

The macOS FileProvider code in `macos/Extension` and `macos/App` is a modified fork of [plinth](https://github.com/ytomasch/plinth) by Amur Labs LLC and is used under the MIT License. See `macos/LICENSE`.

Upstream implementation knowledge about FileProvider framework behavior is retained in source comments and in the original project.

## AList (AGPL-3.0)

This project does not link, embed, or derive from AList. AList runs as a separate local service and CloudWeft's platform frontends communicate with it over HTTP/WebDAV.

AList remains subject to its own AGPL-3.0 license. CloudWeft's bootstrap scripts download the official AList binary and run it as a runtime dependency; use and redistribution must follow AList's own license.

## Rclone (MIT)

The Linux frontend uses the independent [Rclone](https://github.com/rclone/rclone) FUSE/VFS runtime for caching, on-demand reads, and write-back. CloudWeft does not distribute a modified Rclone binary.

## Wusel emblem artwork (Apache-2.0)

Linux Nautilus status emblems reuse SVG assets from [Wusel](https://github.com/itbh-at/wusel), copyright IT Beratung Hermann GmbH and contributors. The assets and complete Apache-2.0 license are located under `linux/nautilus/emblems/` and `linux/nautilus/APACHE-2.0.txt`. CloudWeft's status and menu implementation is independent.

## Node.js (MIT)

The bridge at `macos/server/alist-bridge.js` runs on Node.js.

## Windows Cloud Files API

The Windows frontend uses Microsoft's Windows Cloud Files API (CFAPI). Development and behavior validation referenced Microsoft documentation and public CFAPI examples, including:

- [Microsoft Cloud Files API](https://learn.microsoft.com/windows/win32/cfapi/cloud-files-api-portal)
- [PrimalZed/CloudSync](https://github.com/PrimalZed/CloudSync)
- [pure01fx/cfapi](https://github.com/pure01fx/cfapi)

The project implementation does not directly copy copyrighted source code from those examples.
