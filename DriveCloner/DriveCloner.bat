@echo off
rem Drive Cloner launcher - no installation needed. Keep this next to DriveCloner.ps1.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File "%~dp0DriveCloner.ps1"
