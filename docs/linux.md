# CloudWeft Linux

Linux 版本复用 AList 的云盘驱动、授权和 WebDAV 接口，Rclone FUSE 负责文件挂载、按需下载、随机访问、写回与本地 VFS 缓存。系统服务使用 systemd 用户实例管理，每个 AList 存储 ID 对应一个独立挂载。

## 安装与使用

在 Ubuntu 26.04 上运行 `bash linux/install.sh`。安装器使用用户目录下的 AList v3.66.0 与系统已有的 Rclone/FUSE3，注册开机登录自启服务，在 Nautilus 侧栏添加 CloudWeft 书签，并创建应用程序入口。

AList 管理页位于 `http://127.0.0.1:5244`。管理员账号为 `admin`，本机密码保存在 `~/.local/share/cloudweft/alist-admin-pass.txt`，文件权限为 0600。添加百度、夸克等存储后，CloudWeft 自动发现可用实例，挂载在 `~/CloudWeft/<显示名>`；同名存储通过 `(s<ID>)` 后缀区分。存储配置以 AList 为准，已有用户目录不会被覆盖。

检查当前状态：`python3 linux/cloudweft.py status`。查看运行日志：`journalctl --user -u cloudweft-linux -n 50`。用户登录后两个服务自动启动。Rclone 每个存储的日志位于 `~/.local/share/cloudweft/logs`。

## 文件行为

通过 Nautilus 或其他 Linux 程序直接浏览 `~/CloudWeft`。Rclone VFS 在打开文件时从云端读取，在本地文件关闭后将更改写回 AList WebDAV。上传任务在本地缓存中暂存，默认写回延迟为 5 秒。VFS 缓存默认上限为 30 GiB，缓存保留时间为 720 小时，可通过环境变量 `CLOUDWEFT_VFS_CACHE_SIZE`、`CLOUDWEFT_VFS_CACHE_AGE` 调整。目录条目缓存默认 15 秒，可通过 `CLOUDWEFT_DIR_CACHE_TIME` 调整。夸克网页或另一台设备删除文件夹后，Ubuntu 重新枚举目录时会读取更新后的服务端列表；文件管理器已有窗口可能需要重新进入目录以触发枚举。

Nautilus 通过官方 `python3-nautilus` 扩展显示文件状态角标，并提供右键 **CloudWeft · Download to local cache（下载到本地缓存）**。状态直接取自 Rclone 的 `vfsMeta` 文件，不执行额外的网络请求：云朵代表仅云端或部分缓存，云朵加勾代表整份内容已缓存，上传箭头代表本地修改尚未写回。缓存会根据空间和保留期限被淘汰，因此显示为“已缓存”的文件仍属于可释放的本地副本。

Nautilus 状态图标采用 Wusel 开源项目的 Apache-2.0 SVG 资源，扩展接口使用 Ubuntu 提供的 `python3-nautilus`。图标会随目录刷新更新，右键后台下载完成后也会主动请求刷新。安装器自动安装 Nautilus 扩展依赖；在没有 Nautilus 的桌面环境中，仅使用 FUSE 挂载。

**逐文件永久离线固定与释放空间尚未实现。** 当前标准 Rclone VFS 缺乏对应的安全固定、缓存驱逐和单文件状态控制接口，不能将完整缓存当作永久离线保证。重要离线资料应另存至普通本地目录。

## 验证

`python3 -m unittest discover -s linux/tests -p 'test_*.py'` 执行存储身份与挂载安全检查。运行 `python3 linux/tests/integration.py` 会在本机 AList 中创建一个隔离的 Local 测试存储，实测目录读取、上传、重命名、删除及新建子文件，完成后删除测试存储。所有操作使用单独临时目录，不修改已有网盘。

## 安全与异常

AList 管理接口仅监听 127.0.0.1，Rclone 的 WebDAV 凭据保存在仅用户可读的 `~/.config/cloudweft/rclone.conf`。断网期间写入文件可能留在 VFS 缓存中，确认上传完成前不要删除缓存目录。恢复网络后服务自动重新检查存储状态，重复服务启动不会覆盖已有用户数据。旧目录名称与存储实例 ID 的对应关系保存在 `~/.config/cloudweft/roots.json`。
