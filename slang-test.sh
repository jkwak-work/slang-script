#!/bin/bash

start_seconds=$SECONDS
verbose=false
build_config=
validation=true

log()
{
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

add_to_wslenv()
{
	local entry
	local variable="$1"
	local variable_name="${variable%%/*}"
	local wslenv_entries=()
	local index

	IFS=: read -r -a wslenv_entries <<< "${WSLENV:-}"
	for index in "${!wslenv_entries[@]}"
	do
		entry=${wslenv_entries[index]}
		if [ "${entry%%/*}" = "$variable_name" ]
		then
			if [[ "$variable" == */* ]] && [ "$entry" != "$variable" ]
			then
				wslenv_entries[index]="$variable"
				WSLENV=$(IFS=:; echo "${wslenv_entries[*]}")
			fi
			return
		fi
	done

	WSLENV=${WSLENV%:}
	WSLENV="${WSLENV:+$WSLENV:}$variable"
}

prepend_path_entries()
{
	[ "$#" -gt 0 ] || return
	local prefix
	prefix=$(IFS=:; printf '%s' "$*")
	export PATH="$prefix${PATH:+:$PATH}"
	if [ "$platform" = wsl ]
	then
		add_to_wslenv PATH/lp
	fi
}

log_elapsed_time()
{
	local status=$?
	local elapsed_seconds=$((SECONDS - start_seconds))
	local elapsed_time

	trap - EXIT
	printf -v elapsed_time '%02d:%02d:%02d' \
		$((elapsed_seconds / 3600)) \
		$(((elapsed_seconds % 3600) / 60)) \
		$((elapsed_seconds % 60))
	log "Elapsed time: $elapsed_time"
	exit "$status"
}

trap log_elapsed_time EXIT

usage()
{
	log "Usage: $0 [--debug | --release] [--cuda VERSION] [--server-count X] [--skip-list FILE] [--validation {true | false}] [--verbose] [--] [slang-test arguments...]" >&2
}

detect_platform()
{
	local kernel
	kernel=$(uname -s)

	case "$kernel" in
		Linux)
			if [ -n "${WSL_INTEROP:-}" ] ||
				grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null
			then
				echo wsl
			else
				echo linux
			fi
			;;
		MINGW*|MSYS*|CYGWIN*)
			echo windows
			;;
		*)
			log "Unsupported platform: $kernel" >&2
			exit 1
			;;
	esac
}

add_skip_list()
{
	local path=$1
	local reason=$2

	if [ ! -f "$path" ]
	then
		log "Warning: skip list not found, ignoring: $path" >&2
		return
	fi
	log "Skip list: $path ($reason)"
	skip_lists+=("$path")
}

add_cuda_installation()
{
	local version=${1#v}
	local path=$2
	local index

	[[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return
	[ -d "$path" ] || return

	for index in "${!cuda_versions[@]}"
	do
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

	cuda_root=$(sdk_unix_path "${ProgramFiles:-C:\\Program Files}") || return 1
	cuda_root="$cuda_root/NVIDIA GPU Computing Toolkit/CUDA"

	[ -d "$cuda_root" ] || return
	while IFS= read -r -d '' cuda_dir
	do
		add_cuda_installation "${cuda_dir##*/v}" "$cuda_dir"
	done < <(find "$cuda_root" -mindepth 1 -maxdepth 1 -type d -name 'v*' -print0)
}

discover_linux_cuda()
{
	local cuda_dir resolved version nvcc_path

	for cuda_dir in /usr/local/cuda-* /opt/cuda-*
	do
		[ -d "$cuda_dir" ] || continue
		add_cuda_installation "${cuda_dir##*cuda-}" "$cuda_dir"
	done

	for cuda_dir in /usr/local/cuda /opt/cuda
	do
		[ -d "$cuda_dir" ] || continue
		resolved=$(readlink -f "$cuda_dir")
		version=${resolved##*cuda-}
		if [ "$version" = "$resolved" ] ||
			! [[ "$version" =~ ^[0-9]+([.][0-9]+)*$ ]]
		then
			version=$(cuda_version_from_nvcc "$cuda_dir/bin/nvcc")
		fi
		add_cuda_installation "$version" "$resolved"
	done

	if command -v nvcc >/dev/null 2>&1
	then
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
	while IFS='|' read -r version path
	do
		sorted_versions+=("$version")
		sorted_paths+=("$path")
	done < <(
		for index in "${!cuda_versions[@]}"
		do
			printf '%s|%s\n' "${cuda_versions[index]}" "${cuda_paths[index]}"
		done | sort -t '|' -k1,1V
	)
	cuda_versions=("${sorted_versions[@]}")
	cuda_paths=("${sorted_paths[@]}")
}

select_cuda()
{
	local index last_index

	sort_cuda_installations
	selected_cuda_version=
	selected_cuda_path=
	if [ -n "$requested_cuda_version" ]
	then
		for index in "${!cuda_versions[@]}"
		do
			if [ "${cuda_versions[index]}" = "$requested_cuda_version" ]
			then
				selected_cuda_version=${cuda_versions[index]}
				selected_cuda_path=${cuda_paths[index]}
				break
			fi
		done
		if [ -z "$selected_cuda_path" ]
		then
			log "CUDA $requested_cuda_version is not installed." >&2
			if [ "${#cuda_versions[@]}" -gt 0 ]
			then
				log "Installed CUDA versions: ${cuda_versions[*]}" >&2
			fi
			exit 1
		fi
	elif [ "${#cuda_versions[@]}" -eq 0 ]
	then
		log "Warning: no CUDA installation was found." >&2
	else
		last_index=$((${#cuda_versions[@]} - 1))
		selected_cuda_version=${cuda_versions[last_index]}
		selected_cuda_path=${cuda_paths[last_index]}
		if [ "${#cuda_versions[@]}" -gt 1 ]
		then
			log "Warning: multiple CUDA versions are installed: ${cuda_versions[*]}." >&2
			log "Warning: using the highest version, CUDA $selected_cuda_version." >&2
		fi
	fi
}

configure_cuda_search_paths()
{
	local cuda_path_entries=()

	[ -n "$selected_cuda_path" ] || return

	if [ "$platform" = linux ]
	then
		cuda_path_entries+=("$selected_cuda_path/bin")
		if [ -d "$selected_cuda_path/lib64" ]
		then
			export LD_LIBRARY_PATH="$selected_cuda_path/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
		fi
	else
		[ -d "$selected_cuda_path/bin/x64" ] &&
			cuda_path_entries+=("$selected_cuda_path/bin/x64")
		[ -d "$selected_cuda_path/bin" ] &&
			cuda_path_entries+=("$selected_cuda_path/bin")
		[ -d "$selected_cuda_path/libnvvp" ] &&
			cuda_path_entries+=("$selected_cuda_path/libnvvp")
	fi

	prepend_path_entries "${cuda_path_entries[@]}"
}

sdk_unix_path()
{
	case "$1" in
		[A-Za-z]:\\*|[A-Za-z]:/*)
			case "$platform" in
				wsl) wslpath -u "$1" ;;
				windows) cygpath -u "$1" ;;
				*) return 1 ;;
			esac
			;;
		*) printf '%s\n' "$1" ;;
	esac
}

windows_env_value()
{
	local value

	# WSL only sees Windows variables that are listed in WSLENV, so ask cmd.exe.
	# Run it from a Windows drive to avoid the UNC working directory warning.
	value=$(cd /mnt/c 2>/dev/null; cmd.exe /d /c "echo %$1%" 2>/dev/null) || return 1
	value=${value%$'\r'}
	[ -n "$value" ] && [ "$value" != "%$1%" ] || return 1
	printf '%s\n' "$value"
}

vulkan_sdk_root()
{
	local path
	path=$(sdk_unix_path "$1") || return 1
	if [ "$platform" = linux ]
	then
		[ -f "$path/lib/$vulkan_sdk_marker" ] ||
			[ -f "$path/lib64/$vulkan_sdk_marker" ] || return 1
	else
		[ -f "$path/Bin/$vulkan_sdk_marker" ] ||
			[ -f "$path/bin/$vulkan_sdk_marker" ] || return 1
	fi
	(CDPATH= cd -- "$path" && pwd -P)
}

discover_vulkan_sdk()
{
	local variable value source entry root search_path path_source
	local path_entries=()

	# Prefer an explicit SDK setting, then the SDK already on PATH, then the
	# layer registered with the Windows Vulkan loader.
	for variable in VULKAN_SDK VK_SDK_PATH
	do
		value=${!variable:-}
		source=$variable
		if [ -z "$value" ] && [ "$platform" = wsl ]
		then
			value=$(windows_env_value "$variable") || continue
			source="Windows $variable"
		fi
		[ -n "$value" ] || continue
		root=$(vulkan_sdk_root "$value") || {
			log "Warning: $source does not point to a Vulkan SDK: $value" >&2
			continue
		}
		vulkan_paths+=("$root")
		vulkan_sources+=("$source")
	done

	if [ "$platform" = linux ]
	then
		search_path=${LD_LIBRARY_PATH:-}
		path_source=LD_LIBRARY_PATH
	else
		search_path=$PATH
		path_source=PATH
	fi
	IFS=: read -r -a path_entries <<< "$search_path"
	for entry in "${path_entries[@]}"
	do
		[ -f "$entry/$vulkan_sdk_marker" ] || continue
		root=$(vulkan_sdk_root "$(dirname -- "$entry")") || continue
		vulkan_paths+=("$root")
		vulkan_sources+=("$path_source")
	done

	[ "$platform" = linux ] && return
	while IFS= read -r entry
	do
		entry=${entry%$'\r'}
		entry=$(printf '%s\n' "$entry" |
			sed -n 's/^ *\(.*\\VkLayer_khronos_validation\.json\) .*/\1/p')
		[ -n "$entry" ] || continue
		entry=$(sdk_unix_path "$entry") || continue
		root=$(vulkan_sdk_root "$(dirname -- "$(dirname -- "$entry")")") || continue
		vulkan_paths+=("$root")
		vulkan_sources+=(registry)
	done < <(MSYS2_ARG_CONV_EXCL='*' reg.exe query \
		'HKLM\SOFTWARE\Khronos\Vulkan\ExplicitLayers' 2>/dev/null)
}

select_vulkan_sdk()
{
	local index version_dir

	selected_vulkan_version=
	selected_vulkan_path=

	if [ "${#vulkan_paths[@]}" -eq 0 ]
	then
		return
	fi
	selected_vulkan_path=${vulkan_paths[0]}
	for index in "${!vulkan_paths[@]}"
	do
		if [ "${vulkan_sources[index]}" != PATH ] &&
			[ "${vulkan_sources[index]}" != LD_LIBRARY_PATH ] &&
			[ "${vulkan_sources[index]}" != registry ] &&
			[ "${vulkan_paths[index]}" != "$selected_vulkan_path" ]
		then
			log "Warning: ${vulkan_sources[index]} points to ${vulkan_paths[index]}; using $selected_vulkan_path." >&2
		fi
	done

	version_dir=${selected_vulkan_path##*/}
	if ! [[ "$version_dir" =~ ^[0-9]+([.][0-9]+)*$ ]]
	then
		version_dir=${selected_vulkan_path%/*}
		version_dir=${version_dir##*/}
	fi
	if [[ "$version_dir" =~ ^[0-9]+([.][0-9]+)*$ ]]
	then
		selected_vulkan_version=$version_dir
	else
		selected_vulkan_version=unknown
	fi
}

configure_vulkan_search_paths()
{
	local entry sdk_dir sdk_value layer_dir search_path
	local path_entries=() kept_entries=()

	[ -n "$selected_vulkan_path" ] || return

	if [ "$platform" = linux ]
	then
		if [ -f "$selected_vulkan_path/lib/$vulkan_sdk_marker" ]
		then
			sdk_dir="$selected_vulkan_path/lib"
		else
			sdk_dir="$selected_vulkan_path/lib64"
		fi
		layer_dir="$selected_vulkan_path/share/vulkan/explicit_layer.d"
		search_path=${LD_LIBRARY_PATH:-}
	else
		if [ -f "$selected_vulkan_path/Bin/$vulkan_sdk_marker" ]
		then
			sdk_dir="$selected_vulkan_path/Bin"
		else
			sdk_dir="$selected_vulkan_path/bin"
		fi
		layer_dir=$sdk_dir
		search_path=$PATH
	fi
	IFS=: read -r -a path_entries <<< "$search_path"
	for entry in "${path_entries[@]}"
	do
		[ -f "$entry/$vulkan_sdk_marker" ] || kept_entries+=("$entry")
	done
	search_path=$(IFS=:; printf '%s' "${kept_entries[*]}")
	if [ "$platform" = linux ]
	then
		export LD_LIBRARY_PATH="$sdk_dir${search_path:+:$search_path}"
	else
		PATH=$search_path
		prepend_path_entries "$sdk_dir"
	fi

	# The Vulkan loader finds layers through the registry or layer paths, not
	# PATH, so point it at the selected SDK's validation layer manifest.
	[ -d "$layer_dir" ] || layer_dir=

	case "$platform" in
		wsl)
			sdk_value=$selected_vulkan_path
			add_to_wslenv VK_SDK_PATH/p
			add_to_wslenv VULKAN_SDK/p
			add_to_wslenv VK_ADD_LAYER_PATH/p
			;;
		windows)
			sdk_value=$(cygpath -w "$selected_vulkan_path") || return 1
			if [ -n "$layer_dir" ]
			then
				layer_dir=$(cygpath -w "$layer_dir") || return 1
			fi
			;;
		*) sdk_value=$selected_vulkan_path ;;
	esac
	export VK_SDK_PATH="$sdk_value" VULKAN_SDK="$sdk_value"
	if [ -n "$layer_dir" ]
	then
		export VK_ADD_LAYER_PATH="$layer_dir"
	fi
}

server_count=8
requested_cuda_version=
requested_skip_lists=()
slangtest_args=()
while [ "$#" -gt 0 ]
do
	case "$1" in
		--debug)
			if [ -n "$build_config" ] && [ "$build_config" != Debug ]
			then
				log "Cannot specify both --debug and --release." >&2
				usage
				exit 2
			fi
			build_config=Debug
			;;
		--release)
			if [ -n "$build_config" ] && [ "$build_config" != Release ]
			then
				log "Cannot specify both --debug and --release." >&2
				usage
				exit 2
			fi
			build_config=Release
			;;
		--verbose)
			verbose=true
			;;
		--cuda|--cuda-version)
			if [ "$#" -lt 2 ] || [ -z "$2" ]
			then
				log "$1 requires a CUDA version." >&2
				usage
				exit 2
			fi
			requested_cuda_version=${2#v}
			shift
			;;
		--cuda=*|--cuda-version=*)
			requested_cuda_version=${1#*=}
			requested_cuda_version=${requested_cuda_version#v}
			if [ -z "$requested_cuda_version" ]
			then
				log "${1%%=*} requires a CUDA version." >&2
				usage
				exit 2
			fi
			;;
		--server-count)
			if [ "$#" -lt 2 ] || [[ ! "$2" =~ ^[0-9]+$ ]]
			then
				log "--server-count requires a non-negative integer." >&2
				usage
				exit 2
			fi
			server_count="$2"
			shift
			;;
		--skip-list)
			if [ "$#" -lt 2 ] || [ -z "$2" ]
			then
				log "--skip-list requires a file path." >&2
				usage
				exit 2
			fi
			if [ ! -f "$2" ]
			then
				log "Skip list not found: $2" >&2
				exit 2
			fi
			requested_skip_lists+=("$2")
			shift
			;;
		--validation)
			if [ "$#" -lt 2 ] || { [ "$2" != true ] && [ "$2" != false ]; }
			then
				log "--validation requires either 'true' or 'false'." >&2
				usage
				exit 2
			fi
			validation="$2"
			shift
			;;
		--)
			shift
			slangtest_args+=("$@")
			break
			;;
		*)
			slangtest_args+=("$1")
			;;
	esac
	shift
done

if [ -n "$requested_cuda_version" ] &&
	! [[ "$requested_cuda_version" =~ ^[0-9]+([.][0-9]+)*$ ]]
then
	log "Invalid CUDA version: $requested_cuda_version" >&2
	exit 2
fi

platform=$(detect_platform)
cuda_versions=()
cuda_paths=()
vulkan_paths=()
vulkan_sources=()
case "$platform" in
	windows|wsl)
		discover_windows_cuda
		vulkan_sdk_marker=VkLayer_khronos_validation.dll
		;;
	linux)
		discover_linux_cuda
		vulkan_sdk_marker=libVkLayer_khronos_validation.so
		;;
esac
select_cuda
configure_cuda_search_paths

log "Platform: $platform"
if [ -n "$selected_cuda_version" ]
then
	log "CUDA version: $selected_cuda_version ($selected_cuda_path)"
fi

if [ "$validation" = true ]
then
	discover_vulkan_sdk
	select_vulkan_sdk
	if [ -z "$selected_vulkan_path" ]
	then
		log "Error: Vulkan validation requires an SDK with $vulkan_sdk_marker, but none was found." >&2
		exit 1
	fi
	configure_vulkan_search_paths
	log "Vulkan version: $selected_vulkan_version ($selected_vulkan_path)"

	export SLANG_RUN_SPIRV_VALIDATION=1
	export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
	log "SPIRV and Vulkan validation enabled."
else
	export SLANG_RUN_SPIRV_VALIDATION=0
	export VK_INSTANCE_LAYERS=
	log "SPIRV and Vulkan validation disabled."
fi

add_to_wslenv SLANG_RUN_SPIRV_VALIDATION
add_to_wslenv VK_INSTANCE_LAYERS
export WSLENV

positional_argument_count=0
run_all=false
for arg in "${slangtest_args[@]}"
do
	if [ -n "$arg" ] && [[ "$arg" != -* ]]
	then
		positional_argument_count=$((positional_argument_count + 1))
		[ "$arg" = all ] && run_all=true
	fi
done

if [ "$positional_argument_count" -eq 0 ]
then
	log "At least one positional argument is required. Specify 'all' to run the full test suite." >&2
	exit 2
fi

if $run_all
then
	if [ "$positional_argument_count" -ne 1 ]
	then
		log "'all' cannot be combined with another positional argument." >&2
		exit 2
	fi

	filtered_args=()
	for arg in "${slangtest_args[@]}"
	do
		[ "$arg" != all ] && filtered_args+=("$arg")
	done
	slangtest_args=("${filtered_args[@]}")
	log "Full test suite explicitly selected."
fi

if [ "$server_count" -gt 0 ]
then
	slangtest_args=(
		-use-test-server
		-server-count "$server_count"
		"${slangtest_args[@]}"
	)
fi

if [ -n "$build_config" ]
then
	search_configs=("$build_config/bin" "$build_config")
else
	search_configs=(Debug/bin Release/bin Debug Release)
fi

unset slangtest
slangtest_root=.
for d in ./build ../build ../../build ../../../build
do
	for c in "${search_configs[@]}"
	do
		for e in slang-test slang-test.exe
		do
			slangtest_candidate="$d/$c/$e"
			$verbose && log "Checking: $slangtest_candidate"

			if [ -f "$slangtest_candidate" ] && [ -x "$slangtest_candidate" ]
			then
				if [ -n "$slangtest" ]
				then
					log "More than one executable found: $slangtest_candidate"
				else
					$verbose && log "Found: $slangtest_candidate"
					slangtest="$slangtest_candidate"
					slangtest_root="${d%/build}"
				fi
			fi
		done
	done
	[ -d .git ] && break
done

if [ -z "$slangtest" ]
then
	log "slang-test is not found."
	exit 1
fi

# Mirror the skip lists that .github/workflows/ci-slang-test.yml applies.
skip_lists=()
if [ "${#requested_skip_lists[@]}" -gt 0 ]
then
	for skip_list in "${requested_skip_lists[@]}"
	do
		add_skip_list "$skip_list" "requested"
	done
else
	add_skip_list "$slangtest_root/tests/skip-list-gpu-t4.txt" "GPU"
	case "$slangtest" in
		*/Debug/*)
			add_skip_list "$slangtest_root/tests/skip-list-debug.txt" "debug build"
			;;
	esac
fi

slangtest_options=(-v failure)
for skip_list in "${skip_lists[@]}"
do
	slangtest_options+=(-skip-list "$skip_list")
done
for arg in "${slangtest_args[@]}"
do
	slangtest_options+=("$arg")
done
printf -v slangtest_command '%q ' "$slangtest" "${slangtest_options[@]}"
log "${slangtest_command% }"
"$slangtest" "${slangtest_options[@]}"
