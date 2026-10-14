#!/bin/bash
# Lays out the release packages (docs/ci.md). Used by .github/workflows/build.yml.
#
#   package.sh render <binary> <dir>
#       the renderer: the binary and the Lua it reads at run time, in the repository's layout
#       (sim/lua, sim/render/lua, lua, lib/stellar-lua-pdxscript/*.lua), with the licenses
#   package.sh archive <out> <version> <mod> <render-linux> <render-windows>
#       the release archives from the job artifacts (the mod's files merged in <mod>), each with
#       VERSION, and SHA256SUMS:
#         stellarstellaris-<version>-windows-x64.zip
#         stellar-render-<version>-linux-x64.tar.gz
#         stellar-render-<version>-windows-x64.zip
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"

case "${1:-}" in
render)
	binary="$2" dir="$3"
	mkdir -p "$dir/sim/render" "$dir/lib/stellar-lua-pdxscript"
	cp "$binary" "$dir/"
	cp -R "$repo/sim/lua" "$dir/sim/lua"
	cp -R "$repo/sim/render/lua" "$dir/sim/render/lua"
	cp -R "$repo/lua" "$dir/lua"
	cp "$repo"/lib/stellar-lua-pdxscript/*.lua "$repo/lib/stellar-lua-pdxscript/LICENSE.txt" \
		"$dir/lib/stellar-lua-pdxscript/"
	cp "$repo/LICENSE" "$dir/"
	;;
archive)
	out="$2" version="$3" mod="$4" linux="$5" windows="$6"
	mkdir -p "$out"
	out="$(cd "$out" && pwd)"
	stage="$(mktemp -d)"
	trap 'rm -rf "$stage"' EXIT
	# pack NAME SOURCE: the folder an archive unpacks to, with LICENSE and VERSION
	pack() {
		local name="$1" source="$2"
		cp -R "$source" "$stage/$name"
		cp "$repo/LICENSE" "$stage/$name/"
		printf '%s\n' "$version" > "$stage/$name/VERSION"
	}
	pack "stellarstellaris-$version-windows-x64" "$mod"
	pack "stellar-render-$version-linux-x64" "$linux"
	pack "stellar-render-$version-windows-x64" "$windows"
	for f in stellar-injected.dll stellar-loader.exe proxy/version.dll lua/init.lua lua/pdxscript.lua install.ps1; do
		[ -f "$stage/stellarstellaris-$version-windows-x64/$f" ] || { echo "the mod package has no $f"; exit 1; }
	done
	# artifacts do not keep file modes
	chmod 755 "$stage/stellar-render-$version-linux-x64/stellar-render"
	cd "$stage"
	zip -qrX "$out/stellarstellaris-$version-windows-x64.zip" "stellarstellaris-$version-windows-x64"
	tar -czf "$out/stellar-render-$version-linux-x64.tar.gz" --owner=0 --group=0 "stellar-render-$version-linux-x64"
	zip -qrX "$out/stellar-render-$version-windows-x64.zip" "stellar-render-$version-windows-x64"
	cd "$out"
	sha256sum stellarstellaris-*.zip stellar-render-*.tar.gz stellar-render-*.zip > SHA256SUMS
	cat SHA256SUMS
	;;
*)
	sed -n '2,13p' "$0"
	exit 2
	;;
esac
