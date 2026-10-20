#!/usr/bin/env bash
# release-upload.sh TAG FILE... : attaches the files to the GitHub release of TAG, replacing an
# asset of the same name (.github/workflows/build.yml's bundle job; docs/ci.md). Needs GH_TOKEN
# (contents: write) and GITHUB_REPOSITORY; uses gh when the runner has it, else the REST API with
# curl and python3.
set -euo pipefail
tag=$1
shift
[ $# -gt 0 ] || { echo "release-upload: no files" >&2; exit 1; }
: "${GH_TOKEN:?}" "${GITHUB_REPOSITORY:?}"

if command -v gh >/dev/null 2>&1; then
	gh release upload "$tag" "$@" --clobber --repo "$GITHUB_REPOSITORY"
	exit 0
fi

api="https://api.github.com/repos/$GITHUB_REPOSITORY"
auth=(-H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
release=$(curl -fsS "${auth[@]}" "$api/releases/tags/$tag")
id=$(printf '%s' "$release" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
for f in "$@"; do
	name=$(basename "$f")
	# an asset of the same name first removed (gh's --clobber)
	old=$(printf '%s' "$release" | python3 -c 'import json,sys; n=sys.argv[1]; print(" ".join(str(a["id"]) for a in json.load(sys.stdin)["assets"] if a["name"] == n))' "$name")
	for a in $old; do
		curl -fsS -X DELETE "${auth[@]}" "$api/releases/assets/$a"
	done
	curl -fsS -X POST "${auth[@]}" -H "Content-Type: application/octet-stream" --data-binary "@$f" \
		"https://uploads.github.com/repos/$GITHUB_REPOSITORY/releases/$id/assets?name=$name" >/dev/null
	echo "uploaded $name to $tag"
done
