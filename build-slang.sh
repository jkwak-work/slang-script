#!/bin/bash

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cmd_script=$(wslpath -w "$script_dir/build-slang.sh.cmd")
cache_dir_windows='E:\sbf\slang-cache'

case "${1:-debug}" in
    debug|Debug)
        build_config=Debug
        ;;
    release|Release)
        build_config=Release
        ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [debug|release]" >&2
    exit 2
fi

start_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
start_seconds=$SECONDS

echo "[$(date)] Build config: $build_config"
cmd.exe /d /c "$cmd_script" "$build_config" "$cache_dir_windows"
build_status=$?

elapsed_seconds=$((SECONDS - start_seconds))
printf 'Build took: %02d:%02d:%02d\n' \
    $((elapsed_seconds / 3600)) \
    $(((elapsed_seconds % 3600) / 60)) \
    $((elapsed_seconds % 60))

exit "$build_status"
