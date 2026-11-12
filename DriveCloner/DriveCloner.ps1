<#
    Drive Cloner - simple sector-by-sector disk cloning tool for Windows.
    No installation needed: double-click "DriveCloner.bat" (or right-click this
    file > Run with PowerShell). It asks for Administrator rights, which raw
    disk access requires.
#>

# --- relaunch elevated if needed -------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-WindowStyle', 'Hidden',
            '-File', "`"$PSCommandPath`"")
    } catch { }   # user declined the UAC prompt
    exit
}

Add-Type -AssemblyName System.Windows.Forms

# --- the program (C#, compiled in memory by the .NET Framework built into Windows)
$source = @'
// DriveCloner - simple sector-by-sector disk cloner for Windows.
// Written for C# 5 so it compiles with the compiler built into Windows
// (.NET Framework 4.x / Windows PowerShell 5.1 Add-Type). No install needed.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32.SafeHandles;

namespace DriveCloner
{
    // ------------------------------------------------------------------ Win32
    internal static class Native
    {
        public const uint GENERIC_READ = 0x80000000;
        public const uint GENERIC_WRITE = 0x40000000;
        public const uint FILE_SHARE_READ = 1;
        public const uint FILE_SHARE_WRITE = 2;
        public const uint OPEN_EXISTING = 3;
        public const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
        public const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;

        public const uint IOCTL_DISK_GET_LENGTH_INFO = 0x0007405C;
        public const uint IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x000700A0;
        public const uint IOCTL_DISK_UPDATE_PROPERTIES = 0x00070140;
        public const uint FSCTL_LOCK_VOLUME = 0x00090018;
        public const uint FSCTL_DISMOUNT_VOLUME = 0x00090020;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern SafeFileHandle CreateFile(string name, uint access, uint share,
            IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool DeviceIoControl(SafeFileHandle h, uint code, IntPtr inBuf, int inSize,
            IntPtr outBuf, int outSize, out int returned, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetFilePointerEx(SafeFileHandle h, long distance, out long newPos, uint method);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ReadFile(SafeFileHandle h, IntPtr buf, int toRead, out int read, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool WriteFile(SafeFileHandle h, IntPtr buf, int toWrite, out int written, IntPtr overlapped);

        [DllImport("msvcrt.dll", CallingConvention = CallingConvention.Cdecl)]
        public static extern int memcmp(IntPtr a, IntPtr b, UIntPtr count);

        [DllImport("kernel32.dll")]
        public static extern void RtlZeroMemory(IntPtr dest, UIntPtr size);

        public static Exception LastError(string what)
        {
            return new IOException(what + ": " + new Win32Exception(Marshal.GetLastWin32Error()).Message);
        }
    }

    // ----------------------------------------------------- sector-aligned buffer
    internal sealed class AlignedBuffer : IDisposable
    {
        private IntPtr raw;
        public readonly IntPtr Ptr;
        public readonly int Size;

        public AlignedBuffer(int size)
        {
            Size = size;
            raw = Marshal.AllocHGlobal(size + 4096);
            long p = raw.ToInt64();
            Ptr = new IntPtr((p + 4095) & ~4095L);
        }

        public void Zero(int offset, int count)
        {
            Native.RtlZeroMemory(IntPtr.Add(Ptr, offset), new UIntPtr((uint)count));
        }

        public byte[] ToArray(int count)
        {
            byte[] b = new byte[count];
            Marshal.Copy(Ptr, b, 0, count);
            return b;
        }

        public void FromArray(byte[] b)
        {
            Marshal.Copy(b, 0, Ptr, b.Length);
        }

        public void Dispose()
        {
            if (raw != IntPtr.Zero) { Marshal.FreeHGlobal(raw); raw = IntPtr.Zero; }
        }
    }

    // ------------------------------------------------------------- raw disk
    internal sealed class RawDisk : IDisposable
    {
        public readonly SafeFileHandle Handle;
        public readonly string Path;

        public RawDisk(int index, bool write)
        {
            Path = @"\\.\PhysicalDrive" + index;
            uint access = Native.GENERIC_READ | (write ? Native.GENERIC_WRITE : 0);
            uint flags = Native.FILE_FLAG_NO_BUFFERING | (write ? Native.FILE_FLAG_WRITE_THROUGH : 0);
            Handle = Native.CreateFile(Path, access, Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE,
                IntPtr.Zero, Native.OPEN_EXISTING, flags, IntPtr.Zero);
            if (Handle.IsInvalid) throw Native.LastError("Cannot open " + Path);
        }

        public long Length()
        {
            IntPtr buf = Marshal.AllocHGlobal(8);
            try
            {
                int ret;
                if (!Native.DeviceIoControl(Handle, Native.IOCTL_DISK_GET_LENGTH_INFO, IntPtr.Zero, 0, buf, 8, out ret, IntPtr.Zero))
                    throw Native.LastError("Cannot read size of " + Path);
                return Marshal.ReadInt64(buf);
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        public int SectorSize()
        {
            // DISK_GEOMETRY_EX: Cylinders(8) MediaType(4) TracksPerCylinder(4) SectorsPerTrack(4) BytesPerSector(4) DiskSize(8) ...
            IntPtr buf = Marshal.AllocHGlobal(256);
            try
            {
                int ret;
                if (!Native.DeviceIoControl(Handle, Native.IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, IntPtr.Zero, 0, buf, 256, out ret, IntPtr.Zero))
                    return 512;
                int bps = Marshal.ReadInt32(buf, 20);
                return bps > 0 ? bps : 512;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        private void Seek(long pos)
        {
            long np;
            if (!Native.SetFilePointerEx(Handle, pos, out np, 0))
                throw Native.LastError("Seek failed on " + Path + " at byte " + pos);
        }

        public bool TryRead(long pos, AlignedBuffer buf, int offset, int count)
        {
            long np;
            if (!Native.SetFilePointerEx(Handle, pos, out np, 0)) return false;
            int read;
            return Native.ReadFile(Handle, IntPtr.Add(buf.Ptr, offset), count, out read, IntPtr.Zero) && read == count;
        }

        public void Read(long pos, AlignedBuffer buf, int offset, int count)
        {
            Seek(pos);
            int read;
            if (!Native.ReadFile(Handle, IntPtr.Add(buf.Ptr, offset), count, out read, IntPtr.Zero))
                throw Native.LastError("Read failed on " + Path + " at byte " + pos);
            if (read != count) throw new IOException("Short read on " + Path + " at byte " + pos);
        }

        public void Write(long pos, AlignedBuffer buf, int offset, int count)
        {
            Seek(pos);
            int written;
            if (!Native.WriteFile(Handle, IntPtr.Add(buf.Ptr, offset), count, out written, IntPtr.Zero))
                throw Native.LastError("Write failed on " + Path + " at byte " + pos);
            if (written != count) throw new IOException("Short write on " + Path + " at byte " + pos);
        }

        public void UpdateProperties()
        {
            int ret;
            Native.DeviceIoControl(Handle, Native.IOCTL_DISK_UPDATE_PROPERTIES, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
        }

        public void Dispose() { Handle.Dispose(); }
    }

    // ------------------------------------------------------------- disk list
    public class DiskInfo
    {
        public int Index;
        public string Model = "";
        public string Interface = "";
        public string Serial = "";
        public long Size;
        public bool IsSystem;
        public List<string> Letters = new List<string>();

        public string Describe()
        {
            string letters = Letters.Count > 0 ? "  [" + string.Join(" ", Letters.ToArray()) + "]" : "";
            return "Disk " + Index + ": " + Model + "  (" + Util.FormatSize(Size) + ", " + Interface + ")" + letters
                + (IsSystem ? "  ** WINDOWS SYSTEM DISK **" : "");
        }

        public override string ToString() { return Describe(); }

        public static List<DiskInfo> Enumerate()
        {
            List<DiskInfo> list = new List<DiskInfo>();
            string sysDrive = (Environment.GetEnvironmentVariable("SystemDrive") ?? "C:").ToUpperInvariant();

            using (ManagementObjectSearcher s = new ManagementObjectSearcher("SELECT * FROM Win32_DiskDrive"))
            {
                foreach (ManagementObject d in s.Get())
                {
                    if (d["Index"] == null) continue;
                    DiskInfo info = new DiskInfo();
                    info.Index = Convert.ToInt32(d["Index"]);
                    info.Model = Convert.ToString(d["Model"]).Trim();
                    info.Interface = Convert.ToString(d["InterfaceType"]).Trim();
                    info.Serial = Convert.ToString(d["SerialNumber"]).Trim();
                    info.Size = d["Size"] == null ? 0 : Convert.ToInt64(d["Size"]);

                    try
                    {
                        using (RawDisk rd = new RawDisk(info.Index, false)) info.Size = rd.Length();
                    }
                    catch { /* keep WMI size (slightly smaller than real) */ }

                    string devId = Convert.ToString(d["DeviceID"]).Replace("\\", "\\\\");
                    try
                    {
                        string q1 = "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='" + devId + "'} WHERE AssocClass=Win32_DiskDriveToDiskPartition";
                        using (ManagementObjectSearcher ps = new ManagementObjectSearcher(q1))
                        {
                            foreach (ManagementObject p in ps.Get())
                            {
                                string q2 = "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='" + p["DeviceID"] + "'} WHERE AssocClass=Win32_LogicalDiskToPartition";
                                using (ManagementObjectSearcher ls = new ManagementObjectSearcher(q2))
                                {
                                    foreach (ManagementObject l in ls.Get())
                                    {
                                        string letter = Convert.ToString(l["DeviceID"]).ToUpperInvariant();
                                        info.Letters.Add(letter);
                                        if (letter == sysDrive) info.IsSystem = true;
                                    }
                                }
                            }
                        }
                    }
                    catch { }

                    info.Letters.Sort();
                    if (info.Size > 0) list.Add(info);   // skip empty card readers etc.
                }
            }
            list.Sort(delegate(DiskInfo a, DiskInfo b) { return a.Index.CompareTo(b.Index); });
            return list;
        }
    }

    internal static class Util
    {
        public static string FormatSize(double bytes)
        {
            string[] u = { "B", "KB", "MB", "GB", "TB" };
            int i = 0;
            while (bytes >= 1000 && i < u.Length - 1) { bytes /= 1000; i++; }
            return bytes.ToString(i == 0 ? "0" : "0.0") + " " + u[i];
        }

        public static string FormatTime(double seconds)
        {
            if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds < 0) return "--:--";
            TimeSpan t = TimeSpan.FromSeconds(seconds);
            return (int)t.TotalHours + ":" + t.Minutes.ToString("00") + ":" + t.Seconds.ToString("00");
        }

        public static string RunDiskpart(string script)
        {
            string file = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "drivecloner_" + Guid.NewGuid().ToString("N") + ".txt");
            File.WriteAllText(file, script, Encoding.ASCII);
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("diskpart.exe", "/s \"" + file + "\"");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                using (Process p = Process.Start(psi))
                {
                    string output = p.StandardOutput.ReadToEnd();
                    p.WaitForExit();
                    return output;
                }
            }
            finally { try { File.Delete(file); } catch { } }
        }
    }

    // ---------------------------------------------------------------- CRC32
    internal static class Crc32
    {
        private static readonly uint[] Table = MakeTable();

        private static uint[] MakeTable()
        {
            uint[] t = new uint[256];
            for (uint i = 0; i < 256; i++)
            {
                uint c = i;
                for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
                t[i] = c;
            }
            return t;
        }

        public static uint Compute(byte[] data, int offset, int count)
        {
            uint c = 0xFFFFFFFF;
            for (int i = offset; i < offset + count; i++) c = Table[(c ^ data[i]) & 0xFF] ^ (c >> 8);
            return c ^ 0xFFFFFFFF;
        }
    }

    // ------------------------------------------------------------ clone job
    public class CloneJob
    {
        public int SourceIndex, TargetIndex;
        public bool Verify, SkipBadSectors;

        // progress, read by the UI thread
        public volatile string Phase = "Starting...";
        public long Done;          // bytes processed in current phase
        public long Total;         // bytes in current phase
        public volatile int BadSectors;
        public volatile bool Finished;
        public volatile bool Success;
        public volatile string Message = "";
        public volatile bool CancelRequested;

        private const int ChunkSize = 4 * 1024 * 1024;

        public void Run()
        {
            List<SafeFileHandle> volumeLocks = new List<SafeFileHandle>();
            try
            {
                Phase = "Preparing target disk...";
                volumeLocks = LockTargetVolumes(TargetIndex);
                // Taking the disk offline unmounts every volume on it (including ones
                // without a drive letter) so Windows lets us write the raw sectors.
                Util.RunDiskpart("select disk " + TargetIndex + "\r\nattributes disk clear readonly noerr\r\noffline disk noerr\r\n");

                using (RawDisk src = new RawDisk(SourceIndex, false))
                using (RawDisk dst = new RawDisk(TargetIndex, true))
                {
                    long srcLen = src.Length();
                    long dstLen = dst.Length();
                    int ss = Math.Max(src.SectorSize(), dst.SectorSize());
                    if (src.SectorSize() != dst.SectorSize())
                        throw new IOException("The disks use different sector sizes (" + src.SectorSize() + " vs " + dst.SectorSize()
                            + " bytes). A raw clone would not be usable.");
                    if (dstLen < srcLen)
                        throw new IOException("Target disk is smaller than the source disk.");

                    Copy(src, dst, srcLen, ss);
                    if (CancelRequested) throw new OperationCanceledException();

                    string gptNote = "";
                    if (dstLen > srcLen)
                    {
                        Phase = "Adjusting partition table for larger disk...";
                        gptNote = FixGpt(dst, srcLen, dstLen, ss);
                    }

                    if (Verify)
                    {
                        VerifyCopy(src, dst, srcLen);
                        if (CancelRequested) throw new OperationCanceledException();
                    }

                    dst.UpdateProperties();

                    StringBuilder sb = new StringBuilder();
                    sb.Append("Clone finished successfully.\r\n\r\nCopied " + Util.FormatSize(srcLen) + ".");
                    if (Verify) sb.Append(" Verification passed.");
                    if (BadSectors > 0) sb.Append("\r\n\r\nWARNING: " + BadSectors + " unreadable sector(s) on the source were replaced with zeros.");
                    if (gptNote.Length > 0) sb.Append("\r\n\r\n" + gptNote);
                    if (dstLen > srcLen)
                        sb.Append("\r\n\r\nThe target is larger than the source. Use Disk Management to extend the last partition into the "
                            + Util.FormatSize(dstLen - srcLen) + " of unallocated space if you want to use it.");
                    sb.Append("\r\n\r\nTip: disconnect one of the two disks before booting. Windows does not like two identical disks connected at the same time.");
                    Message = sb.ToString();
                    Success = true;
                }
            }
            catch (OperationCanceledException)
            {
                Message = "Cancelled. The target disk is now only partially written and will not be usable until you clone again or re-partition it.";
            }
            catch (Exception ex)
            {
                Message = "Clone failed:\r\n\r\n" + ex.Message;
            }
            finally
            {
                foreach (SafeFileHandle h in volumeLocks) { try { h.Dispose(); } catch { } }
                try { Util.RunDiskpart("select disk " + TargetIndex + "\r\nonline disk noerr\r\n"); } catch { }
                Phase = Success ? "Done" : "Stopped";
                Finished = true;
            }
        }

        private static List<SafeFileHandle> LockTargetVolumes(int diskIndex)
        {
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            DiskInfo target = null;
            foreach (DiskInfo d in DiskInfo.Enumerate()) if (d.Index == diskIndex) target = d;
            if (target == null) return handles;

            foreach (string letter in target.Letters)
            {
                SafeFileHandle h = Native.CreateFile(@"\\.\" + letter, Native.GENERIC_READ | Native.GENERIC_WRITE,
                    Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE, IntPtr.Zero, Native.OPEN_EXISTING, 0, IntPtr.Zero);
                if (h.IsInvalid) continue;
                int ret;
                bool locked = false;
                for (int i = 0; i < 20 && !locked; i++)
                {
                    locked = Native.DeviceIoControl(h, Native.FSCTL_LOCK_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                    if (!locked) Thread.Sleep(250);
                }
                if (!locked)
                {
                    h.Dispose();
                    foreach (SafeFileHandle o in handles) o.Dispose();
                    throw new IOException("Drive " + letter + " on the target disk is in use. Close any programs or windows using it and try again.");
                }
                Native.DeviceIoControl(h, Native.FSCTL_DISMOUNT_VOLUME, IntPtr.Zero, 0, IntPtr.Zero, 0, out ret, IntPtr.Zero);
                handles.Add(h);
            }
            return handles;
        }

        private void Copy(RawDisk src, RawDisk dst, long length, int ss)
        {
            Phase = "Copying";
            Interlocked.Exchange(ref Total, length);
            Interlocked.Exchange(ref Done, 0);
            using (AlignedBuffer buf = new AlignedBuffer(ChunkSize))
            {
                long pos = 0;
                while (pos < length)
                {
                    if (CancelRequested) return;
                    int n = (int)Math.Min(ChunkSize, length - pos);

                    if (!src.TryRead(pos, buf, 0, n))
                    {
                        if (!SkipBadSectors)
                            throw Native.LastError("Cannot read source disk at byte " + pos
                                + " (bad sector?). Enable 'Skip unreadable sectors' to continue past errors");
                        // fall back to sector-by-sector reads, zero-filling the bad ones
                        for (int off = 0; off < n; off += ss)
                        {
                            if (!src.TryRead(pos + off, buf, off, ss))
                            {
                                buf.Zero(off, ss);
                                BadSectors++;
                            }
                        }
                    }

                    dst.Write(pos, buf, 0, n);
                    pos += n;
                    Interlocked.Exchange(ref Done, pos);
                }
            }
        }

        private void VerifyCopy(RawDisk src, RawDisk dst, long length)
        {
            Phase = "Verifying";
            Interlocked.Exchange(ref Total, length);
            Interlocked.Exchange(ref Done, 0);
            // The GPT fix-up legitimately changes the first two sectors and the area of the
            // old backup table near the end of the source; differences there are expected.
            using (AlignedBuffer a = new AlignedBuffer(ChunkSize))
            using (AlignedBuffer b = new AlignedBuffer(ChunkSize))
            {
                long pos = 0;
                while (pos < length)
                {
                    if (CancelRequested) return;
                    int n = (int)Math.Min(ChunkSize, length - pos);
                    bool readOk = src.TryRead(pos, a, 0, n);
                    dst.Read(pos, b, 0, n);
                    bool differs = readOk && Native.memcmp(a.Ptr, b.Ptr, new UIntPtr((uint)n)) != 0;
                    if (differs && !gptRewritten)
                        throw new IOException("Verification failed: data differs in the block at byte " + pos + ".");
                    if (differs)
                    {
                        byte[] x = a.ToArray(n), y = b.ToArray(n);
                        for (int i = 0; i < n; i++)
                        {
                            if (x[i] == y[i]) continue;
                            long abs = pos + i;
                            if (abs < gptHeadEnd || abs >= gptTailStart) continue;
                            throw new IOException("Verification failed: data differs at byte " + abs + ".");
                        }
                    }
                    // unreadable source blocks (bad sectors) are skipped
                    pos += n;
                    Interlocked.Exchange(ref Done, pos);
                }
            }
        }

        private bool gptRewritten;
        private long gptHeadEnd, gptTailStart;

        // When the target is larger than the source, the GPT backup header ends up in
        // the middle of the disk. Move it to the real end and update the primary header
        // so Windows can use the extra space.
        private string FixGpt(RawDisk dst, long srcLen, long dstLen, int ss)
        {
            using (AlignedBuffer buf = new AlignedBuffer(Math.Max(ss * 2, 64 * 1024)))
            {
                dst.Read(0, buf, 0, ss * 2);
                byte[] lba01 = buf.ToArray(ss * 2);
                if (Encoding.ASCII.GetString(lba01, ss, 8) != "EFI PART")
                    return ""; // MBR disk - nothing to do

                byte[] hdr = new byte[ss];
                Array.Copy(lba01, ss, hdr, 0, ss);
                int hdrSize = BitConverter.ToInt32(hdr, 12);
                if (hdrSize < 92 || hdrSize > ss) return "Note: GPT header looks unusual; it was left unchanged.";
                long entryLba = BitConverter.ToInt64(hdr, 72);
                int numEntries = BitConverter.ToInt32(hdr, 80);
                int entrySize = BitConverter.ToInt32(hdr, 84);
                long entryBytes = (long)numEntries * entrySize;
                if (entryBytes <= 0 || entryBytes > 4 * 1024 * 1024) return "Note: GPT header looks unusual; it was left unchanged.";
                int entrySectors = (int)((entryBytes + ss - 1) / ss);

                // read the partition entry array
                byte[] entries;
                using (AlignedBuffer eb = new AlignedBuffer(entrySectors * ss))
                {
                    dst.Read(entryLba * ss, eb, 0, entrySectors * ss);
                    entries = eb.ToArray(entrySectors * ss);
                }

                long totalSectors = dstLen / ss;
                long backupHdrLba = totalSectors - 1;
                long backupEntriesLba = backupHdrLba - entrySectors;
                long lastUsable = backupEntriesLba - 1;
                long oldBackupLba = BitConverter.ToInt64(hdr, 32);

                // primary header
                PutInt64(hdr, 32, backupHdrLba);
                PutInt64(hdr, 48, lastUsable);
                SetHeaderCrc(hdr, hdrSize);

                // backup header
                byte[] bak = (byte[])hdr.Clone();
                PutInt64(bak, 24, backupHdrLba);
                PutInt64(bak, 32, 1);
                PutInt64(bak, 72, backupEntriesLba);
                SetHeaderCrc(bak, hdrSize);

                // protective MBR: size of the 0xEE partition
                byte[] mbr = new byte[ss];
                Array.Copy(lba01, 0, mbr, 0, ss);
                for (int i = 0; i < 4; i++)
                {
                    int e = 446 + i * 16;
                    if (mbr[e + 4] == 0xEE)
                    {
                        long size = Math.Min(totalSectors - 1, 0xFFFFFFFFL);
                        byte[] sz = BitConverter.GetBytes((uint)size);
                        Array.Copy(sz, 0, mbr, e + 12, 4);
                    }
                }

                WriteSectors(dst, 0, mbr, ss);
                WriteSectors(dst, ss, hdr, ss);
                WriteSectors(dst, backupEntriesLba * ss, entries, ss);
                WriteSectors(dst, backupHdrLba * ss, bak, ss);

                // wipe the stale backup header that was copied from the source
                if (oldBackupLba > 1 && oldBackupLba < backupEntriesLba)
                    WriteSectors(dst, oldBackupLba * ss, new byte[ss], ss);

                gptRewritten = true;
                gptHeadEnd = 2L * ss;
                gptTailStart = Math.Min(srcLen - (long)(entrySectors + 1) * ss, oldBackupLba * ss);
                return "The GPT partition table was updated to cover the whole target disk.";
            }
        }

        private static void WriteSectors(RawDisk dst, long pos, byte[] data, int ss)
        {
            int len = (data.Length + ss - 1) / ss * ss;
            using (AlignedBuffer b = new AlignedBuffer(len))
            {
                b.Zero(0, len);
                b.FromArray(data);
                dst.Write(pos, b, 0, len);
            }
        }

        private static void PutInt64(byte[] b, int off, long v)
        {
            Array.Copy(BitConverter.GetBytes(v), 0, b, off, 8);
        }

        private static void SetHeaderCrc(byte[] hdr, int hdrSize)
        {
            Array.Clear(hdr, 16, 4);
            uint crc = Crc32.Compute(hdr, 0, hdrSize);
            Array.Copy(BitConverter.GetBytes(crc), 0, hdr, 16, 4);
        }
    }

    // -------------------------------------------------------------------- UI
    public class MainForm : Form
    {
        private ComboBox cbSource = new ComboBox();
        private ComboBox cbTarget = new ComboBox();
        private Button btnRefresh = new Button();
        private CheckBox chkVerify = new CheckBox();
        private CheckBox chkSkipBad = new CheckBox();
        private ProgressBar progress = new ProgressBar();
        private Label lblStatus = new Label();
        private Label lblDetail = new Label();
        private Button btnStart = new Button();
        private Button btnCancel = new Button();
        private System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();

        private CloneJob job;
        private Thread worker;
        private Stopwatch phaseWatch = new Stopwatch();
        private string lastPhase = "";

        public MainForm()
        {
            Text = "Drive Cloner";
            Font = new Font("Segoe UI", 9f);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(620, 330);

            int x = 16, w = 588;
            AddLabel("Source disk  (copy FROM):", x, 14, true);
            cbSource.SetBounds(x, 34, w, 24);
            cbSource.DropDownStyle = ComboBoxStyle.DropDownList;
            Controls.Add(cbSource);

            AddLabel("Target disk  (copy TO  -  EVERYTHING ON IT WILL BE ERASED):", x, 70, true);
            cbTarget.SetBounds(x, 90, w, 24);
            cbTarget.DropDownStyle = ComboBoxStyle.DropDownList;
            Controls.Add(cbTarget);

            chkVerify.Text = "Verify after copying (takes about twice as long)";
            chkVerify.SetBounds(x, 126, 400, 22);
            Controls.Add(chkVerify);

            chkSkipBad.Text = "Skip unreadable sectors on the source (fill with zeros)";
            chkSkipBad.SetBounds(x, 150, 400, 22);
            Controls.Add(chkSkipBad);

            btnRefresh.Text = "Refresh disks";
            btnRefresh.SetBounds(x + w - 120, 126, 120, 28);
            btnRefresh.Click += delegate { LoadDisks(); };
            Controls.Add(btnRefresh);

            progress.SetBounds(x, 188, w, 24);
            progress.Maximum = 1000;
            Controls.Add(progress);

            lblStatus.SetBounds(x, 218, w, 20);
            lblStatus.Text = "Select a source and a target disk.";
            Controls.Add(lblStatus);

            lblDetail.SetBounds(x, 238, w, 36);
            lblDetail.ForeColor = SystemColors.GrayText;
            Controls.Add(lblDetail);

            btnStart.Text = "Start Clone";
            btnStart.SetBounds(x + w - 250, 284, 120, 32);
            btnStart.Click += OnStart;
            Controls.Add(btnStart);

            btnCancel.Text = "Cancel";
            btnCancel.SetBounds(x + w - 120, 284, 120, 32);
            btnCancel.Enabled = false;
            btnCancel.Click += OnCancel;
            Controls.Add(btnCancel);

            timer.Interval = 250;
            timer.Tick += OnTick;

            cbSource.SelectedIndexChanged += delegate { UpdateDetail(); };
            cbTarget.SelectedIndexChanged += delegate { UpdateDetail(); };

            Load += delegate { LoadDisks(); };
            FormClosing += OnClosing;
        }

        private void AddLabel(string text, int x, int y, bool bold)
        {
            Label l = new Label();
            l.Text = text;
            l.AutoSize = true;
            l.Location = new Point(x, y);
            if (bold) l.Font = new Font(Font, FontStyle.Bold);
            Controls.Add(l);
        }

        private void LoadDisks()
        {
            Cursor = Cursors.WaitCursor;
            try
            {
                List<DiskInfo> disks = DiskInfo.Enumerate();
                cbSource.Items.Clear();
                cbTarget.Items.Clear();
                foreach (DiskInfo d in disks)
                {
                    cbSource.Items.Add(d);
                    cbTarget.Items.Add(d);
                }
                lblStatus.Text = disks.Count + " disk(s) found. Select a source and a target disk.";
                UpdateDetail();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Could not list disks:\r\n" + ex.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally { Cursor = Cursors.Default; }
        }

        private void UpdateDetail()
        {
            DiskInfo s = cbSource.SelectedItem as DiskInfo;
            DiskInfo t = cbTarget.SelectedItem as DiskInfo;
            string msg = "";
            if (s != null && t != null)
            {
                if (s.Index == t.Index) msg = "Source and target must be different disks.";
                else if (t.IsSystem) msg = "The target is the disk Windows is running from. That is not allowed.";
                else if (t.Size < s.Size) msg = "Target (" + Util.FormatSize(t.Size) + ") is smaller than source (" + Util.FormatSize(s.Size) + "). The target must be the same size or larger.";
                else
                {
                    msg = "Will copy " + Util.FormatSize(s.Size) + " from Disk " + s.Index + " to Disk " + t.Index + ".";
                    if (s.IsSystem) msg += " The source is the running Windows disk: close other programs first; files changing during the copy may not be captured consistently.";
                }
            }
            lblDetail.Text = msg;
        }

        private void OnStart(object sender, EventArgs e)
        {
            DiskInfo s = cbSource.SelectedItem as DiskInfo;
            DiskInfo t = cbTarget.SelectedItem as DiskInfo;
            if (s == null || t == null) { Warn("Please select both a source and a target disk."); return; }
            if (s.Index == t.Index) { Warn("Source and target must be different disks."); return; }
            if (t.IsSystem) { Warn("You cannot overwrite the disk Windows is currently running from."); return; }
            if (t.Size < s.Size) { Warn("The target disk is smaller than the source disk."); return; }

            string confirm = "ALL DATA ON THE TARGET DISK WILL BE PERMANENTLY ERASED:\r\n\r\n    " + t.Describe()
                + "\r\n\r\nIt will be overwritten with an exact copy of:\r\n\r\n    " + s.Describe()
                + "\r\n\r\nAre you absolutely sure?";
            if (MessageBox.Show(this, confirm, "Confirm clone", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                return;

            job = new CloneJob();
            job.SourceIndex = s.Index;
            job.TargetIndex = t.Index;
            job.Verify = chkVerify.Checked;
            job.SkipBadSectors = chkSkipBad.Checked;

            SetBusy(true);
            progress.Value = 0;
            lastPhase = "";
            worker = new Thread(job.Run);
            worker.IsBackground = true;
            worker.Start();
            timer.Start();
        }

        private void OnCancel(object sender, EventArgs e)
        {
            if (job == null) return;
            if (MessageBox.Show(this, "Stop cloning? The target disk will be left incomplete.", "Cancel", MessageBoxButtons.YesNo,
                    MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) == DialogResult.Yes)
            {
                job.CancelRequested = true;
                btnCancel.Enabled = false;
                lblStatus.Text = "Cancelling...";
            }
        }

        private void OnTick(object sender, EventArgs e)
        {
            if (job == null) return;
            string phase = job.Phase;
            if (phase != lastPhase) { lastPhase = phase; phaseWatch.Reset(); phaseWatch.Start(); }

            long done = Interlocked.Read(ref job.Done);
            long total = Interlocked.Read(ref job.Total);
            if ((phase == "Copying" || phase == "Verifying") && total > 0)
            {
                double frac = (double)done / total;
                progress.Value = Math.Max(0, Math.Min(1000, (int)(frac * 1000)));
                double secs = phaseWatch.Elapsed.TotalSeconds;
                double rate = secs > 0.5 ? done / secs : 0;
                double eta = rate > 0 ? (total - done) / rate : double.NaN;
                lblStatus.Text = phase + ":  " + Util.FormatSize(done) + " of " + Util.FormatSize(total)
                    + "  (" + (frac * 100).ToString("0.0") + "%)    " + Util.FormatSize(rate) + "/s    "
                    + "time left " + Util.FormatTime(eta)
                    + (job.BadSectors > 0 ? "    bad sectors: " + job.BadSectors : "");
            }
            else if (!job.Finished)
            {
                lblStatus.Text = phase;
            }

            if (job.Finished)
            {
                timer.Stop();
                SetBusy(false);
                if (job.Success) progress.Value = 1000;
                lblStatus.Text = job.Success ? "Clone complete." : "Clone did not complete.";
                MessageBox.Show(this, job.Message, Text, MessageBoxButtons.OK, job.Success ? MessageBoxIcon.Information : MessageBoxIcon.Error);
                job = null;
                LoadDisks();
            }
        }

        private void SetBusy(bool busy)
        {
            cbSource.Enabled = cbTarget.Enabled = btnRefresh.Enabled = btnStart.Enabled = !busy;
            chkVerify.Enabled = chkSkipBad.Enabled = !busy;
            btnCancel.Enabled = busy;
        }

        private void OnClosing(object sender, FormClosingEventArgs e)
        {
            if (job != null && !job.Finished)
            {
                if (MessageBox.Show(this, "A clone is in progress. Stop it and exit? The target disk will be left incomplete.", Text,
                        MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2) != DialogResult.Yes)
                {
                    e.Cancel = true;
                    return;
                }
                job.CancelRequested = true;
                if (worker != null) worker.Join(15000);
            }
        }

        private void Warn(string msg)
        {
            MessageBox.Show(this, msg, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    public static class Program
    {
        public static void Run()
        {
            WindowsPrincipal p = new WindowsPrincipal(WindowsIdentity.GetCurrent());
            if (!p.IsInRole(WindowsBuiltInRole.Administrator))
            {
                MessageBox.Show("Drive Cloner must be run as Administrator.", "Drive Cloner", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }
            Application.EnableVisualStyles();
            Application.Run(new MainForm());
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $source -Language CSharp `
        -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Management
    [DriveCloner.Program]::Run()
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "Drive Cloner failed to start:`r`n`r`n$($_.Exception.Message)",
        'Drive Cloner', 'OK', 'Error') | Out-Null
}
