# A Basic Init System Setup

In this post, I'll go over how basic Linux init systems work by explaining all the stuff that happens during the boot process - right from the kernel image being loaded to the user being dropped to a TTY.

**NOTE:** You can use the scripts present in [this](https://github.com/git-bruh/git-bruh.github.io/tree/master/code/init) repo to perform all the tasks described here rather than doing them by hand, see the `README.md` for more information.

## `runit`

We'll be using `runit` (the traditional init system of choice for minimalist folks) for this purpose as it has very few moving parts, making the whole ordeal easier to understand.

An init system has a few basic tasks to perform, which can conceptually be organized into "stages":

- Stage 1 is the initialization phase wherein the core, one-time initialization tasks are performed, which include mounting pseudo-filesystems like `/dev`, setting up device nodes nodes, mounting filesystems defined in `/etc/fstab`, and so on.

- Stage 2 refers to the actual spawning of system services/daemons by the service manager, which further exposes interfaces to users to manage said services

- Stage 3 is when all the services are stopped and the system shuts down

In `runit`, there's two main components (or binaries) involved in executing all these stages:

- [`runit`](http://smarden.org/runit/runit.8.html): The binary that's executed by the kernel as PID 1. It is responsible for kickstarting the whole boot process; from running the stage 1 scripts to handling poweroff/reboot (i.e. stage 3) commands.

- [`runsvdir`](http://smarden.org/runit/runsvdir.8.html): This is responsible for actually spawning the long-running services we define. Said services are managed using the [`sv`](http://smarden.org/runit/sv.8.html) command.

Note that we'll be using `busybox`'s `runit` implementation in this post since that's what I've been using so far, so the linked docs _might_ not match up 1:1 in all the cases, but the main ideas hold.

## Creating The Rootfs

Now we'll work our way up to a bootable system that uses `busybox` for it's coreutils as well as the `runit` implementation. Note that we're limiting this system's scope quite a bit, so it's only going to be capable of logging in as a user and supervising a long running daemon.

First we'll create a minimal rootfs. It's quite easy; all you need is a `busybox` build and boom, you have `runit` and the necessary coreutils. Moreover, we'll be doing a fully static build of busybox so we don't even need a C library in the rootfs!

```sh
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
```

We'll also create empty dirs for the pseudo-filesystems to be mounted upon and some skeleton files required for various coreutils (such as `ls`) to recognize the current user/group properly (via the [`getpw{nam,uid}*`](https://www.man7.org/linux/man-pages/man3/getpwnam.3.html) and similar families of functions):

```sh
MY_ROOTFS="$PWD/rootfs"

# Dirs for mounting pseudo-filesystems
for dir in dev sys proc tmp; do
    mkdir "$MY_ROOTFS/$dir"
done

# Required for users & groups stuff
mkdir "$MY_ROOTFS/etc"

echo "root:x:0:" > "$MY_ROOTFS/etc/group"
echo "root:x:0:0:root:/root:/bin/sh" > "$MY_ROOTFS/etc/passwd"
```

## Init Setup

Now, we can get to actually writing the init scripts that perform the functions described at the beginning of this section.

Let's write the Stage 1 script, responsible for initializing core system components required by basically any process to function. We'll divide this into functions to make the explanation easier:

1. `mnt_fs` - This function is responsible for mounting pseudo-filesystems like `/dev`, `/sys` and `/proc` aswell as user-defined filesystems/mountpoints:

```sh
mnt_fs() {
  mount -t devtmpfs -o mode=0755 dev /dev
  mount -t sysfs sys /sys
  mount -t proc proc /proc

  # Read /etc/fstab (Commented out since we don't have one)
  # mount -a
}
```

2. `coldplug` - This function runs the coldplug procedure using the device manager, `mdev` which ensures that device nodes in `/dev` are set up and have the correct permissions:

```sh
coldplug() {
  # Execute mdev every time a device node related event is triggered
  echo /sbin/mdev > /proc/sys/kernel/hotplug

  # The -s flag tells mdev to trigger events for initial node population
  # which would then be handled by mdev itself when it is fork+exec'd by the kernel
  /sbin/mdev -s
}
```

A more detailed explanation can be found in the [BusyBox documentation](https://git.busybox.net/busybox/tree/docs/mdev.txt?h=1_18_stable). Also note that it's preferred to run the device manager as a daemon to receive and handle udev events since `fork+exec()`-ing the device manager for every event is [quite expensive](https://www.kernelconfig.io/config_uevent_helper).

3. `misc` - This is the final function where we're just going to put in misc. stuff like setting up the [`hostname`](https://www.man7.org/linux/man-pages/man1/hostname.1.html) and the loopback network device (which allows `localhost` to function):

```sh
misc() {
  echo "installgentoo" > /proc/sys/kernel/hostname
  ip link set up dev lo

  # Print out the time taken for the boot process
  IFS=. read -r boot_time _ < /proc/uptime
  echo "Boot stage completed in ${boot_time}s"
}
```

Note that in an actual setup, a few more functions are performed which are ommited here since we just want to understand the core concept. More featureful `runit` scripts can be found in [KISS Linux's setup](https://codeberg.org/kiss-community/init), some documentation for it can be found [here](https://kisslinux.org/wiki/pkg/baseinit) and [here](https://kisslinux.org/wiki/service-management).

This file, which can be found [here](https://github.com/git-bruh/git-bruh.github.io/tree/master/code/init/stage1.sh) should be placed in `/etc/runit/`:

```sh
mkdir -p "$MY_ROOTFS/etc/runit"

cp stage1.sh "$MY_ROOTFS/etc/runit/stage1"
chmod +x "$MY_ROOTFS/etc/runit/stage1"
```

Now coming to stage 2, we'll just define a tty service, stored in `/etc/sv`. The command to be executed by the init system is simply to be put in an executable file called `run`:

```sh
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
```

The [`getty`](https://www.unix.com/man-page/Linux/8/getty) command basically sets up a TTY and executes the `login` command, allowing the user to login.

**NOTE:** In a non-trivial setup, this step would include services for various daemons such as `dhcpcd`, `ntpd`, etc. aswell, which would be defined in a similar fashion. For example, look at Void Linux's [`ntpd` service](https://github.com/void-linux/void-packages/blob/master/srcpkgs/openntpd/files/openntpd/run).

**NOTE:** In traditional setups, `/etc/sv` is used more like a database of all the available services which are then symlinked to the `/var/service` (or similar) directory, and `runsvdir` is run on `/var/service`. You can read more about this on the respective [Void Linux](https://docs.voidlinux.org/config/services/index.html) and [Artix Linux](https://wiki.artixlinux.org/Main/Runit) pages.

As for stage 3, we don't really need one here since the init & kernel perform most of the cleanup for us. It might be useful in certain cases though, such as unmounting network filesystems.

Finally, for actually telling `runit` (the busybox variant) of where to actually find the scripts & services we defined, we'll use the `/etc/inittab` file:

```sh
cat > "$MY_ROOTFS/etc/inittab" <<EOF
::sysinit:/etc/runit/stage1
::respawn:/usr/bin/runsvdir -P /etc/runit/sv
EOF
```

The `sysinit` directive points to the `stage1` script, whereas the `respawn` directive tells it to run `runsvdir` (and restart it if it crashes for some reason), which in turn runs/supervises all the services defined in `/etc/runit/sv`

## Running The System

We'll now run the system we just built using Qemu, for which we need to perform two more tasks:

- Packing the rootfs into an initramfs

- Building a bootable kernel

Why are we creating an initramfs based on the root filesystem? The initramfs is loaded by the kernel and is responsible for doing preliminary tasks such as loading modules for core components such as filesystems. Now we're going to exploit this fact to obviate the need to have any real partitions set up at all, so that we don't need to create a proper Qemu image and set up a bootloader and all that boring stuff.

For creating an initramfs, we'll just use the [`cpio`](https://linux.die.net/man/1/cpio) command:

```sh
cd "$MY_ROOTFS"
find . | cpio -o -H newc > ../initramfs.cpio
```

Now, we'll configure the kernel; won't be going too much in detail here, just sticking with the defaults:

```sh
curl -LO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.38.tar.xz
cd linux-6.1.38

# Create a config with default options
make defconfig

# Enable CONFIG_UEVENT_HELPER for `mdev` to work, as described in the setup section
echo "CONFIG_UEVENT_HELPER=y" >> .config
make olddefconfig

# Build the kernel. might take a while...
make -j"$(nproc)"
```

At this stage, your directory tree should look something like this:

```sh
.
├── ...
├── initramfs.cpio
└── rootfs
linux-6.1.38/arch/x86/boot
├── ...
└── bzImage
```

Now, we can finally run the system:

```sh
qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -kernel linux-6.1.38/arch/x86/boot/bzImage \
  -initrd ./initramfs.cpio \
  -nographic \
  -append 'rdinit=/sbin/init console=ttyS0' # Execute /sbin/init (runit) as PID 1
```

The system boots in less than 600ms (almost all of it being from the kernel itself, since the init scripts themselves barely do anything :p), we can see the service manager in action here aswell since the login prompt re-appears when we exit the shell:

```sh
[    0.546986] Freeing unused kernel image (text/rodata gapK
[    0.547760] Freeing unused kernel image (rodata/data gapK
[    0.571559] x86/mm: Checked W+X mappings: passed, no W+X.
[    0.571841] Run /sbin/init as init process
[    0.572642] mount (70) used greatest stack depth: 13856 t
Boot stage completed in 0s

[    1.148601] input: ImExPS/2 Generic3
installgentoo login: root
/etc/runit/sv/tty1 # whoami
root
/etc/runit/sv/tty1 # sv status tty1
run: tty1: (pid 77) 33s
/etc/runit/sv/tty1 # exit

installgentoo login: root
/etc/runit/sv/tty1 # sv status tty1
run: tty1: (pid 94) 3s
/etc/runit/sv/tty1 # # Time & PID reset due to restart
```

Similarly, any other long-running service such as `dhcpcd` would automatically be restarted when it's either killed, or an `sv restart dhcpcd` command is issued.

Finally, the `poweroff` command signals `init`, causing it to clean up all the process first by sending them a SIGTERM, and then a SIGKILL (which can't be ignored and always kills the process) and power off the system:

```sh
...
/etc/runit/sv/tty1 # poweroff
The system is going down NOW!
Sent SIGTERM to all processes
Terminated
Sent SIGKILL to all processes
Requesting system poweroff
[  226.245418] ACPI: PM: Preparing to enter system sleep st5
[  226.245679] reboot: Power down
```
