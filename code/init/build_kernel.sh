#!/bin/sh

rm -rf ./linux*

curl -LO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.38.tar.xz
tar xf linux-6.1.38.tar.xz

cd linux-6.1.38

# Create a config with default options
make defconfig

# Enable CONFIG_UEVENT_HELPER for `mdev` to work, as described in the setup section
echo "CONFIG_UEVENT_HELPER=y" >> .config
make olddefconfig

# Build the kernel. might take a while...
make -j"$(nproc)"
