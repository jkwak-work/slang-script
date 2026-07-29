#!/bin/bash

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
start_seconds=$SECONDS

log()
{
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

usage()
{
    echo "Usage: $0 [debug|release] [--cuda VERSION]" >&2
}

detect_platform()
{
    local kernel
    kernel=$(uname -s)

    case "$kernel" in
        Linux)
            if [ -n "${WSL_INTEROP:-}" ] ||
               grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
                echo wsl
            else
                echo linux
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo windows
            ;;
        *)
            echo "Error: unsupported platform: $kernel" >&2
            exit 1
            ;;
    esac
}

to_windows_path()
{
    if [ "$platform" = wsl ] && command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$1"
    elif [ "$platform" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        echo "Error: the platform path-conversion tool is unavailable." >&2
        return 1
    fi
}

add_cuda_installation()
{
    local version=${1#v}
    local path=$2
    local index

    [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return
    [ -d "$path" ] || return

    for index in "${!cuda_versions[@]}"; do
        [ "${cuda_versions[index]}" = "$version" ] && return
    done

    cuda_versions+=("$version")
    cuda_paths+=("$path")
}

cuda_version_from_nvcc()
{
    "$1" --version 2>/dev/null |
        sed -n 's/.*release \([0-9][0-9.]*\).*/\1/p' |
        head -n 1
}

discover_windows_cuda()
{
    local cuda_root cuda_dir

    if [ "$platform" = wsl ]; then
        cuda_root='/mnt/c/Program Files/NVIDIA GPU Computing Toolkit/CUDA'
    else
        cuda_root=$(cygpath -u "${ProgramFiles:-C:\\Program Files}") ||
            return 1
        cuda_root="$cuda_root/NVIDIA GPU Computing Toolkit/CUDA"
    fi

    [ -d "$cuda_root" ] || return
    while IFS= read -r -d '' cuda_dir; do
        add_cuda_installation "${cuda_dir##*/v}" "$cuda_dir"
    done < <(find "$cuda_root" -mindepth 1 -maxdepth 1 -type d -name 'v*' -print0)
}

discover_linux_cuda()
{
    local cuda_dir resolved version nvcc_path

    for cuda_dir in /usr/local/cuda-* /opt/cuda-*; do
        [ -d "$cuda_dir" ] || continue
        add_cuda_installation "${cuda_dir##*cuda-}" "$cuda_dir"
    done

    for cuda_dir in /usr/local/cuda /opt/cuda; do
        [ -d "$cuda_dir" ] || continue
        resolved=$(readlink -f "$cuda_dir")
        version=${resolved##*cuda-}
        if [ "$version" = "$resolved" ] || ! [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
            version=$(cuda_version_from_nvcc "$cuda_dir/bin/nvcc")
        fi
        add_cuda_installation "$version" "$resolved"
    done

    if command -v nvcc >/dev/null 2>&1; then
        nvcc_path=$(command -v nvcc)
        resolved=$(CDPATH= cd -- "$(dirname -- "$nvcc_path")/.." 2>/dev/null && pwd -P)
        version=$(cuda_version_from_nvcc "$nvcc_path")
        add_cuda_installation "$version" "$resolved"
    fi
}

sort_cuda_installations()
{
    local index
    local sorted_versions=()
    local sorted_paths=()

    [ "${#cuda_versions[@]}" -gt 0 ] || return
    while IFS='|' read -r version path; do
        sorted_versions+=("$version")
        sorted_paths+=("$path")
    done < <(
        for index in "${!cuda_versions[@]}"; do
            printf '%s|%s\n' "${cuda_versions[index]}" "${cuda_paths[index]}"
        done | sort -t '|' -k1,1V
    )
    cuda_versions=("${sorted_versions[@]}")
    cuda_paths=("${sorted_paths[@]}")
}

build_config=Debug
build_config_set=false
requested_cuda_version=

while [ "$#" -gt 0 ]; do
    case "$1" in
        debug|Debug)
            if [ "$build_config_set" = true ]; then
                usage
                exit 2
            fi
            build_config=Debug
            build_config_set=true
            ;;
        release|Release)
            if [ "$build_config_set" = true ]; then
                usage
                exit 2
            fi
            build_config=Release
            build_config_set=true
            ;;
        --cuda|--cuda-version)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "Error: $1 requires a CUDA version." >&2
                usage
                exit 2
            fi
            requested_cuda_version=${2#v}
            shift
            ;;
        --cuda=*|--cuda-version=*)
            requested_cuda_version=${1#*=}
            requested_cuda_version=${requested_cuda_version#v}
            if [ -z "$requested_cuda_version" ]; then
                echo "Error: ${1%%=*} requires a CUDA version." >&2
                usage
                exit 2
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
    shift
done

if [ -n "$requested_cuda_version" ] &&
   ! [[ "$requested_cuda_version" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo "Error: invalid CUDA version: $requested_cuda_version" >&2
    exit 2
fi

platform=$(detect_platform)
cuda_versions=()
cuda_paths=()
case "$platform" in
    windows|wsl) discover_windows_cuda ;;
    linux) discover_linux_cuda ;;
esac
sort_cuda_installations

selected_cuda_version=
selected_cuda_path=
if [ -n "$requested_cuda_version" ]; then
    for index in "${!cuda_versions[@]}"; do
        if [ "${cuda_versions[index]}" = "$requested_cuda_version" ]; then
            selected_cuda_version=${cuda_versions[index]}
            selected_cuda_path=${cuda_paths[index]}
            break
        fi
    done
    if [ -z "$selected_cuda_path" ]; then
        echo "Error: CUDA $requested_cuda_version is not installed." >&2
        if [ "${#cuda_versions[@]}" -gt 0 ]; then
            echo "Installed CUDA versions: ${cuda_versions[*]}" >&2
        fi
        exit 1
    fi
elif [ "${#cuda_versions[@]}" -eq 0 ]; then
    echo "Warning: no CUDA installation was found." >&2
else
    last_index=$((${#cuda_versions[@]} - 1))
    selected_cuda_version=${cuda_versions[last_index]}
    selected_cuda_path=${cuda_paths[last_index]}
    if [ "${#cuda_versions[@]}" -gt 1 ]; then
        echo "Warning: multiple CUDA versions are installed: ${cuda_versions[*]}." >&2
        echo "Warning: using the highest version, CUDA $selected_cuda_version." >&2
    fi
fi

log "Platform: $platform"
log "Build config: $build_config"
if [ -n "$selected_cuda_version" ]; then
    log "CUDA version: $selected_cuda_version ($selected_cuda_path)"
fi

if [ "$platform" = linux ]; then
    if [ -n "$selected_cuda_path" ]; then
        export CUDA_PATH="$selected_cuda_path"
        export CUDAToolkit_ROOT="$selected_cuda_path"
        export PATH="$selected_cuda_path/bin:$PATH"
        if [ -d "$selected_cuda_path/lib64" ]; then
            export LD_LIBRARY_PATH="$selected_cuda_path/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        fi
    fi

    if ! command -v cmake >/dev/null 2>&1; then
        echo "Error: cmake was not found in PATH." >&2
        exit 1
    fi
    if ! command -v sccache >/dev/null 2>&1; then
        echo "Error: sccache was not found in PATH." >&2
        exit 1
    fi
    export SCCACHE_DIR=${SCCACHE_DIR:-"${XDG_CACHE_HOME:-$HOME/.cache}/sccache"}
    export SLANG_USE_SCCACHE=1
    mkdir -p "$SCCACHE_DIR" || exit 1

    cmake --preset default --log-level=ERROR \
        -DCMAKE_COMPILE_WARNING_AS_ERROR=ON \
        -DSLANG_IGNORE_ABORT_MSG=ON
    build_status=$?
    if [ "$build_status" -eq 0 ]; then
        cmake --build build --config "$build_config"
        build_status=$?
    fi
else
    cmd_script=$(to_windows_path "$script_dir/build-slang.sh.cmd") || exit 1
    cuda_path_windows=
    if [ -n "$selected_cuda_path" ]; then
        cuda_path_windows=$(to_windows_path "$selected_cuda_path") || exit 1
    fi
    if [ "$platform" = wsl ]; then
        cache_dir_windows=${SCCACHE_DIR_WINDOWS:-'E:\sbf\slang-cache'}
    else
        cache_dir_windows=${SCCACHE_DIR_WINDOWS:-}
    fi

    cmd.exe /d /c "$cmd_script" \
        "$build_config" "$cache_dir_windows" "$cuda_path_windows"
    build_status=$?
fi

elapsed_seconds=$((SECONDS - start_seconds))
printf 'Build took: %02d:%02d:%02d\n' \
    $((elapsed_seconds / 3600)) \
    $(((elapsed_seconds % 3600) / 60)) \
    $((elapsed_seconds % 60))

exit "$build_status"
