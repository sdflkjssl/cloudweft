# Bridge 参考后端契约

[English](macos-server.en.md)

平台前端只要求后端满足一个核心条件：

> 每个文件和目录都有稳定、不透明的 ID，并且可以通过 ID 寻址。

`plinth-server.js` 是最小参考实现，只使用 Node.js 标准库。

## 为什么需要稳定 ID

普通 WebDAV 以路径寻址。路径会随重命名和移动变化，因此不能直接作为 FileProvider/CFAPI item identity。

Plinth 在 `PROPFIND` 中加入两个自定义属性：

| 属性 | 含义 |
|---|---|
| `<D:fileid>` | 当前 item 的稳定 ID；重命名、移动、覆盖后保持不变 |
| `<D:parentid>` | 父目录 ID；根目录的直接子项为空 |

macOS 中空 `parentid` 映射到 `NSFileProviderItemIdentifier.rootContainer`。

## HTTP/DAV 契约

```text
PROPFIND /dav/                     根目录，Depth 0/1
PROPFIND /dav/.id/<id>             单项，Depth 0/1
GET      /dav/.id/<id>

PUT      /dav/.id/<parent>/<name>  在已知父目录创建
PUT      /dav/<name>               在根目录创建
PUT      /dav/.id/<id>             原地覆盖

MKCOL    /dav/.id/<parent>/<name>
MKCOL    /dav/<name>

DELETE   /dav/.id/<id>
MOVE     /dav/.id/<id>             Destination 使用任一创建形式
```

`Depth: 1` 响应先返回容器本身，再返回子项；客户端会丢弃第一项。

创建中的文件还没有 ID，所以使用 `.id/<parent>/<name>`。

生产 bridge 在此契约上增加 provider namespace：

```text
/dav/<provider>/.id/<id>
```

## 客户端使用的状态码

| 状态码 | 含义 |
|---|---|
| `404` on `PROPFIND` | item 确实不存在 |
| `401` / `403` on read | 未认证 |
| `403` on write | 策略拒绝，不自动重试 |
| `405` / `412` | 文件名冲突 |
| `507` | 配额不足 |
| 其他 | 后端不可达或临时错误，按策略重试 |

## 参考实现的 ID

`plinth-server.js` 使用：

```text
<inode>-<birthtimeMs>
```

inode 在重命名和移动后保持不变，birth time 用于降低 inode 复用造成的身份冲突。

覆盖必须**原地写入**，不能通过“写临时文件再 rename 覆盖”，否则 inode 会变化，item identity 也会变化。

参考实现只用于测试：

- 任意非空 Basic 凭据都接受；
- 每次请求都会扫描文件树重建 ID 索引；
- 没有并发锁。

## 验证

在 `macos/server` 中：

```bash
node plinth-server.js --port 8080 &
./verify.sh 8080
```

验证包含 delete-and-recreate 后 ID 必须变化这一负向用例。
