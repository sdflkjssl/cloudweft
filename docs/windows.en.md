# Windows CFAPI frontend

[中文](windows.md)

CloudWeft for Windows uses the Windows Cloud Files API (CFAPI) and retains the existing stable `fileid` bridge contract. Cloud accounts are configured in AList. For safe upgrades, legacy `Plinth` install paths, sync root paths, and startup registry names remain unchanged.

## 1. Install the runtime

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\install.ps1
```

The installer automatically:

- builds the CFAPI frontend;
- downloads AList v3.64.0 for the current CPU architecture into `%LOCALAPPDATA%\Plinth\alist`;
- initializes private AList state and an admin password;
- forces AList to bind to `127.0.0.1:5244`;
- starts the bridge on `127.0.0.1:8081`;
- creates AList/bridge runners;
- repairs logon-startup registration for all existing provider runners.

Administrator privileges, a preinstalled AList, Visual Studio, and the .NET SDK are not required. Re-running the installer preserves AList data and credentials.

### Logon startup

CloudWeft retains compatible startup entries under:

```text
HKCU\Software\Microsoft\Windows\CurrentVersion\Run
```

Entries include:

- `Plinth AList`
- `Plinth Bridge`
- every provider previously attached, such as `Plinth quark` and `Plinth baidu`

After the user signs in to Windows, the runtime and attached providers are restored automatically. Re-running `install.ps1` repairs missing provider startup entries from `%LOCALAPPDATA%\Plinth\run-*.cmd`.

## 2. Sign in to AList

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\open-alist.ps1 -Provider baidu
```

Management URL:

```text
http://127.0.0.1:5244/@manage/storages
```

Credentials:

- username: `admin`
- password: randomly generated on first install
- password file: `%USERPROFILE%\.cloud-drive-fp-data\alist-admin-pass.txt`

`open-alist.ps1` copies the password to the clipboard. To inspect it manually:

```powershell
Get-Content $HOME\.cloud-drive-fp-data\alist-admin-pass.txt
```

## 3. Configure storage in AList

| Provider | AList driver | Mount path | Remark |
|---|---|---|---|
| Quark | `Quark` | `/quark` | empty |
| Baidu Netdisk | `BaiduNetdisk` | `/baidu` | empty |

Cookies, OAuth, refresh tokens, and provider client settings are managed only by AList.

## 4. Attach to Explorer

Baidu:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\attach-provider.ps1 baidu
```

Quark:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\attach-provider.ps1 quark
```

The script:

1. verifies that the required AList mount path exists and is healthy;
2. creates `%LOCALAPPDATA%\Plinth\run-<provider>.cmd`;
3. registers the provider for logon startup;
4. starts the CFAPI engine;
5. opens the sync root.

Default sync root:

```text
%USERPROFILE%\Plinth\<provider>
```

Directories are populated on demand and files are hydrated when opened. Local create, modify, rename, and delete operations are written back through the bridge.

## 5. Regression verification

No real cloud account is required:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\verify.ps1
```

Coverage includes:

- namespace population
- on-demand hydration
- file creation
- directory creation
- nested creation
- modify/upload
- rename
- delete
- restart identity recovery
- move-out

The production path has also been validated through:

```text
CFAPI → alist-bridge.js → AList WebDAV → AList storage
```

## 6. Unregister a sync root

```powershell
.\windows\bin\Plinth.Windows.exe --provider quark --root "$HOME\Plinth\quark" --unregister
```

If the provider is no longer used, also remove its `HKCU\...\Run` entry and `%LOCALAPPDATA%\Plinth\run-<provider>.cmd`.
