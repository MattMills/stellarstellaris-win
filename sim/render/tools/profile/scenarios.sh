#!/bin/bash
# scenarios.sh OUT_DIR [SAVE]: writes the profiling scenarios (docs/profiling.md) as command files
# for `stellar-render --script` into OUT_DIR: menu.txt, map.txt (the map and each heavy window,
# paused: still, hovered, wheeled, dragged) and running.txt (the same windows with the clock at
# Normal). `{OUT}` in them is the run's folder (run.sh fills it in).
set -eu
O=${1:?OUT_DIR}
SAVE=${2:-/opt/stellaris-saves/autosave_2210.01.01.sav}
mkdir -p "$O"

# the windows: NAME|OPEN|CLOSE (the 2210.01.01 save: planet 0 the capital, fleet 1, starbase 0)
WINDOWS="map||
planet|open_planet 0|open_planet close
fleet|open fleet 1|select none
outliner_fleet_selected|select fleet 1|select none
designer|open_designer|open_designer close
technology|open_view technology|open_view technology
market|open_view market|open_view market
diplomacy|open_diplomacy contacts|open_diplomacy close
empire|open_view empire|open_view empire
fleet_manager|open fleet_manager|select none
starbase|open_starbase 0|select none"

# the input of each measurement: NAME:ARGS of `bench SECONDS [hover|wheel|drag ...]` at 1280x720
INPUTS="static:
hover:hover 100 150 1000 600
wheel:wheel 640 400
drag:drag 300 300 700 450"

cat > "$O/menu.txt" <<EOF
resize 1280 720
bench 1
bench 5
prof report {OUT}/menu_static.prof
bench 5 hover 100 100 1100 650
prof report {OUT}/menu_hover.prof
quit
EOF

start() {
    echo "load-sim $SAVE"
    echo "resize 1280 720"
    echo "view galaxy"
}

{
    start
    echo "pause"
    echo "bench 2"
    while IFS='|' read -r n open close; do
        [ -n "$open" ] && echo "$open"
        # (the opening's frame apart: its layout and textures)
        echo "bench 1"
        while IFS=: read -r i args; do
            echo "bench 5 $args"
            echo "prof report {OUT}/${n}_$i.prof"
        done <<< "$INPUTS"
        [ -n "$close" ] && echo "$close"
        echo "bench 1"
    done <<< "$WINDOWS"
    echo "quit"
} > "$O/map.txt"

{
    start
    echo "pause off"
    echo "speed 3"
    echo "bench 3"
    while IFS='|' read -r n open close; do
        [ -n "$open" ] && echo "$open"
        echo "bench 1"
        echo "bench 8"
        echo "prof report {OUT}/running_$n.prof"
        echo "bench 5 hover 100 150 1000 600"
        echo "prof report {OUT}/running_${n}_hover.prof"
        [ -n "$close" ] && echo "$close"
        echo "bench 1"
    done <<< "$WINDOWS"
    echo "quit"
} > "$O/running.txt"
echo "wrote $O/menu.txt $O/map.txt $O/running.txt"
