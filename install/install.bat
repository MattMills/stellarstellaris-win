@echo off
rem Installs StellarStellaris into the Stellaris folder (see install.ps1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
