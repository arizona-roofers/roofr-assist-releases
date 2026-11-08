@echo off
rem Chrome starts this (native messaging host com.arizonaroofers.notes); it runs the PowerShell helper next to it.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0notes-helper.ps1"
