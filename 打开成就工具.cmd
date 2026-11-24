@echo off
start "" conhost.exe --headless "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0SteamAchievements.ps1" %*
