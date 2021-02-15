#!/bin/sh

# Fail if an unset variable is referenced (bad config).
set -eu

. /etc/stagit/stagit.conf

stagit-index "$GIT_HOME"/*.git > "$WWW_HOME/index.html"
