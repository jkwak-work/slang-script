#!/bin/bash

verbose=false
build_config=
release_tag=

log()
{
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

usage()
{
	log "Usage: $0 [--debug | --release | --tag TAG] [--verbose] [--] [slangc arguments...]" >&2
}

detect_release_platform()
{
	local kernel
	local machine

	kernel=$(uname -s)
	machine=$(uname -m)
	case "$kernel:$machine" in
		Linux:x86_64|Linux:amd64)
			if [ -r /proc/sys/kernel/osrelease ] && grep -qi microsoft /proc/sys/kernel/osrelease
			then
				release_platform=windows-x86_64
				release_executable=slangc.exe
				release_host=wsl
			else
				release_platform=linux-x86_64
				release_executable=slangc
				release_host=linux
			fi
			;;
		Darwin:arm64|Darwin:aarch64)
			release_platform=macos-aarch64
			release_executable=slangc
			release_host=macos
			;;
		MINGW*:x86_64|MSYS*:x86_64|CYGWIN*:x86_64)
			release_platform=windows-x86_64
			release_executable=slangc.exe
			release_host=windows
			;;
		*)
			log "Unsupported platform: $kernel $machine" >&2
			return 1
			;;
	esac

	log "Detected platform: $release_platform"
}

extract_release_archive()
{
	case "$release_host" in
		wsl)
			local archive_windows
			local release_dir_windows
			archive_windows=$(wslpath -w "$archive") || return 1
			release_dir_windows=$(wslpath -w "$release_dir") || return 1
			powershell.exe -NoProfile -NonInteractive -Command \
				'& { param($archive, $destination) Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force }' \
				"$archive_windows" "$release_dir_windows"
			;;
		windows)
			powershell.exe -NoProfile -NonInteractive -Command \
				'& { param($archive, $destination) Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force }' \
				"$archive" "$release_dir"
			;;
		linux)
			unzip -oq "$archive" -d "$release_dir"
			;;
		macos)
			ditto -x -k "$archive" "$release_dir"
			;;
	esac
}

slangc_args=()
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
		--tag)
			if [ "$#" -lt 2 ]
			then
				log "--tag requires a Slang release tag, for example: --tag v2026.13.1" >&2
				usage
				exit 2
			fi
			release_tag="$2"
			shift
			;;
		--)
			shift
			slangc_args+=("$@")
			break
			;;
		*)
			slangc_args+=("$1")
			;;
	esac
	shift
done

if [ -n "$release_tag" ] && [ -n "$build_config" ]
then
	log "--tag cannot be combined with --debug or --release." >&2
	usage
	exit 2
fi

if [ -n "$release_tag" ] && [[ ! "$release_tag" =~ ^v20[0-9A-Za-z._-]*$ ]]
then
	log "Invalid Slang release tag: $release_tag" >&2
	exit 2
fi

unset slangc
if [ -n "$release_tag" ]
then
	if [ -z "${SLANGC_RELEASE_DIR:-}" ]
	then
		log "SLANGC_RELEASE_DIR must be set when using --tag." >&2
		exit 1
	fi

	release_dir="$SLANGC_RELEASE_DIR/$release_tag"
	for cached_slangc in "$release_dir/bin/slangc.exe" "$release_dir/bin/slangc"
	do
		if [ -f "$cached_slangc" ]
		then
			slangc="$cached_slangc"
			break
		fi
	done

	if [ -z "$slangc" ]
	then
		detect_release_platform || exit 1
		slangc="$release_dir/bin/$release_executable"
		version="${release_tag#v}"
		archive_name="slang-$version-$release_platform.zip"
		download_dir="$release_dir/download"
		archive="$download_dir/$archive_name"

		mkdir -p "$download_dir" || exit 1
		if [ ! -f "$archive" ]
		then
			log "Downloading Slang $release_tag..."
			if [ "$release_host" = wsl ]
			then
				download_dir_argument=$(wslpath -w "$download_dir") || exit 1
				gh_command=gh.exe
			else
				download_dir_argument="$download_dir"
				if [ "$release_host" = windows ]
				then
					gh_command=gh.exe
				else
					gh_command=gh
				fi
			fi
			if ! "$gh_command" release download "$release_tag" \
					--repo shader-slang/slang \
					--pattern "$archive_name" \
					--dir "$download_dir_argument"
			then
				log "Failed to download Slang release $release_tag." >&2
				exit 1
			fi
		fi

		log "Extracting: $archive"
		if ! extract_release_archive
		then
			log "Failed to extract $archive." >&2
			exit 1
		fi

		if [ ! -f "$slangc" ]
		then
			log "$release_executable was not found after extracting $archive." >&2
			exit 1
		fi
		if [ "$release_executable" = slangc ]
		then
			chmod +x "$slangc" || exit 1
		fi
	fi
elif [ -n "$build_config" ]
then
	search_configs=("$build_config/bin" "$build_config")
else
	search_configs=(Debug/bin Release/bin Debug Release)
fi

if [ -z "$slangc" ]
then
	for d in ./build ../build ../../build ../../../build
	do
		for c in "${search_configs[@]}"
		do
			for e in slangc slangc.exe
			do
				slangcCandidate="$d/$c/$e"
				$verbose && log "Checking: $slangcCandidate"

				if [ -f "$slangcCandidate" ] && [ -x "$slangcCandidate" ]
				then
					if [ "$slangc" != "" ]
					then
						log "More than one executable found: $slangcCandidate"
					else
						$verbose && log "Found: $slangcCandidate"
						slangc="$slangcCandidate"
					fi
				fi
			done
		done
		[ -d .git ] && break
	done
	if [ "$slangc" = "" ]
	then
		log "slangc is not found."
		exit 1
	fi
else
	$verbose && log "Using Slang release: $release_tag"
fi
log "slangc found: $slangc"

"$slangc" "${slangc_args[@]}"
