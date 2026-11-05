# Bridge reference backend contract

[中文](macos-server.md)

A platform frontend requires one core property from its backend:

> Every file and directory has a stable opaque ID and can be addressed by that ID.

`plinth-server.js` is the smallest reference implementation and uses only the Node.js standard library.

## Why stable IDs are required

Plain WebDAV is path-addressed. Paths change on rename and reparent, so they cannot directly serve as FileProvider/CFAPI item identity.

Plinth adds two custom properties to `PROPFIND` responses:

| Property | Meaning |
|---|---|
| `<D:fileid>` | Stable item ID; survives rename, reparent, and overwrite |
| `<D:parentid>` | Parent folder ID; empty for direct children of the root |

On macOS, an empty `parentid` maps to `NSFileProviderItemIdentifier.rootContainer`.

## HTTP/DAV contract

```text
PROPFIND /dav/                     root, Depth 0/1
PROPFIND /dav/.id/<id>             item, Depth 0/1
GET      /dav/.id/<id>

PUT      /dav/.id/<parent>/<name>  create inside an identified parent
PUT      /dav/<name>               create at root
PUT      /dav/.id/<id>             overwrite in place

MKCOL    /dav/.id/<parent>/<name>
MKCOL    /dav/<name>

DELETE   /dav/.id/<id>
MOVE     /dav/.id/<id>             Destination uses either create form
```

A `Depth: 1` response returns the container first, followed by its children; the client drops the first entry.

A new file has no ID yet, so creation uses `.id/<parent>/<name>`.

The production bridge adds a provider namespace:

```text
/dav/<provider>/.id/<id>
```

## Status codes used by the client

| Status | Meaning |
|---|---|
| `404` on `PROPFIND` | the item is genuinely gone |
| `401` / `403` on read | authentication failure |
| `403` on write | policy refusal; do not blindly retry |
| `405` / `412` | filename collision |
| `507` | out of quota |
| anything else | backend unavailable or temporary failure |

## Reference implementation identity

`plinth-server.js` uses:

```text
<inode>-<birthtimeMs>
```

The inode survives rename and reparent, while birth time reduces identity collisions caused by inode reuse.

Overwrite must happen **in place**. Replacing a file by renaming a temporary file over it would allocate a new inode and therefore change item identity.

The reference server is test-only:

- any non-empty Basic credential is accepted;
- the ID index is rebuilt by walking the tree on every request;
- there is no locking.

## Verification

From `macos/server`:

```bash
node plinth-server.js --port 8080 &
./verify.sh 8080
```

The verification includes a negative case requiring the ID to change after delete-and-recreate.
