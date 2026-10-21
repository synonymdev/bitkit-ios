#!/usr/bin/env bash
# Shrinks SwiftPM's package clones to the pinned commits so CI can cache them.
#
# SwiftPM keeps a full bare clone of every package under <SourcePackages>/repositories, and
# looks each one up again on every resolve (bitkit-core's history alone is over 13 GB, past
# the repository cache limit). This keeps, for each clone, only the commit its checkout is
# on plus the tags pointing at it, and drops the checkouts' own refs to commits that are gone.
#
# Usage: scripts/shallow-source-packages.sh <SourcePackages dir>
set -euo pipefail

source_packages="${1:?usage: $0 <SourcePackages dir>}"

for checkout in "$source_packages"/checkouts/*/; do
    checkout="${checkout%/}"
    alternates="$checkout/.git/objects/info/alternates"
    [ -f "$alternates" ] || continue
    repository="$(dirname "$(cat "$alternates")")"
    revision="$(git -C "$checkout" rev-parse HEAD)"

    shallow="$repository.shallow"
    rm -rf "$shallow"
    git init -q --bare "$shallow"
    cp "$repository/config" "$shallow/config"
    git -C "$repository" config uploadpack.allowAnySHA1InWant true

    refspecs=("$revision:refs/heads/pinned")
    while read -r tag; do
        [ -n "$tag" ] && refspecs+=("refs/tags/$tag:refs/tags/$tag")
    done < <(git -C "$repository" tag --points-at "$revision")
    git -C "$shallow" fetch -q --depth 1 --no-tags "file://$repository" "${refspecs[@]}"

    rm -rf "$repository"
    mv "$shallow" "$repository"

    cp "$repository/shallow" "$checkout/.git/shallow"
    git -C "$checkout" update-ref --no-deref HEAD "$revision"
    git -C "$checkout" for-each-ref --format='%(refname)' | while read -r ref; do
        git -C "$checkout" update-ref -d --no-deref "$ref"
    done
    rm -rf "$checkout/.git/logs"

    echo "$(basename "$checkout"): $(du -sh "$repository" | cut -f1) at ${revision:0:7}"
done
