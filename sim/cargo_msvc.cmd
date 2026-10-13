@echo off
rem cargo_msvc.cmd <cargo args> : cargo in this crate with the MSVC environment, which the vendored
rem LuaJIT build (mlua-sys) needs. With STELLARIS_DIR set to the game's folder, the tests read the
rem vanilla scripts in place. Build mlua-sys with -j 1 (two builds at once broke it).
rem   set STELLARIS_DIR=C:\Program Files (x86)\Steam\steamapps\common\Stellaris
rem   sim\cargo_msvc.cmd test -j 1
setlocal
rem LuaJIT's build runs tools from its own folder
set NoDefaultCurrentDirectoryInExePath=
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath`) do set VS=%%i
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
set PATH=%USERPROFILE%\.cargo\bin;%PATH%
rem build on the local disk, not the share the crate is on
if not defined CARGO_TARGET_DIR set CARGO_TARGET_DIR=%LOCALAPPDATA%\stellarstellaris\simtarget
cd /d "%~dp0" || exit /b 1
cargo %*
