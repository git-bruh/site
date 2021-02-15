#!/bin/sh

# Fail if an unset variable is referenced (bad config).
set -eu

. /etc/stagit/stagit.conf

# The hook is called from the repository's root.
src="$(pwd)"
name=$(basename "$src")
dst="$WWW_HOME/$(basename "$name" '.git')"
mkdir -p "$dst"
cd "$dst"

echo "[stagit] building $dst"
stagit "$src"

echo "[stagit] linking $dst"
ln -sf log.html index.html

for file in style.css logo.png; do
    ln -sf "../$file" "$file"
done
