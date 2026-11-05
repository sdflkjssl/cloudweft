# Provider 适配规范

[English](providers.en.md)

`cloud-drive-fp` 是多 provider 的原生占位符文件系统前端。云盘登录、OAuth、Cookie、Refresh Token 和存储驱动配置全部属于 AList；本仓库只负责平台前端、稳定 ID bridge，以及 AList mount path 到系统 provider 的映射。

## 架构

同一个 `alist-bridge.js` 进程服务所有 provider：

```text
macOS Finder / Windows Explorer
  ├─ 夸克
  │    └─ http://127.0.0.1:8081/dav/quark
  └─ 百度网盘
       └─ http://127.0.0.1:8081/dav/baidu
                         │
                         ▼
                      AList
                    /quark
                    /baidu
```

每个 provider 都有独立的持久化 ID 映射。夸克为兼容旧版本继续使用 `fp-idmap.json`；其他 provider 使用 `fp-idmap-<provider>.json`。

## 单一静态配置源

静态 provider 元数据位于：

```text
macos/Shared/providers.json
```

一个条目定义：

- provider id 与显示名称；
- macOS FileProvider domain identifier；
- AList driver；
- 固定 mount path；
- provider schema version；
- 可选下载策略。

catalog 不得包含 Cookie、Refresh Token、OAuth URL、client secret 或用户登录状态。

## 认证边界

只有 AList 可以向用户索取云端凭据。

Plinth 可以：

- 打开本机 AList 存储管理页；
- 查询指定 mount path 是否存在、是否健康；
- 使用 AList WebDAV；
- 注册或启动平台原生文件前端。

Plinth 不得：

- 向用户索取夸克 Cookie、百度 Refresh Token 等网盘凭据；
- 代替 AList 创建带云端凭据的 storage；
- 在 AList 之外持久化云端凭据；
- 将 AList 管理员密码交给 FileProvider/CFAPI 前端。

bridge 的 provider control API 为只读状态接口。

## AList storage 约定

| Provider | Driver | Mount path | Remark |
|---|---|---|---|
| 夸克 | `Quark` | `/quark` | 留空 |
| 百度网盘 | `BaiduNetdisk` | `/baidu` | 留空 |

Remark 不属于身份或路由契约，Plinth 不读取它。

## 百度网盘

在 AList 中使用 `BaiduNetdisk`，挂载到 `/baidu`。OAuth、Refresh Token 和所有驱动参数均由 AList 管理。

当 `/baidu` 健康后，Plinth 将其暴露为 `baidu` provider。完整文件下载可以在 AList 解析出当前直链后使用 catalog 中声明的并行 Range 策略；失败时回退到 AList WebDAV/native proxy。

相关 catalog 字段：

- `downloadStrategy`
- `downloadConcurrency`
- `downloadChunkSize`
- `downloadUserAgent`

未声明下载策略的 provider 使用普通 AList WebDAV 流。

## 新增 provider

1. 在 `macos/Shared/providers.json` 增加唯一的 `id`、domain identifier、AList `driver` 和固定 `mountPath`。
2. 文档中说明用户应在 AList 中使用哪个 driver 和 mount path。
3. bridge 路径固定为 `/dav/<provider-id>`。
4. 每个 provider 使用独立 ID 映射。
5. 只有确有必要时增加 provider-specific 下载策略，不增加凭据处理。
6. 仅当原生 item identifier 或能力模型发生不兼容变化时递增 `schemaVersion`。

AList 登录或驱动配置变化不需要重置 FileProvider/CFAPI 数据库。
