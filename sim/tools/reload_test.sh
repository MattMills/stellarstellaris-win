#!/bin/sh
# tools/reload_test.sh RUN GAME_DIR SAVE : engine.reload end to end (tools/reload_test.lua). A test
# mod is made in a temporary folder, enabled through STELLAR_MODS_DIR, and rewritten during the run;
# prints the checks, exits 1 when one fails. RUN is the `run` example (cargo build --release
# --example run), run from sim/.
#
#   sh tools/reload_test.sh target/release/examples/run /opt/stellaris save.sav
set -u
RUN=$1; GAME=$2; SAVE=$3
T=$(mktemp -d "${TMPDIR:-/tmp}/stellar-reload-test.XXXXXX") || exit 1
D="${T:?}/docs"
M="${T:?}/mod"
mkdir -p "$D/mod" "$M/common/technology" "$M/common/scripted_triggers" "$M/common/script_values" \
    "$M/common/inline_scripts/zz" "$M/common/buildings" "$M/events" "$M/localisation/english" \
    "$M/common/scripted_variables"
printf '{"enabled_mods":["mod/r.mod"]}\n' > "$D/dlc_load.json"
printf 'name="reload test"\npath="%s"\n' "$M" > "$D/mod/r.mod"
printf 'tech_reload_a = { area = physics tier = 1 cost = 10 }\ntech_reload_b = { area = physics tier = 1 cost = 15 }\n' > "$M/common/technology/zz_reload.txt"
printf 'reload_st = { always = yes }\n' > "$M/common/scripted_triggers/zz_reload.txt"
printf 'reload_sv = { base = 5 }\n' > "$M/common/script_values/zz_reload.txt"
printf 'reload_inline_field = one\n' > "$M/common/inline_scripts/zz/reload_inline.txt"
printf 'building_reload = { inline_script = "zz/reload_inline" }\n' > "$M/common/buildings/zz_reload.txt"
printf 'namespace = reload_test\ncountry_event = { id = reload_test.1 is_triggered_only = yes }\n' > "$M/events/zz_reload.txt"
printf '\357\273\277l_english:\n RELOAD_KEY:0 "one"\n' > "$M/localisation/english/zz_reload_l_english.yml"
printf '@reload_var = 1\n' > "$M/common/scripted_variables/zz_reload.txt"
RELOAD_MOD=$M STELLAR_MODS_DIR=$D STELLARIS_DIR=$GAME STELLAR_LUA=tools/reload_test.lua \
    "$RUN" 0 "$SAVE" > "$T/out.txt" 2>&1
sed -n '/^RELOADTEST/,$p' "$T/out.txt"
grep -E "panicked|stack traceback" -A4 "$T/out.txt"
status=1
grep -q "^RELOADTEST all passed" "$T/out.txt" && status=0
rm -rf -- "${T:?}"
exit $status
