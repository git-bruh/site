mkdir -p /etc/sv/git-daemon

cat > /etc/sv/git-daemon/run << EOF
#!/bin/sh

. /etc/stagit/stagit.conf

# Run `git daemon` as our `git` user (security).
exec chpst -u git git daemon --base-path="\$GIT_HOME"
EOF

ln -s /run/runit/supervise.git-daemon /etc/sv/git-daemon/supervise
ln -s /etc/sv/git-daemon /var/service/ # Enable the service
