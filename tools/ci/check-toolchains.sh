#!/bin/bash
# check-toolchains.sh msvc|gnullvm : fails early, saying what is missing, when the runner image has
# not the cross toolchains a job uses (runner-hive's contrib/Dockerfile.windows-cross; docs/ci.md).
# Nothing is downloaded.
set -euo pipefail
missing=()
need() { [ -e "$1" ] || missing+=("$1"); }
case "${1:-}" in
msvc)
	for tool in clang-cl lld-link llvm-lib llvm-rc; do need "/opt/llvm-mingw/bin/$tool"; done
	need /opt/xwin/crt/include/vcruntime.h
	need /opt/xwin/sdk/lib/um/x86_64/kernel32.lib
	command -v ninja >/dev/null || missing+=(ninja)
	target=x86_64-pc-windows-msvc
	;;
gnullvm)
	need /opt/llvm-mingw/bin/x86_64-w64-mingw32-clang
	target=x86_64-pc-windows-gnullvm
	;;
*)
	echo "usage: $0 msvc|gnullvm" >&2
	exit 2
	;;
esac
rustup target list --installed | grep -qx "$target" || missing+=("the Rust target $target")
if [ ${#missing[@]} -gt 0 ]; then
	echo "::error::The runner image lacks: ${missing[*]}. See docs/ci.md (runner image)."
	exit 1
fi
echo "toolchains for $1: present ($(/opt/llvm-mingw/bin/clang --version | head -1), rustc $(rustc --version | cut -d' ' -f2))"
