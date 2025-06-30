#!/bin/bash
if [ ! -d .git ]
then
	echo "Directory not found: .git"
	exit 1
fi

performRebase=true
unset branchName
unset branchType
while [ "x$1" != "x" ]
do
	case "$1" in
		--feature|-feature)
			branchType=feature
			;;
		--fix|-fix)
			branchType=fix
			;;
		--refactoring|-refactoring)
			branchType=refectoring
			;;
		--doc|-doc)
			branchType=doc
			;;
		--test|-test)
			branchType=test
			;;
		--wip|-wip)
			branchType=wip
			;;
		--rebase|-rebase)
			branchType=rebase
			;;
		--update|-update)
			branchType=update
			;;
		--skip-rebase)
			performRebase=false
			;;
		*)
			if [ "$branchName" != "" ]
			then
				echo "Cannot use more than one branch name: $branchName $1"
				exit 1
			fi
			branchName=$1
			;;
	esac
	shift
done

if [ "x$branchName" = "x" ] || [ "x$branchType" = "x" ]
then
	echo "Usage: $0 (--feature|--fix|--doc|--test|--wip) [new branch name]"
	exit 1
fi

# Check if branch name is too long to avoid Windows path length issues
branchNameLength=${#branchName}
maxBranchNameLength=50
if [ $branchNameLength -gt $maxBranchNameLength ]
then
	echo "Error: Branch name is too long ($branchNameLength characters)"
	echo "Maximum allowed length is $maxBranchNameLength characters to avoid Windows path issues"
	echo "Current branch name: $branchName"
	echo "Please use a shorter branch name."
	exit 1
fi

currentBranch="$(git branch --show-current)"
if ! echo "$currentBranch" | grep -q "master\|main\|release"
then
	echo "Current branch is not master: $currentBranch"
	exit 2
fi
echo "[$(date)] Current branch is: $currentBranch"

upstreamFetch="$(git remote show upstream | grep 'Fetch URL: ' | sed 's|.*Fetch URL: ||')"
if [ "x$upstreamFetch" = "x" ]
then
	echo "Upstream fetch URL not set"
	exit 2
fi

echo "[$(date)] Fetch from $upstreamFetch ..."
if ! git fetch -q upstream
then
	echo "git fetch failed"
	exit 2
fi


if $performRebase
then
	echo "[$(date)] Rebasing from upstream/$currentBranch ..."
	if ! git rebase -q upstream/$currentBranch
	then
		echo "Rebasing failed."
		echo "You may want to do: git reset --hard && git clean -fxq ."
		exit 2
	fi

else
	echo "[$(date)] Skipping rebase for $currentBranch"
fi

echo "[$(date)] Updating submodules ..."
if ! git submodule -q update --init --recursive
then
	echo "[$(date)] Failed to update submodules."
	exit 2
fi

echo "[$(date)] Prune worktree ..."
if ! git worktree prune
then
	echo "Failed to prune worktree"
	exit 2
fi

echo "[$(date)] Adding a new worktree: ../$branchName ..."
if ! git worktree add -q -d "../$branchName"
then
	echo "Failed to create a new worktree: $branchName"
	exit 2
fi
# Simple relative path calculation - works on all platforms
relMaster="$(basename "$(pwd)")"

echo "[$(date)] Creating and switching to a new branch: $branchType/$branchName ..."
cd "../$branchName" || exit 2
trap 'echo "DO NOT FORGET TO CHANGE DIRECTORY to ../'$branchName'"' EXIT
if ! git checkout -b "$branchType/$branchName"
then
	echo "Failed to create a new branch."
	exit 2
fi

if [ -f .gitmodules ]
then
	echo "[$(date)] Initialize submodules ..."
	#for m in $(grep 'path = ' .gitmodules | dos2unix | sed 's|.*path = ||')
	for m in $(grep 'path = ' .gitmodules | sed 's|.*path = ||' | tr -d '\r')
	do
		echo "[$(date)] Initializing: $m ..."
		moduleLocal="../$relMaster/$m"
		git submodule -q update --init --reference "$moduleLocal" "$m" &
	done
	wait

	echo "[$(date)] Updating submodules recursively ..."
	if ! git submodule -q update --init --recursive
	then
		echo "[$(date)] submodule update failed, you may want to manually update them:"
		echo "[$(date)]   git submodule update --init"
		exit 2
	fi
else
	echo "[$(date)] Skipping submodule initialization, because .gitmodules is not found."
fi

echo "[$(date)] done ..."

