#!/bin/bash
if [ "x$1" != "x" ]
then
        echo "[$(date)] Changing the working directory to: $1"
        cd "$1"
fi

if [ ! -d .git ]
then
        echo "Directory not found: .git"
        exit 1
fi

echo "[$(date)] The top commit is:"
git log -1 --oneline

if ! defaultBranch="$(git remote show upstream | grep 'HEAD branch:' | cut -d':' -f2 | tr -d ' ')"
then
        exit 2
fi
upstreamBranch="${defaultBranch##*/}"
echo "[$(date)] Upstream branch is: $upstreamBranch"


upstreamFetch="$(git remote show upstream | grep 'Fetch URL: ' | sed 's|.*Fetch URL: ||')"
if [ "x$upstreamFetch" = "x" ]
then
        echo "[$(date)] Upstream fetch URL not set"
        exit 2
fi
echo "[$(date)] Upstream URL is: $upstreamFetch"


echo "[$(date)] Fetch from upstream ..."
if ! git fetch -q upstream
then
        echo "[$(date)] git fetch failed"
        exit 2
fi

echo "[$(date)] The top commit on upstream/$upstreamBranch is:"
git log -1 --oneline upstream/$upstreamBranch


echo "[$(date)] Reset hard to upstream/$upstreamBranch ..."
if ! git reset -q --hard upstream/$upstreamBranch
then
        echo "git reset --hard failed"
        exit 2
fi


echo "[$(date)] Push force to origin/$defaultBranch ..."
if ! git push -q origin $defaultBranch --force
then
        echo "[$(date)] Pushing failed."
        exit 2
fi


echo "[$(date)] Updating submodules ..."
if ! git submodule -q update --init --recursive
then
        echo "[$(date)] Failed to update submodules."
        exit 2
fi

echo "[$(date)] Worktree prune ..."
if ! git worktree prune
then
        echo "[$(date)] worktree prune failed."
        exit 2
fi

echo "[$(date)] The top commit is:"
git log -1 --oneline
