#!/bin/bash
# setup.sh [build dir] [data dir] [extra data dir]
#
# Builds the runtime directory $HEADLESS_ROOT/game (default /opt/stellaris-headless/game):
#   - the Linux 4.5.2 executable and its shared libraries (Steam depot 281994), copied;
#   - the game data (common depot), copied: the game's file system (PhysFS) refuses symbolic
#     links ("symlinks are forbidden"), and the sources are not to be modified;
#   - the folders the common-depot copy on this box lacks (unchecked_defines: without its
#     interface defines the in-game GUI crashes in CPlanetView::Reload; dlc_metadata,
#     curated_save_games, pdx_online_assets, tweakergui_assets, locales), from a Windows Steam
#     install of the same version (same checksum_manifest.txt);
#   - the preload, headless.so.
# Idempotent (rsync); a second run only checks.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${HEADLESS_ROOT:-/opt/stellaris-headless}
BUILD=${1:-/zpool0/share/stellaris_backups_steam/by_manifest/281994/1994331557761953329}
DATA=${2:-/opt/stellaris}
EXTRA=${3:-}

mkdir -p "$ROOT/game" "$ROOT/work" "$ROOT/cache/mesa"
for f in stellaris libsteam_api.so libnakama-sdk.so libPDXSDK.so steam_appid.txt launcher-settings.json \
	settings-layout.json metadata.json assets crash_reporter; do
	rsync -a "$BUILD/$f" "$ROOT/game/"
done
chmod +x "$ROOT/game/stellaris"
rsync -a --exclude '*.msi' --exclude '*.exe' --exclude '*.dll' "$DATA/" "$ROOT/game/"
if [ -n "$EXTRA" ]; then
	for d in unchecked_defines dlc_metadata curated_save_games pdx_online_assets tweakergui_assets locales; do
		[ -d "$EXTRA/$d" ] && rsync -a "$EXTRA/$d" "$ROOT/game/"
	done
fi
for d in unchecked_defines dlc_metadata; do
	[ -d "$ROOT/game/$d" ] || echo "warning: $ROOT/game/$d is missing (copy it from a Windows install: setup.sh ... <extra dir>)" >&2
done
if [ -n "$(find "$ROOT/game" -maxdepth 1 -type l)" ]; then
	echo "warning: symbolic links in $ROOT/game; the game will not read through them" >&2
fi
gcc -O2 -Wall -shared -fPIC -o "$ROOT/headless.so" "$HERE/headless.c" -ldl -lpthread
cmp -s "$ROOT/game/checksum_manifest.txt" "$DATA/checksum_manifest.txt" && echo "data: checksum_manifest.txt matches $DATA"
echo "ready: $ROOT (game $(du -sh "$ROOT/game" | cut -f1))"
