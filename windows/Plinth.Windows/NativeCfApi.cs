using System;
using System.Runtime.InteropServices;

namespace Plinth.Windows
{
    internal static class NativeCfApi
    {
        internal const int STATUS_SUCCESS = 0;
        internal const int STATUS_UNSUCCESSFUL = unchecked((int)0xC0000001);

        internal const uint CF_REGISTER_FLAG_UPDATE = 0x00000001;
        internal const uint CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT = 0x00000004;

        internal const uint CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH = 0x00000004;

        internal const uint CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC = 0x00000002;
        internal const uint CF_CREATE_FLAG_NONE = 0;

        internal const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        internal const uint FILE_ATTRIBUTE_ARCHIVE = 0x00000020;
        internal const uint GENERIC_READ = 0x80000000;
        internal const uint GENERIC_WRITE = 0x40000000;
        internal const uint FILE_WRITE_DATA = 0x00000002;
        internal const uint FILE_READ_ATTRIBUTES = 0x00000080;
        internal const uint FILE_SHARE_READ = 0x00000001;
        internal const uint FILE_SHARE_WRITE = 0x00000002;
        internal const uint FILE_SHARE_DELETE = 0x00000004;
        internal const uint OPEN_EXISTING = 3;
        internal const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        internal const uint CF_CONVERT_FLAG_MARK_IN_SYNC = 0x00000001;
        internal const uint CF_IN_SYNC_STATE_IN_SYNC = 1;

        internal enum CallbackType : int
        {
            FetchData = 0,
            ValidateData = 1,
            CancelFetchData = 2,
            FetchPlaceholders = 3,
            CancelFetchPlaceholders = 4,
            NotifyFileOpenCompletion = 5,
            NotifyFileCloseCompletion = 6,
            NotifyDehydrate = 7,
            NotifyDehydrateCompletion = 8,
            NotifyDelete = 9,
            NotifyDeleteCompletion = 10,
            NotifyRename = 11,
            NotifyRenameCompletion = 12,
            None = -1
        }

        internal enum OperationType : int
        {
            TransferData = 0,
            RetrieveData = 1,
            AckData = 2,
            RestartHydration = 3,
            TransferPlaceholders = 4,
            AckDehydrate = 5,
            AckDelete = 6,
            AckRename = 7
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct HydrationPolicy
        {
            internal uint Primary;
            internal uint Modifier;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct PopulationPolicy
        {
            internal uint Primary;
            internal uint Modifier;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct SyncPolicies
        {
            internal uint StructSize;
            internal HydrationPolicy Hydration;
            internal PopulationPolicy Population;
            internal uint InSync;
            internal uint HardLink;
            internal uint PlaceholderManagement;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct SyncRegistration
        {
            internal uint StructSize;
            internal IntPtr ProviderName;
            internal IntPtr ProviderVersion;
            internal IntPtr SyncRootIdentity;
            internal uint SyncRootIdentityLength;
            internal IntPtr FileIdentity;
            internal uint FileIdentityLength;
            internal Guid ProviderId;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct FileBasicInfo
        {
            internal long CreationTime;
            internal long LastAccessTime;
            internal long LastWriteTime;
            internal long ChangeTime;
            internal uint FileAttributes;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct FsMetadata
        {
            internal FileBasicInfo BasicInfo;
            internal long FileSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct PlaceholderCreateInfo
        {
            internal IntPtr RelativeFileName;
            internal FsMetadata FsMetadata;
            internal IntPtr FileIdentity;
            internal uint FileIdentityLength;
            internal uint Flags;
            internal int Result;
            internal long CreateUsn;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        internal delegate void CallbackDelegate(IntPtr callbackInfo, IntPtr callbackParameters);

        [StructLayout(LayoutKind.Sequential)]
        internal struct CallbackRegistration
        {
            internal CallbackType Type;
            internal IntPtr Callback;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct CallbackInfo
        {
            internal uint StructSize;
            internal long ConnectionKey;
            internal IntPtr CallbackContext;
            internal IntPtr VolumeGuidName;
            internal IntPtr VolumeDosName;
            internal uint VolumeSerialNumber;
            internal long SyncRootFileId;
            internal IntPtr SyncRootIdentity;
            internal uint SyncRootIdentityLength;
            internal long FileId;
            internal long FileSize;
            internal IntPtr FileIdentity;
            internal uint FileIdentityLength;
            internal IntPtr NormalizedPath;
            internal long TransferKey;
            internal byte PriorityHint;
            internal IntPtr CorrelationVector;
            internal IntPtr ProcessInfo;
            internal long RequestKey;
        }

        [StructLayout(LayoutKind.Explicit, Size = 72)]
        internal struct CallbackParameters
        {
            [FieldOffset(0)] internal uint ParamSize;
            [FieldOffset(8)] internal uint Flags;

            // FetchData
            [FieldOffset(16)] internal long RequiredFileOffset;
            [FieldOffset(24)] internal long RequiredLength;
            [FieldOffset(32)] internal long OptionalFileOffset;
            [FieldOffset(40)] internal long OptionalLength;

            // FetchPlaceholders.Pattern / Rename.TargetPath / RenameCompletion.SourcePath
            [FieldOffset(16)] internal IntPtr PathOrPattern;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct OperationInfo
        {
            internal uint StructSize;
            internal OperationType Type;
            internal long ConnectionKey;
            internal long TransferKey;
            internal IntPtr CorrelationVector;
            internal IntPtr SyncStatus;
            internal long RequestKey;
        }

        [StructLayout(LayoutKind.Explicit, Size = 64)]
        internal struct OperationParameters
        {
            [FieldOffset(0)] internal uint ParamSize;

            // Common first two fields for TransferData/TransferPlaceholders/Ack*
            [FieldOffset(8)] internal uint Flags;
            [FieldOffset(12)] internal int CompletionStatus;

            // TransferData
            [FieldOffset(16)] internal IntPtr Buffer;
            [FieldOffset(24)] internal long Offset;
            [FieldOffset(32)] internal long Length;

            // TransferPlaceholders
            [FieldOffset(16)] internal long PlaceholderTotalCount;
            [FieldOffset(24)] internal IntPtr PlaceholderArray;
            [FieldOffset(32)] internal uint PlaceholderCount;
            [FieldOffset(36)] internal uint EntriesProcessed;
        }

        [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
        internal static extern int CfRegisterSyncRoot(
            string syncRootPath,
            ref SyncRegistration registration,
            ref SyncPolicies policies,
            uint registerFlags);

        [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
        internal static extern int CfUnregisterSyncRoot(string syncRootPath);

        [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
        internal static extern int CfConnectSyncRoot(
            string syncRootPath,
            IntPtr callbackTable,
            IntPtr callbackContext,
            uint connectFlags,
            out long connectionKey);

        [DllImport("cldapi.dll")]
        internal static extern int CfDisconnectSyncRoot(long connectionKey);

        [DllImport("cldapi.dll")]
        internal static extern int CfExecute(
            ref OperationInfo operationInfo,
            ref OperationParameters operationParameters);

        [DllImport("cldapi.dll")]
        internal static extern int CfConvertToPlaceholder(
            IntPtr fileHandle,
            IntPtr fileIdentity,
            uint fileIdentityLength,
            uint convertFlags,
            out long convertUsn,
            IntPtr overlapped);

        [DllImport("cldapi.dll")]
        internal static extern int CfSetInSyncState(
            IntPtr fileHandle,
            uint inSyncState,
            uint inSyncFlags,
            IntPtr inSyncUsn);

        [DllImport("cldapi.dll")]
        internal static extern int CfGetPlaceholderInfo(
            IntPtr fileHandle,
            int infoClass,
            IntPtr infoBuffer,
            uint infoBufferLength,
            out uint returnedLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern IntPtr CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool CloseHandle(IntPtr handle);

        internal static void ThrowIfFailed(int hresult, string operation)
        {
            if (hresult < 0)
                throw new InvalidOperationException(operation + " failed: 0x" + hresult.ToString("X8"));
        }

        internal static int SizeOf<T>()
        {
            return Marshal.SizeOf(typeof(T));
        }
    }
}
