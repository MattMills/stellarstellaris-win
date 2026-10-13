@echo off
rem Removes StellarStellaris from the Stellaris folder (see install.ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Uninstall %*
pause
