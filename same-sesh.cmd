@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\same-sesh.ps1" %*
