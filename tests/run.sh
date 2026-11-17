#!/bin/sh
# Run the offline tests under Lua 5.1 (the game's LuaJIT is 5.1).
#
#   tests/logic_test.lua     pure logic: signature keys, modes, link resolution,
#                            diff/preview, link normalisation
#   tests/pipeline_test.lua  the apply pipeline and trigger state machine
#                            against a fake REFramework save
#   tests/gear_test.lua      build capture from the live catalogue and the
#                            client's weapon-swap scenario, end to end
#
# LUA=/path/to/lua ./tests/run.sh
set -e
cd "$(dirname "$0")/.."

LUA_BIN="${LUA:-}"
if [ -z "$LUA_BIN" ]; then
    for candidate in lua5.1 luajit lua; do
        if command -v "$candidate" >/dev/null 2>&1; then
            LUA_BIN="$candidate"
            break
        fi
    done
fi
if [ -z "$LUA_BIN" ]; then
    echo "no Lua 5.1 interpreter found; set LUA=/path/to/lua5.1" >&2
    exit 2
fi

# A misplaced `local` turns a table into a nil global and every test still
# passes, because the fake world sets it. Catch that here: compile the mod and
# reject any global that is not one of REFramework's own.
LUAC_BIN="${LUAC:-}"
if [ -z "$LUAC_BIN" ] && [ -x "$(dirname "$LUA_BIN")/luac" ]; then
    LUAC_BIN="$(dirname "$LUA_BIN")/luac"
fi
if [ -n "$LUAC_BIN" ]; then
    "$LUAC_BIN" -p reframework/linked_restock.lua || exit 1
    EXPECTED_GLOBALS="_G draw imgui io ipairs json log math os pairs pcall re sdk string table tonumber tostring type unpack"
    seen=$("$LUAC_BIN" -l -p reframework/linked_restock.lua \
        | sed -n 's/.*GETGLOBAL.*; //p; s/.*GETGLOBAL.*- *[0-9][0-9]* *; //p' \
        | sort -u | tr '\n' ' ')
    extra=""
    for g in $seen; do
        case " $EXPECTED_GLOBALS " in
            *" $g "*) ;;
            *) extra="$extra $g" ;;
        esac
    done
    if [ -n "$extra" ]; then
        echo "unexpected globals in the mod:$extra" >&2
        exit 1
    fi
else
    echo "note: no luac next to $LUA_BIN, skipping the globals check" >&2
fi

status=0
for test_file in tests/logic_test.lua tests/pipeline_test.lua tests/gear_test.lua; do
    echo "== $test_file"
    "$LUA_BIN" "$test_file" || status=1
done
exit "$status"
