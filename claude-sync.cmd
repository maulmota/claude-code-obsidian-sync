@echo off
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0claude-sync.ps1" %*
