#!/bin/sh

set -eu

rm -rf rootfs ./busybox-*

# The rootfs will be created at this path
MY_ROOTFS="$PWD/rootfs"

# Downloading sources
curl -LO https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xf busybox-1.36.1.tar.bz2
cd busybox-1.36.1

# Use the default configuration that includes the necessary stuff
make defconfig

# Enable the static build
sed -i 's/^# CONFIG_STATIC.*/CONFIG_STATIC=y/' .config

# Only look for services in /etc/runit/sv
sed -i 's|/var/service|/etc/runit/sv|' .config

# Build using all the cores on the system
make -j"$(nproc)"

# Install it to the rootfs directory
make CONFIG_PREFIX="$MY_ROOTFS" install

cd ..

# Dirs for mounting pseudo-filesystems
for dir in dev sys proc tmp; do
    mkdir "$MY_ROOTFS/$dir"
done

# Required for users & groups stuff
mkdir "$MY_ROOTFS/etc"

echo "root:x:0:" > "$MY_ROOTFS/etc/group"
echo "root:x:0:0:root:/root:/bin/sh" > "$MY_ROOTFS/etc/passwd"

# TTY Service
mkdir -p "$MY_ROOTFS/etc/runit"

cp stage1.sh "$MY_ROOTFS/etc/runit/stage1"
chmod +x "$MY_ROOTFS/etc/runit/stage1"

SVDIR="$MY_ROOTFS/etc/runit/sv"
mkdir -p "$SVDIR"

mkdir -p "$SVDIR/tty1"
cat > "$SVDIR/tty1/run" <<EOF
#!/bin/sh
# Automatically login as root without a password
# -l changes the LOGIN command to be executed such that it
# executes /bin/su directly instead of asking for a password
# We use ttyS0 instead of tty1 as this will run under Qemu
/sbin/getty 38400 ttyS0 -l /bin/su
EOF
chmod +x "$SVDIR/tty1/run"

# Inittab
cat > "$MY_ROOTFS/etc/inittab" <<EOF
::sysinit:/etc/runit/stage1
::respawn:/usr/bin/runsvdir -P /etc/runit/sv
EOF

(
  cd rootfs
  find . | cpio -o -H newc > ../initramfs.cpio
)

echo "Stored initramfs at $PWD/initramfs.cpio"
