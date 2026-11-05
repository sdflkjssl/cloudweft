# Windows CFAPI 前端

[English](windows.en.md)

CloudWeft Windows 前端使用 Windows Cloud Files API（CFAPI），复用已有 bridge 与稳定 `fileid` 身份契约。AList 负责云盘账号与授权。升级时保留旧安装的 `Plinth` 程序目录、同步根和自启动注册名，避免破坏已有文件状态。

## 1. 安装运行环境

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
```

安装器会自动：

- 构建 CFAPI frontend；
- 按 CPU 架构下载 AList v3.64.0 到 `%LOCALAPPDATA%\Plinth\alist`；
- 初始化独立 AList 数据目录和管理员密码；
- 强制 AList 只监听 `127.0.0.1:5244`；
- 启动 bridge `127.0.0.1:8081`；
- 创建 AList/bridge runner；
- 修复所有已有 provider runner 的登录自启动注册。

无需管理员权限，也不要求预装 AList、Visual Studio 或 .NET SDK。重复运行不会重置 AList 数据或管理员密码。

### 登录自启动

CloudWeft 使用原有兼容注册位置：

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
```

注册：

- `Plinth AList`
- `Plinth Bridge`
- 每个已经挂载过的 provider，例如 `Plinth quark`、`Plinth baidu`

因此用户登录 Windows 后会自动恢复运行环境和已挂载 provider。再次运行 `install.ps1` 会根据 `%LOCALAPPDATA%\Plinth\run-*.cmd` 修复缺失的 provider 自启动项。

## 2. 登录 AList

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\open-alist.ps1 -Provider baidu
```

管理地址：

```text
http://127.0.0.1:5244/@manage/storages
```

登录信息：

- 用户名：`admin`
- 密码：首次安装随机生成
- 密码文件：`%USERPROFILE%\.cloud-drive-fp-data\alist-admin-pass.txt`

`open-alist.ps1` 会自动把密码复制到剪贴板。手工查看：

```powershell
Get-Content $HOME\.cloud-drive-fp-data\alist-admin-pass.txt
```

## 3. 在 AList 中配置网盘

| Provider | AList driver | Mount path | Remark |
|---|---|---|---|
| 夸克 | `Quark` | `/quark` | 留空 |
| 百度网盘 | `BaiduNetdisk` | `/baidu` | 留空 |

Cookie、OAuth、Refresh Token、客户端参数等全部由 AList 驱动页面管理。CloudWeft 前端不保存这些字段。

## 4. 挂载到资源管理器

百度：

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\attach-provider.ps1 baidu
```

夸克：

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\attach-provider.ps1 quark
```

脚本会：

1. 检查 AList 对应 mount path 是否存在且 healthy；
2. 生成 `%LOCALAPPDATA%\Plinth\run-<provider>.cmd`；
3. 注册该 provider 登录自启动；
4. 启动 CFAPI engine；
5. 打开同步根。

默认同步根：

```text
%USERPROFILE%\Plinth\<provider>
```

同步根按需枚举目录并创建占位符；打开文件时才水合。本地新建、修改、重命名和删除通过 bridge 写回 AList。

## 5. 回归验证

不需要真实网盘账号：

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\verify.ps1
```

覆盖：

- 目录枚举
- 按需水合
- 新建文件
- 新建目录
- 嵌套新建
- 修改上传
- 重命名
- 删除
- engine 重启身份恢复
- 移出同步根

Windows 安装链还验证过：

```text
CFAPI → alist-bridge.js → AList WebDAV → AList storage
```

## 6. 卸载同步根

```powershell
.\windows\bin\Plinth.Windows.exe --provider quark --root "$HOME\Plinth\quark" --unregister
```

若不再使用该 provider，同时删除对应 `HKCU\...\Run` 项和 `%LOCALAPPDATA%\Plinth\run-<provider>.cmd`。
