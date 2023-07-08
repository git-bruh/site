Cloning:

```sh
git clone https://github.com/git-bruh/git-bruh.github.io
cd git-bruh.github.io/code/init
```

Generating the rootfs, this will create the rootfs in the `rootfs/` directory and archive it in `initramfs.cpio`:

```sh
./generate_rootfs.sh
```

Building the kernel, this will download the kernel sources and create a kernel build at `linux-6.1.38/arch/x86/boot/bzImage` for Qemu:

```sh
./build_kernel.sh
```

The commands to run the Qemu virtual machine can be found in the `Running The System` section and should be run from within this directory
