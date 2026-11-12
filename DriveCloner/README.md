# Drive Cloner

A small, portable tool for Windows that makes an exact sector-by-sector copy of one disk onto another. You don't install anything: it runs on the PowerShell and .NET Framework that already come with Windows 10 and 11.

## How to use

1. Copy `DriveCloner.bat` and `DriveCloner.ps1` into the same folder. A USB stick works.
2. Double-click **`DriveCloner.bat`** and say **Yes** to the Administrator prompt.
3. Pick the **Source** disk (copy from) and the **Target** disk (copy to).
4. If you want, tick **Verify after copying** or **Skip unreadable sectors**.
5. Click **Start Clone** and confirm.

## Things to know

- **Everything on the target disk is erased.** Check the disk number, model and size before you confirm.
- The target must be **the same size or larger** than the source. Both disks must also use the same sector size.
- If the target is larger, the tool fixes the GPT partition table so the extra space can be used. The new space shows up as *unallocated*. To use it, open Disk Management and choose **Extend Volume** on the last partition.
- You can't pick the disk Windows is running from as the target. You *can* pick it as the source, but files that change during the copy may not be captured consistently. Close other programs first. For a fully clean copy, clone from another Windows install or a WinPE boot USB.
- When the clone finishes, **disconnect one of the two disks** before rebooting. Windows takes a second disk with the same identity offline ("signature collision").
- Cancelling partway leaves the target unusable until you clone again or re-partition it.

## Troubleshooting

- **"Drive X: on the target disk is in use"**: close any Explorer windows or programs that are using that drive, then try again.
- **Read error on the source**: the disk may have bad sectors. Tick *Skip unreadable sectors* to copy everything else. Unreadable sectors are filled with zeros and counted in the final report.
- **Nothing happens on double-click**: right-click `DriveCloner.ps1` and choose **Run with PowerShell** to see any error message.
