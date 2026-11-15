#!/bin/sh
# Run the offline tests under Lua 5.1 (the game's LuaJIT is 5.1).
#
#   tests/logic_test.lua     pure logic: signature keys, modes, link resolution,
#                            diff/preview, link normalisation
#   tests/pipeline_test.lua  the apply pipeline and trigger state machine
#                            against a fake REFramework save
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

status=0
for test_file in tests/logic_test.lua tests/pipeline_test.lua; do
    echo "== $test_file"
    "$LUA_BIN" "$test_file" || status=1
done
exit "$status"
