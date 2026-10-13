# install.ps1 : installs StellarStellaris into the Stellaris folder, or removes it (-Uninstall).
#
#   install.bat                    (or: powershell -ExecutionPolicy Bypass -File install.ps1)
#   uninstall.bat                  (or: ... install.ps1 -Uninstall)
#   install.ps1 -GameDir "D:\Games\Stellaris"   when the game is not found
#
# Installing copies, from the folder of this script:
#   proxy\version.dll           -> <Stellaris>\version.dll  (Windows loads it with the game: it
#                                  starts StellarStellaris before the game reads its script)
#   stellar-injected.dll, .pdb  -> <Stellaris>\stellarstellaris\
#   lua\                        -> <Stellaris>\stellarstellaris\lua\
# Uninstalling removes <Stellaris>\version.dll (only if it is StellarStellaris's),
# <Stellaris>\stellarstellaris\ and <Stellaris>\stellarstellaris.txt. Nothing else is touched.
param([string]$GameDir, [switch]$Uninstall)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot

# The Stellaris folders of Steam (every library) and GOG on this machine
function Find-Stellaris {
    $found = @()
    $steam = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if ($steam) {
        $libraries = @($steam -replace "/", "\")
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libraries += $m.Groups[1].Value -replace "\\\\", "\"
            }
        }
        foreach ($library in $libraries | Select-Object -Unique) {
            $found += Join-Path $library "steamapps\common\Stellaris"
        }
    }
    foreach ($key in @("HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games", "HKLM:\SOFTWARE\GOG.com\Games")) {
        Get-ChildItem $key -ErrorAction SilentlyContinue | ForEach-Object {
            $game = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($game.gameName -match "Stellaris" -and $game.path) { $found += $game.path }
        }
    }
    # one of each folder (paths differ in case between the registry and Steam's library file)
    $unique = [ordered]@{}
    foreach ($dir in $found) {
        $key = $dir.TrimEnd("\").ToLowerInvariant()
        if (-not $unique.Contains($key) -and (Test-Path (Join-Path $dir "stellaris.exe"))) {
            $unique[$key] = $dir.TrimEnd("\")
        }
    }
    $unique.Values
}

# Whether a version.dll is StellarStellaris's proxy (it names itself in a UTF-16 string)
function Test-OurProxy([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $text = [System.Text.Encoding]::Unicode.GetString($bytes) + [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
    return $text.Contains("version.dll (StellarStellaris)")
}

if (-not $GameDir) {
    $games = @(Find-Stellaris)
    if ($games.Count -eq 0) {
        throw "Stellaris was not found (Steam or GOG). Run again with -GameDir <the folder of stellaris.exe>."
    }
    if ($games.Count -gt 1) {
        throw "Stellaris was found in more than one place:`n  $($games -join "`n  ")`nRun again with -GameDir <one of them>."
    }
    $GameDir = $games[0]
}
if (-not (Test-Path (Join-Path $GameDir "stellaris.exe"))) {
    throw "$GameDir has no stellaris.exe."
}
if (Get-Process stellaris -ErrorAction SilentlyContinue) {
    throw "Stellaris is running: close the game first."
}
$proxy = Join-Path $GameDir "version.dll"
$folder = Join-Path $GameDir "stellarstellaris"
$config = Join-Path $GameDir "stellarstellaris.txt"

if ($Uninstall) {
    if (Test-Path $proxy) {
        if (Test-OurProxy $proxy) {
            Remove-Item $proxy
            "removed $proxy"
        } else {
            "left $proxy alone: it is not StellarStellaris's"
        }
    }
    if (Test-Path $folder) {
        Remove-Item $folder -Recurse
        "removed $folder"
    }
    if (Test-Path $config) {
        Remove-Item $config
        "removed $config"
    }
    "StellarStellaris is uninstalled from $GameDir"
    return
}

foreach ($file in @("stellar-injected.dll", "lua", "proxy\version.dll")) {
    if (-not (Test-Path (Join-Path $here $file))) {
        throw "$file is missing next to install.ps1: extract the whole archive."
    }
}
if ((Test-Path $proxy) -and -not (Test-OurProxy $proxy)) {
    throw "$proxy is there and is not StellarStellaris's (another mod?): not installing over it."
}
New-Item -ItemType Directory -Force $folder | Out-Null
Copy-Item (Join-Path $here "stellar-injected.dll") $folder -Force
if (Test-Path (Join-Path $here "stellar-injected.pdb")) {
    Copy-Item (Join-Path $here "stellar-injected.pdb") $folder -Force
}
# the scripts: replaced as a whole, so that none is left from an older version
$lua = Join-Path $folder "lua"
if (Test-Path $lua) { Remove-Item $lua -Recurse }
Copy-Item (Join-Path $here "lua") $lua -Recurse
Copy-Item (Join-Path $here "proxy\version.dll") $proxy -Force
"installed into $GameDir :"
"  $proxy"
"  $folder\ (stellar-injected.dll, lua\)"
if (Test-Path $config) {
    "note: $config is there and chooses which stellar-injected.dll is loaded; remove it to use the installed one"
}
"Start Stellaris as usual. The log is Documents\Paradox Interactive\Stellaris\logs\stellarstellaris-debug.log."
