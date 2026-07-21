#!/bin/bash

start_seconds=$SECONDS
verbose=false
build_config=

log()
{
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
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

get_cpu_count()
{
	local count

	if command -v nproc >/dev/null 2>&1
	then
		count=$(nproc)
	elif command -v sysctl >/dev/null 2>&1
	then
		count=$(sysctl -n hw.logicalcpu 2>/dev/null)
	elif [ -n "${NUMBER_OF_PROCESSORS:-}" ]
	then
		count="$NUMBER_OF_PROCESSORS"
	fi

	if [[ "${count:-}" =~ ^[1-9][0-9]*$ ]]
	then
		printf '%s\n' "$count"
	else
		printf '1\n'
	fi
}

usage()
{
	log "Usage: $0 [--debug | --release] [--server-count X] [--verbose] [--] [slang-test arguments...]" >&2
}

server_count=$(get_cpu_count)
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

log "slang-test found: $slangtest"
"$slangtest" "${slangtest_args[@]}"
