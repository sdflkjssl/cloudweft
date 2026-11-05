# Provider adapters

[中文](providers.md)

`cloud-drive-fp` is a multi-provider native placeholder filesystem frontend. Cloud login, OAuth, cookies, refresh tokens, and storage-driver configuration belong entirely to AList. This repository owns the platform frontends, the stable-ID bridge contract, and the mapping from AList mount paths to native provider domains.

## Architecture

One `alist-bridge.js` process serves all providers:

```text
macOS Finder / Windows Explorer
  ├─ Quark
  │    └─ http://127.0.0.1:8081/dav/quark
  └─ Baidu Netdisk
       └─ http://127.0.0.1:8081/dav/baidu
                         │
                         ▼
                      AList
                    /quark
                    /baidu
```

Each provider has an independent persistent ID map. Quark keeps the legacy `fp-idmap.json` for upgrade compatibility; other providers use `fp-idmap-<provider>.json`.

## Single static source of truth

Static provider metadata lives in:

```text
macos/Shared/providers.json
```

A catalog entry defines:

- provider id and display name;
- macOS FileProvider domain identifier;
- AList driver;
- required mount path;
- provider schema version;
- optional download strategy.

The catalog must not contain cookies, refresh tokens, OAuth URLs, client secrets, or user login state.

## Authentication boundary

AList is the only component allowed to ask users for cloud credentials.

Plinth may:

- open the local AList storage-management page;
- query whether a required mount path exists and is healthy;
- consume AList WebDAV;
- register or start the native platform frontend.

Plinth must not:

- ask for Quark cookies, Baidu refresh tokens, or other cloud credentials;
- create credential-bearing AList storage entries on behalf of the user;
- persist cloud credentials outside AList;
- expose AList admin credentials to FileProvider or CFAPI.

The bridge provider-control API is read-only.

## AList storage conventions

| Provider | Driver | Mount path | Remark |
|---|---|---|---|
| Quark | `Quark` | `/quark` | empty |
| Baidu Netdisk | `BaiduNetdisk` | `/baidu` | empty |

The Remark field is not part of routing or identity and is ignored by Plinth.

## Baidu Netdisk

Configure AList `BaiduNetdisk` at `/baidu`. AList owns OAuth, refresh-token lifecycle, and all driver settings.

Once `/baidu` is healthy, Plinth exposes it as the `baidu` provider. Full-file downloads may use catalog-declared parallel Range requests after AList resolves the current direct URL, with AList WebDAV/native proxy as fallback.

Relevant catalog fields:

- `downloadStrategy`
- `downloadConcurrency`
- `downloadChunkSize`
- `downloadUserAgent`

Providers without an explicit download strategy use ordinary AList WebDAV streaming.

## Adding a provider

1. Add a unique `id`, domain identifier, AList `driver`, and fixed `mountPath` to `macos/Shared/providers.json`.
2. Document the driver and mount path the user must configure in AList.
3. Keep the bridge namespace at `/dav/<provider-id>`.
4. Keep a separate ID map per provider.
5. Add provider-specific download behavior only when necessary; do not add credential handling.
6. Increment `schemaVersion` only when native item identifiers or capabilities change incompatibly.

AList authentication or driver-setting changes do not require a FileProvider/CFAPI database reset.
