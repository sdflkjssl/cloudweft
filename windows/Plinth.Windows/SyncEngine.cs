using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Plinth.Windows
{
    internal sealed class SyncEngine : IDisposable
    {
        private const int TransferChunkSize = 4 * 1024 * 1024;
        private static readonly Guid ProviderGuid = new Guid("9b678a46-4f8f-4ac1-99dd-67e6f29d7187");

        private readonly string _root;
        private readonly string _providerId;
        private readonly DavClient _dav;
        private readonly object _mapLock = new object();
        private readonly Dictionary<string, string> _relativeToId =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, string> _idToRelative =
            new Dictionary<string, string>(StringComparer.Ordinal);
        private readonly object _pendingLock = new object();
        private readonly Dictionary<string, DateTime> _pendingLocalChanges =
            new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);

        private FileSystemWatcher _watcher;
        private NativeCfApi.CallbackDelegate _fetchDataDelegate;
        private NativeCfApi.CallbackDelegate _fetchPlaceholdersDelegate;
        private NativeCfApi.CallbackDelegate _deleteDelegate;
        private NativeCfApi.CallbackDelegate _renameDelegate;
        private IntPtr _callbackTable = IntPtr.Zero;
        private long _connectionKey;
        private bool _connected;

        internal SyncEngine(string root, string providerId, DavClient dav)
        {
            _root = Path.GetFullPath(root);
            _providerId = providerId;
            _dav = dav;
            _relativeToId[string.Empty] = string.Empty;
        }

        internal string Root { get { return _root; } }

        internal void Start()
        {
            Directory.CreateDirectory(_root);
            RegisterSyncRoot();
            Connect();
            StartWatcher();
            Log("connected: " + _root);
        }

        internal static void Unregister(string root)
        {
            string full = Path.GetFullPath(root);
            int hr = NativeCfApi.CfUnregisterSyncRoot(full);
            NativeCfApi.ThrowIfFailed(hr, "CfUnregisterSyncRoot");
        }

        private void RegisterSyncRoot()
        {
            IntPtr providerName = Marshal.StringToHGlobalUni("CloudWeft");
            IntPtr providerVersion = Marshal.StringToHGlobalUni("0.1");
            byte[] syncIdentityBytes = Encoding.UTF8.GetBytes(_providerId);
            IntPtr syncIdentity = Marshal.AllocHGlobal(syncIdentityBytes.Length);
            Marshal.Copy(syncIdentityBytes, 0, syncIdentity, syncIdentityBytes.Length);

            try
            {
                NativeCfApi.SyncRegistration registration = new NativeCfApi.SyncRegistration();
                registration.StructSize = (uint)NativeCfApi.SizeOf<NativeCfApi.SyncRegistration>();
                registration.ProviderName = providerName;
                registration.ProviderVersion = providerVersion;
                registration.SyncRootIdentity = syncIdentity;
                registration.SyncRootIdentityLength = (uint)syncIdentityBytes.Length;
                registration.FileIdentity = IntPtr.Zero;
                registration.FileIdentityLength = 0;
                registration.ProviderId = ProviderGuid;

                NativeCfApi.SyncPolicies policies = new NativeCfApi.SyncPolicies();
                policies.StructSize = (uint)NativeCfApi.SizeOf<NativeCfApi.SyncPolicies>();
                policies.Hydration = new NativeCfApi.HydrationPolicy { Primary = 2, Modifier = 0 };
                policies.Population = new NativeCfApi.PopulationPolicy { Primary = 2, Modifier = 0 };
                policies.InSync = 0;
                policies.HardLink = 0;
                policies.PlaceholderManagement = 0;

                int hr = NativeCfApi.CfRegisterSyncRoot(
                    _root,
                    ref registration,
                    ref policies,
                    NativeCfApi.CF_REGISTER_FLAG_UPDATE |
                    NativeCfApi.CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT);
                NativeCfApi.ThrowIfFailed(hr, "CfRegisterSyncRoot");
            }
            finally
            {
                Marshal.FreeHGlobal(providerName);
                Marshal.FreeHGlobal(providerVersion);
                Marshal.FreeHGlobal(syncIdentity);
            }
        }

        private void Connect()
        {
            _fetchDataDelegate = OnFetchData;
            _fetchPlaceholdersDelegate = OnFetchPlaceholders;
            _deleteDelegate = OnDelete;
            _renameDelegate = OnRename;

            NativeCfApi.CallbackRegistration[] callbacks = new NativeCfApi.CallbackRegistration[]
            {
                Registration(NativeCfApi.CallbackType.FetchData, _fetchDataDelegate),
                Registration(NativeCfApi.CallbackType.FetchPlaceholders, _fetchPlaceholdersDelegate),
                Registration(NativeCfApi.CallbackType.NotifyDelete, _deleteDelegate),
                Registration(NativeCfApi.CallbackType.NotifyRename, _renameDelegate),
                new NativeCfApi.CallbackRegistration { Type = NativeCfApi.CallbackType.None, Callback = IntPtr.Zero }
            };

            int stride = NativeCfApi.SizeOf<NativeCfApi.CallbackRegistration>();
            _callbackTable = Marshal.AllocHGlobal(stride * callbacks.Length);
            for (int i = 0; i < callbacks.Length; i++)
                Marshal.StructureToPtr(callbacks[i], IntPtr.Add(_callbackTable, i * stride), false);

            int hr = NativeCfApi.CfConnectSyncRoot(
                _root,
                _callbackTable,
                IntPtr.Zero,
                NativeCfApi.CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
                out _connectionKey);
            NativeCfApi.ThrowIfFailed(hr, "CfConnectSyncRoot");
            _connected = true;
        }

        private static NativeCfApi.CallbackRegistration Registration(
            NativeCfApi.CallbackType type,
            NativeCfApi.CallbackDelegate callback)
        {
            return new NativeCfApi.CallbackRegistration
            {
                Type = type,
                Callback = Marshal.GetFunctionPointerForDelegate(callback)
            };
        }

        private void OnFetchPlaceholders(IntPtr infoPtr, IntPtr parametersPtr)
        {
            NativeCfApi.CallbackInfo info = ReadInfo(infoPtr);
            try
            {
                string parentId = Identity(info);
                string parentRelative = ObserveCallbackIdentity(info, parentId);
                List<DavEntry> children = _dav.List(parentId);
                List<DavEntry> valid = new List<DavEntry>();
                foreach (DavEntry child in children)
                {
                    if (!IsWindowsNameSafe(child.Name))
                    {
                        Log("skip unsupported Windows name: " + child.Name);
                        continue;
                    }
                    valid.Add(child);
                }

                TransferPlaceholders(info, parentRelative, valid);
                Log("listed " + DisplayRelative(parentRelative) + ": " + valid.Count + " item(s)");
            }
            catch (Exception ex)
            {
                Log("FETCH_PLACEHOLDERS failed: " + ex.Message);
                TransferPlaceholderFailure(info);
            }
        }

        private void TransferPlaceholders(
            NativeCfApi.CallbackInfo info,
            string parentRelative,
            List<DavEntry> entries)
        {
            int count = entries.Count;
            int stride = NativeCfApi.SizeOf<NativeCfApi.PlaceholderCreateInfo>();
            IntPtr array = count == 0 ? IntPtr.Zero : Marshal.AllocHGlobal(stride * count);
            List<IntPtr> allocations = new List<IntPtr>();

            try
            {
                for (int i = 0; i < count; i++)
                {
                    DavEntry entry = entries[i];
                    byte[] identityBytes = Encoding.UTF8.GetBytes(entry.Id);
                    IntPtr identity = Marshal.AllocHGlobal(identityBytes.Length);
                    Marshal.Copy(identityBytes, 0, identity, identityBytes.Length);
                    IntPtr name = Marshal.StringToHGlobalUni(entry.Name);
                    allocations.Add(identity);
                    allocations.Add(name);

                    long fileTime = entry.ModifiedUtc.ToFileTimeUtc();
                    NativeCfApi.PlaceholderCreateInfo placeholder =
                        new NativeCfApi.PlaceholderCreateInfo();
                    placeholder.RelativeFileName = name;
                    placeholder.FsMetadata = new NativeCfApi.FsMetadata
                    {
                        BasicInfo = new NativeCfApi.FileBasicInfo
                        {
                            CreationTime = fileTime,
                            LastAccessTime = fileTime,
                            LastWriteTime = fileTime,
                            ChangeTime = fileTime,
                            FileAttributes = entry.IsDirectory
                                ? NativeCfApi.FILE_ATTRIBUTE_DIRECTORY
                                : NativeCfApi.FILE_ATTRIBUTE_ARCHIVE
                        },
                        FileSize = entry.IsDirectory ? 0 : entry.Size
                    };
                    placeholder.FileIdentity = identity;
                    placeholder.FileIdentityLength = (uint)identityBytes.Length;
                    placeholder.Flags = NativeCfApi.CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;
                    Marshal.StructureToPtr(placeholder, IntPtr.Add(array, i * stride), false);

                    string relative = CombineRelative(parentRelative, entry.Name);
                    Cache(entry.Id, relative);
                }

                NativeCfApi.OperationInfo operation = Operation(info, NativeCfApi.OperationType.TransferPlaceholders);
                NativeCfApi.OperationParameters parameters = new NativeCfApi.OperationParameters();
                parameters.ParamSize = 40;
                // This callback returns the complete directory listing in one batch.
                // Mark it fully populated so Windows does not ask for the same
                // namespace repeatedly on every enumeration.
                parameters.Flags = 0x00000002;
                parameters.CompletionStatus = NativeCfApi.STATUS_SUCCESS;
                parameters.PlaceholderTotalCount = count;
                parameters.PlaceholderArray = array;
                parameters.PlaceholderCount = (uint)count;
                parameters.EntriesProcessed = 0;

                int hr = NativeCfApi.CfExecute(ref operation, ref parameters);
                NativeCfApi.ThrowIfFailed(hr, "CfExecute(TRANSFER_PLACEHOLDERS)");
            }
            finally
            {
                foreach (IntPtr allocation in allocations)
                    if (allocation != IntPtr.Zero) Marshal.FreeHGlobal(allocation);
                if (array != IntPtr.Zero) Marshal.FreeHGlobal(array);
            }
        }

        private void TransferPlaceholderFailure(NativeCfApi.CallbackInfo info)
        {
            NativeCfApi.OperationInfo operation = Operation(info, NativeCfApi.OperationType.TransferPlaceholders);
            NativeCfApi.OperationParameters parameters = new NativeCfApi.OperationParameters();
            parameters.ParamSize = 40;
            parameters.Flags = 0;
            parameters.CompletionStatus = NativeCfApi.STATUS_UNSUCCESSFUL;
            parameters.PlaceholderTotalCount = 0;
            parameters.PlaceholderArray = IntPtr.Zero;
            parameters.PlaceholderCount = 0;
            TryExecute(ref operation, ref parameters);
        }

        private void OnFetchData(IntPtr infoPtr, IntPtr parametersPtr)
        {
            NativeCfApi.CallbackInfo info = ReadInfo(infoPtr);
            NativeCfApi.CallbackParameters callbackParameters = ReadParameters(parametersPtr);
            long offset = callbackParameters.RequiredFileOffset;
            long length = callbackParameters.RequiredLength;
            if (length < 0 || offset + length > info.FileSize)
                length = Math.Max(0, info.FileSize - offset);

            try
            {
                string id = Identity(info);
                if (string.IsNullOrEmpty(id))
                    throw new InvalidOperationException("FETCH_DATA without file identity.");
                string relative = ObserveCallbackIdentity(info, id);

                using (DavReadStream remote = _dav.OpenRead(id, offset, length))
                {
                    TransferData(info, remote.Stream, offset, length);
                }
                Log("hydrated " + DisplayRelative(relative) +
                    " [" + offset + "," + length + "]");
            }
            catch (Exception ex)
            {
                Log("FETCH_DATA failed: " + ex.Message);
                TransferDataFailure(info, offset);
            }
        }

        private void TransferData(
            NativeCfApi.CallbackInfo info,
            Stream input,
            long offset,
            long length)
        {
            if (length == 0)
            {
                ExecuteTransferData(info, IntPtr.Zero, offset, 0, NativeCfApi.STATUS_SUCCESS);
                return;
            }

            byte[] managed = new byte[TransferChunkSize];
            long remaining = length;
            long currentOffset = offset;

            while (remaining > 0)
            {
                int wanted = (int)Math.Min(managed.Length, remaining);
                int read = ReadAtMost(input, managed, wanted);
                if (read <= 0)
                    throw new EndOfStreamException("Remote content ended before hydration completed.");

                IntPtr buffer = Marshal.AllocHGlobal(read);
                try
                {
                    Marshal.Copy(managed, 0, buffer, read);
                    ExecuteTransferData(
                        info,
                        buffer,
                        currentOffset,
                        read,
                        NativeCfApi.STATUS_SUCCESS);
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }

                currentOffset += read;
                remaining -= read;
            }
        }

        private void ExecuteTransferData(
            NativeCfApi.CallbackInfo info,
            IntPtr buffer,
            long offset,
            long length,
            int status)
        {
            NativeCfApi.OperationInfo operation = Operation(info, NativeCfApi.OperationType.TransferData);
            NativeCfApi.OperationParameters parameters = new NativeCfApi.OperationParameters();
            parameters.ParamSize = 40;
            parameters.Flags = 0;
            parameters.CompletionStatus = status;
            parameters.Buffer = buffer;
            parameters.Offset = offset;
            parameters.Length = length;
            int hr = NativeCfApi.CfExecute(ref operation, ref parameters);
            NativeCfApi.ThrowIfFailed(hr, "CfExecute(TRANSFER_DATA)");
        }

        private void TransferDataFailure(NativeCfApi.CallbackInfo info, long offset)
        {
            try
            {
                ExecuteTransferData(info, IntPtr.Zero, offset, 0, NativeCfApi.STATUS_UNSUCCESSFUL);
            }
            catch (Exception ex)
            {
                Log("failed to report hydration error: " + ex.Message);
            }
        }

        private void OnDelete(IntPtr infoPtr, IntPtr parametersPtr)
        {
            NativeCfApi.CallbackInfo info = ReadInfo(infoPtr);
            int status = NativeCfApi.STATUS_SUCCESS;
            string id = Identity(info);
            try
            {
                ObserveCallbackIdentity(info, id);
                if (!string.IsNullOrEmpty(id)) _dav.Delete(id);
                RemoveCached(id);
                Log("deleted " + id);
            }
            catch (Exception ex)
            {
                status = NativeCfApi.STATUS_UNSUCCESSFUL;
                Log("DELETE failed: " + ex.Message);
            }
            Ack(info, NativeCfApi.OperationType.AckDelete, status);
        }

        private void OnRename(IntPtr infoPtr, IntPtr parametersPtr)
        {
            NativeCfApi.CallbackInfo info = ReadInfo(infoPtr);
            NativeCfApi.CallbackParameters callbackParameters = ReadParameters(parametersPtr);
            int status = NativeCfApi.STATUS_SUCCESS;
            string id = Identity(info);

            try
            {
                string target = Marshal.PtrToStringUni(callbackParameters.PathOrPattern) ?? string.Empty;
                string source = Marshal.PtrToStringUni(info.NormalizedPath) ?? string.Empty;
                string oldRelative = ObserveCallbackIdentity(info, id);
                bool targetInScope = (callbackParameters.Flags & 0x00000004) != 0;

                if (!targetInScope)
                {
                    _dav.Delete(id);
                    RemoveCached(id);
                    Log("moved out of sync root " + oldRelative);
                }
                else
                {
                    string targetRelative = TargetRelative(source, oldRelative, target);
                    string parentRelative = NormalizeRelative(Path.GetDirectoryName(targetRelative) ?? string.Empty);
                    string name = Path.GetFileName(targetRelative);
                    string parentId = EnsureIdForRelative(parentRelative);
                    _dav.Move(id, parentId, name);
                    MoveCachedPrefix(oldRelative, targetRelative);
                    Log("moved " + oldRelative + " -> " + targetRelative);
                }
            }
            catch (Exception ex)
            {
                status = NativeCfApi.STATUS_UNSUCCESSFUL;
                Log("RENAME failed: " + ex.Message);
            }

            Ack(info, NativeCfApi.OperationType.AckRename, status);
        }

        private void Ack(NativeCfApi.CallbackInfo info, NativeCfApi.OperationType type, int status)
        {
            NativeCfApi.OperationInfo operation = Operation(info, type);
            NativeCfApi.OperationParameters parameters = new NativeCfApi.OperationParameters();
            parameters.ParamSize = 16;
            parameters.Flags = 0;
            parameters.CompletionStatus = status;
            TryExecute(ref operation, ref parameters);
        }

        private static NativeCfApi.OperationInfo Operation(
            NativeCfApi.CallbackInfo callback,
            NativeCfApi.OperationType type)
        {
            NativeCfApi.OperationInfo operation = new NativeCfApi.OperationInfo();
            operation.StructSize = (uint)NativeCfApi.SizeOf<NativeCfApi.OperationInfo>();
            operation.Type = type;
            operation.ConnectionKey = callback.ConnectionKey;
            operation.TransferKey = callback.TransferKey;
            operation.CorrelationVector = callback.CorrelationVector;
            operation.SyncStatus = IntPtr.Zero;
            operation.RequestKey = callback.RequestKey;
            return operation;
        }

        private static NativeCfApi.CallbackInfo ReadInfo(IntPtr pointer)
        {
            return (NativeCfApi.CallbackInfo)Marshal.PtrToStructure(
                pointer, typeof(NativeCfApi.CallbackInfo));
        }

        private static NativeCfApi.CallbackParameters ReadParameters(IntPtr pointer)
        {
            return (NativeCfApi.CallbackParameters)Marshal.PtrToStructure(
                pointer, typeof(NativeCfApi.CallbackParameters));
        }

        private static string Identity(NativeCfApi.CallbackInfo info)
        {
            if (info.FileIdentity == IntPtr.Zero || info.FileIdentityLength == 0)
                return string.Empty;
            byte[] bytes = new byte[info.FileIdentityLength];
            Marshal.Copy(info.FileIdentity, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }

        private static int ReadAtMost(Stream stream, byte[] buffer, int count)
        {
            int total = 0;
            while (total < count)
            {
                int read = stream.Read(buffer, total, count - total);
                if (read <= 0) break;
                total += read;
            }
            return total;
        }

        private void Cache(string id, string relative)
        {
            relative = NormalizeRelative(relative);
            lock (_mapLock)
            {
                _idToRelative[id] = relative;
                _relativeToId[relative] = id;
            }
        }

        private string RelativeForId(string id)
        {
            if (string.IsNullOrEmpty(id)) return string.Empty;
            lock (_mapLock)
            {
                string relative;
                if (_idToRelative.TryGetValue(id, out relative)) return relative;
            }
            throw new InvalidOperationException("Unknown local identity: " + id);
        }

        private string ObserveCallbackIdentity(NativeCfApi.CallbackInfo info, string id)
        {
            if (string.IsNullOrEmpty(id)) return string.Empty;

            lock (_mapLock)
            {
                string cached;
                if (_idToRelative.TryGetValue(id, out cached)) return cached;
            }

            string normalized = Marshal.PtrToStringUni(info.NormalizedPath) ?? string.Empty;
            string relative = RelativeFromNormalizedCallbackPath(normalized);
            Cache(id, relative);
            return relative;
        }

        private string RelativeFromNormalizedCallbackPath(string normalized)
        {
            if (string.IsNullOrEmpty(normalized))
                throw new InvalidOperationException("CFAPI callback has no normalized path.");

            string path = normalized.Replace('/', '\\');
            string root = _root.TrimEnd('\\');

            if (path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase))
                return NormalizeRelative(path.Substring(root.Length + 1));
            if (string.Equals(path, root, StringComparison.OrdinalIgnoreCase))
                return string.Empty;

            // CFAPI commonly reports NormalizedPath relative to the volume root
            // (for example \Users\name\Plinth\file). Reattach this sync root's
            // drive before comparing it with the configured root.
            string driveRoot = Path.GetPathRoot(root) ?? string.Empty;
            if (driveRoot.Length > 0)
            {
                string candidate = driveRoot.TrimEnd('\\') + "\\" + path.TrimStart('\\');
                if (candidate.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase))
                    return NormalizeRelative(candidate.Substring(root.Length + 1));
                if (string.Equals(candidate, root, StringComparison.OrdinalIgnoreCase))
                    return string.Empty;
            }

            throw new InvalidOperationException("Callback path is outside the sync root: " + normalized);
        }

        private string IdForRelative(string relative)
        {
            relative = NormalizeRelative(relative);
            if (relative.Length == 0) return string.Empty;
            lock (_mapLock)
            {
                string id;
                if (_relativeToId.TryGetValue(relative, out id)) return id;
            }
            throw new InvalidOperationException("Target parent has not been populated: " + relative);
        }

        private void RemoveCached(string id)
        {
            if (string.IsNullOrEmpty(id)) return;
            lock (_mapLock)
            {
                string relative;
                if (!_idToRelative.TryGetValue(id, out relative)) return;
                List<string> removeIds = new List<string>();
                foreach (KeyValuePair<string, string> item in _idToRelative)
                    if (IsSameOrChild(item.Value, relative)) removeIds.Add(item.Key);
                foreach (string removeId in removeIds)
                {
                    string removeRelative = _idToRelative[removeId];
                    _idToRelative.Remove(removeId);
                    _relativeToId.Remove(removeRelative);
                }
            }
        }

        private void MoveCachedPrefix(string oldRelative, string newRelative)
        {
            oldRelative = NormalizeRelative(oldRelative);
            newRelative = NormalizeRelative(newRelative);
            lock (_mapLock)
            {
                List<KeyValuePair<string, string>> updates =
                    new List<KeyValuePair<string, string>>();
                foreach (KeyValuePair<string, string> item in _idToRelative)
                {
                    if (!IsSameOrChild(item.Value, oldRelative)) continue;
                    string suffix = item.Value.Length == oldRelative.Length
                        ? string.Empty
                        : item.Value.Substring(oldRelative.Length).TrimStart('\\');
                    string moved = suffix.Length == 0 ? newRelative : Path.Combine(newRelative, suffix);
                    updates.Add(new KeyValuePair<string, string>(item.Key, NormalizeRelative(moved)));
                }
                foreach (KeyValuePair<string, string> update in updates)
                {
                    _relativeToId.Remove(_idToRelative[update.Key]);
                    _idToRelative[update.Key] = update.Value;
                    _relativeToId[update.Value] = update.Key;
                }
            }
        }

        private void StartWatcher()
        {
            _watcher = new FileSystemWatcher(_root);
            _watcher.IncludeSubdirectories = true;
            _watcher.NotifyFilter =
                NotifyFilters.FileName |
                NotifyFilters.DirectoryName |
                NotifyFilters.LastWrite |
                NotifyFilters.Size;
            _watcher.Created += OnLocalChange;
            _watcher.Changed += OnLocalChange;
            _watcher.EnableRaisingEvents = true;
        }

        private void OnLocalChange(object sender, FileSystemEventArgs eventArgs)
        {
            QueueLocalChange(eventArgs.FullPath);
        }

        private void QueueLocalChange(string fullPath)
        {
            string normalized;
            try { normalized = Path.GetFullPath(fullPath); }
            catch { return; }

            bool startWorker = false;
            lock (_pendingLock)
            {
                startWorker = !_pendingLocalChanges.ContainsKey(normalized);
                _pendingLocalChanges[normalized] = DateTime.UtcNow;
            }
            if (!startWorker) return;

            ThreadPool.QueueUserWorkItem(delegate
            {
                while (true)
                {
                    Thread.Sleep(500);
                    DateTime lastChange;
                    lock (_pendingLock)
                    {
                        if (!_pendingLocalChanges.TryGetValue(normalized, out lastChange))
                            return;
                        if ((DateTime.UtcNow - lastChange).TotalMilliseconds < 450)
                            continue;
                        _pendingLocalChanges.Remove(normalized);
                    }
                    break;
                }

                ProcessLocalChangeWithRetry(normalized);
            });
        }

        private void ProcessLocalChangeWithRetry(string fullPath)
        {
            Exception last = null;
            for (int attempt = 0; attempt < 5; attempt++)
            {
                try
                {
                    ProcessLocalChange(fullPath);
                    return;
                }
                catch (IOException ex)
                {
                    last = ex;
                }
                catch (UnauthorizedAccessException ex)
                {
                    last = ex;
                }
                catch (InvalidOperationException ex)
                {
                    // A nested item can arrive before its newly-created parent
                    // has finished converting to a placeholder. Retrying lets the
                    // parent establish its bridge id first.
                    last = ex;
                }

                Thread.Sleep(300 * (attempt + 1));
            }

            if (last != null)
                Log("local sync failed for " + fullPath + ": " + last.Message);
        }

        private void ProcessLocalChange(string fullPath)
        {
            bool isDirectory = Directory.Exists(fullPath);
            bool isFile = File.Exists(fullPath);
            if (!isDirectory && !isFile) return;

            string relative = RelativeFromFullPath(fullPath);
            if (relative.Length == 0) return;

            string id;
            bool inSync;
            if (TryGetPlaceholderInfo(fullPath, isDirectory, out id, out inSync))
            {
                if (!string.IsNullOrEmpty(id)) Cache(id, relative);

                // Placeholder creation, namespace population and hydration all
                // generate filesystem notifications. They arrive marked in-sync,
                // so they must not be uploaded back to the bridge.
                if (isDirectory || inSync) return;
                if (string.IsNullOrEmpty(id))
                    throw new InvalidOperationException("Placeholder has no bridge identity.");

                DavEntry updated = _dav.PutFile(
                    id,
                    EnsureIdForRelative(ParentRelative(relative)),
                    Path.GetFileName(relative),
                    fullPath);
                Cache(updated.Id, relative);
                MarkInSync(fullPath, isDirectory);
                Log("uploaded changes " + relative);
                return;
            }

            string parentId = EnsureIdForRelative(ParentRelative(relative));
            DavEntry created;
            if (isDirectory)
                created = _dav.CreateDirectory(parentId, Path.GetFileName(relative));
            else
                created = _dav.PutFile(string.Empty, parentId, Path.GetFileName(relative), fullPath);

            ConvertToPlaceholder(fullPath, isDirectory, created.Id);
            Cache(created.Id, relative);
            Log("uploaded new " + relative);
        }

        private string EnsureIdForRelative(string relative)
        {
            relative = NormalizeRelative(relative);
            if (relative.Length == 0) return string.Empty;

            lock (_mapLock)
            {
                string cached;
                if (_relativeToId.TryGetValue(relative, out cached)) return cached;
            }

            string fullPath = Path.Combine(_root, relative);
            bool isDirectory = Directory.Exists(fullPath);
            string id;
            bool inSync;
            if (TryGetPlaceholderInfo(fullPath, isDirectory, out id, out inSync) &&
                !string.IsNullOrEmpty(id))
            {
                Cache(id, relative);
                return id;
            }

            throw new InvalidOperationException("Parent has no bridge identity: " + relative);
        }

        private bool TryGetPlaceholderInfo(
            string fullPath,
            bool isDirectory,
            out string id,
            out bool inSync)
        {
            id = string.Empty;
            inSync = false;

            IntPtr handle = NativeCfApi.CreateFile(
                fullPath,
                NativeCfApi.FILE_READ_ATTRIBUTES,
                NativeCfApi.FILE_SHARE_READ |
                    NativeCfApi.FILE_SHARE_WRITE |
                    NativeCfApi.FILE_SHARE_DELETE,
                IntPtr.Zero,
                NativeCfApi.OPEN_EXISTING,
                isDirectory ? NativeCfApi.FILE_FLAG_BACKUP_SEMANTICS : 0,
                IntPtr.Zero);
            if (handle == new IntPtr(-1)) return false;

            IntPtr buffer = Marshal.AllocHGlobal(8192);
            try
            {
                uint returned;
                int hr = NativeCfApi.CfGetPlaceholderInfo(
                    handle, 0, buffer, 8192, out returned);
                if (hr < 0) return false;

                inSync = Marshal.ReadInt32(buffer, 4) == (int)NativeCfApi.CF_IN_SYNC_STATE_IN_SYNC;
                int identityLength = Marshal.ReadInt32(buffer, 24);
                if (identityLength < 0 || identityLength > 4096 || 28 + identityLength > returned)
                    throw new InvalidOperationException("Invalid CFAPI file identity length.");

                if (identityLength > 0)
                {
                    byte[] bytes = new byte[identityLength];
                    Marshal.Copy(IntPtr.Add(buffer, 28), bytes, 0, identityLength);
                    id = Encoding.UTF8.GetString(bytes);
                }
                return true;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
                NativeCfApi.CloseHandle(handle);
            }
        }

        private void ConvertToPlaceholder(string fullPath, bool isDirectory, string id)
        {
            byte[] identity = Encoding.UTF8.GetBytes(id);
            IntPtr identityBuffer = Marshal.AllocHGlobal(identity.Length);
            Marshal.Copy(identity, 0, identityBuffer, identity.Length);

            IntPtr handle = NativeCfApi.CreateFile(
                fullPath,
                NativeCfApi.FILE_WRITE_DATA | NativeCfApi.FILE_READ_ATTRIBUTES,
                NativeCfApi.FILE_SHARE_READ |
                    NativeCfApi.FILE_SHARE_WRITE |
                    NativeCfApi.FILE_SHARE_DELETE,
                IntPtr.Zero,
                NativeCfApi.OPEN_EXISTING,
                isDirectory ? NativeCfApi.FILE_FLAG_BACKUP_SEMANTICS : 0,
                IntPtr.Zero);

            try
            {
                if (handle == new IntPtr(-1))
                    throw new IOException("Unable to open local item for CFAPI conversion.");

                long usn;
                int hr = NativeCfApi.CfConvertToPlaceholder(
                    handle,
                    identityBuffer,
                    (uint)identity.Length,
                    NativeCfApi.CF_CONVERT_FLAG_MARK_IN_SYNC,
                    out usn,
                    IntPtr.Zero);
                NativeCfApi.ThrowIfFailed(hr, "CfConvertToPlaceholder");
            }
            finally
            {
                if (handle != new IntPtr(-1)) NativeCfApi.CloseHandle(handle);
                Marshal.FreeHGlobal(identityBuffer);
            }
        }

        private void MarkInSync(string fullPath, bool isDirectory)
        {
            IntPtr handle = NativeCfApi.CreateFile(
                fullPath,
                NativeCfApi.FILE_WRITE_DATA | NativeCfApi.FILE_READ_ATTRIBUTES,
                NativeCfApi.FILE_SHARE_READ |
                    NativeCfApi.FILE_SHARE_WRITE |
                    NativeCfApi.FILE_SHARE_DELETE,
                IntPtr.Zero,
                NativeCfApi.OPEN_EXISTING,
                isDirectory ? NativeCfApi.FILE_FLAG_BACKUP_SEMANTICS : 0,
                IntPtr.Zero);

            try
            {
                if (handle == new IntPtr(-1))
                    throw new IOException("Unable to open placeholder to mark it in sync.");

                int hr = NativeCfApi.CfSetInSyncState(
                    handle,
                    NativeCfApi.CF_IN_SYNC_STATE_IN_SYNC,
                    0,
                    IntPtr.Zero);
                NativeCfApi.ThrowIfFailed(hr, "CfSetInSyncState");
            }
            finally
            {
                if (handle != new IntPtr(-1)) NativeCfApi.CloseHandle(handle);
            }
        }

        private string RelativeFromFullPath(string fullPath)
        {
            string full = Path.GetFullPath(fullPath);
            string prefix = _root.TrimEnd('\\') + "\\";
            if (!full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Path is outside the sync root.");
            return NormalizeRelative(full.Substring(prefix.Length));
        }

        private static string ParentRelative(string relative)
        {
            return NormalizeRelative(Path.GetDirectoryName(relative) ?? string.Empty);
        }

        private static bool IsSameOrChild(string candidate, string parent)
        {
            if (string.Equals(candidate, parent, StringComparison.OrdinalIgnoreCase)) return true;
            return candidate.StartsWith(parent + "\\", StringComparison.OrdinalIgnoreCase);
        }

        private static string TargetRelative(string sourceNormalized, string sourceRelative, string target)
        {
            string source = sourceNormalized.Replace('/', '\\');
            string targetPath = target.Replace('/', '\\');
            string relative = sourceRelative.Replace('/', '\\');

            if (relative.Length > 0 &&
                source.EndsWith(relative, StringComparison.OrdinalIgnoreCase))
            {
                string prefix = source.Substring(0, source.Length - relative.Length);
                if (targetPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    return NormalizeRelative(targetPath.Substring(prefix.Length));
            }

            string fileName = Path.GetFileName(targetPath);
            string oldParent = Path.GetDirectoryName(relative) ?? string.Empty;
            return NormalizeRelative(Path.Combine(oldParent, fileName));
        }

        private static string CombineRelative(string parent, string name)
        {
            return NormalizeRelative(string.IsNullOrEmpty(parent) ? name : Path.Combine(parent, name));
        }

        private static string NormalizeRelative(string relative)
        {
            if (string.IsNullOrEmpty(relative)) return string.Empty;
            return relative.Replace('/', '\\').Trim('\\');
        }

        private static bool IsWindowsNameSafe(string name)
        {
            if (string.IsNullOrEmpty(name) || name == "." || name == "..") return false;
            if (name.EndsWith(" ", StringComparison.Ordinal) ||
                name.EndsWith(".", StringComparison.Ordinal)) return false;
            return name.IndexOfAny(Path.GetInvalidFileNameChars()) < 0;
        }

        private static string DisplayRelative(string relative)
        {
            return string.IsNullOrEmpty(relative) ? "<root>" : relative;
        }

        private static void TryExecute(
            ref NativeCfApi.OperationInfo operation,
            ref NativeCfApi.OperationParameters parameters)
        {
            int hr = NativeCfApi.CfExecute(ref operation, ref parameters);
            if (hr < 0) Log("CfExecute acknowledgement failed: 0x" + hr.ToString("X8"));
        }

        private static void Log(string message)
        {
            Console.WriteLine("[CloudWeft] " + message);
        }

        public void Dispose()
        {
            if (_watcher != null)
            {
                _watcher.EnableRaisingEvents = false;
                _watcher.Dispose();
                _watcher = null;
            }
            if (_connected)
            {
                try { NativeCfApi.CfDisconnectSyncRoot(_connectionKey); } catch { }
                _connected = false;
            }
            if (_callbackTable != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(_callbackTable);
                _callbackTable = IntPtr.Zero;
            }

            GC.KeepAlive(_fetchDataDelegate);
            GC.KeepAlive(_fetchPlaceholdersDelegate);
            GC.KeepAlive(_deleteDelegate);
            GC.KeepAlive(_renameDelegate);
        }
    }
}
