#!/bin/sh

# Fail if an unset variable is referenced (bad config).
set -eu

. /etc/stagit/stagit.conf

if [ $# -gt 1 ]; then
        DESC="$2"
else
        DESC="$DEFAULT_DESCRIPTION"
fi

if [ $# -eq 0 ]; then
        printf "not enough args\n" >&2
        exit 1
else
        REPO="$(basename "$1")"
fi

git init --bare "$GIT_HOME/$REPO.git"

# Share a common `git` hook between repositories.
ln -sf "/etc/stagit/post-receive" "$GIT_HOME/$REPO.git/hooks/post-receive"

echo "$CLONE_URI/$REPO.git" > "$GIT_HOME/$REPO.git/url"
echo "$DEFAULT_OWNER" > "$GIT_HOME/$REPO.git/owner"

# Ensure that `git daemon` allows repository cloning.
:> "$GIT_HOME/$REPO.git/git-daemon-export-ok"

echo "$DESC" > "$GIT_HOME/$REPO.git/description"

mkdir "$WWW_HOME/$REPO"
