@echo off
echo Building nv_shield_tv-dmw.c4z...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1"
if errorlevel 1 (
    echo ERROR: Build failed.
    exit /b 1
)
