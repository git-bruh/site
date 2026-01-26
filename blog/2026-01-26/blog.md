# Faster package builds using Icecream and a Mac

Being a daily driver of a source-based Linux distribution ([KISS Linux](https://kisscommunity.org)), I recently had the idea of partly offloading package builds to my M3 MacBook (that mostly sits idle) for a potential speed up. In this post we'll be exploring how the [icecream](https://github.com/icecc/icecream) distributed compilation tool works and the challenges I faced setting it up in a multi-architecture environment

# Distributed Compilation

There are various distributed compilation projects like `distcc`, `sccache` and `icecream`, all implementing similar functionality but with different caveats:

- [icecream](https://github.com/icecc/icecream)
  - Supports offloading `cpp` preprocessing to remote nodes
  - Handles nodes dynamically joining/leaving the cluster
  - Has a centralized scheduler that helps saturate all the machines in the cluster, performing the best of the three tools in my testing

- [distcc](https://github.com/distcc/distcc)
  - [`pump`](https://www.distcc.org/man/pump_1.html) mode which implements offloading for `cpp` preprocessing [causes various build failures](https://bugs.gentoo.org/702146)
  - Relies on a hardcoded list of IPs to identify nodes

- [sccache](https://github.com/mozilla/sccache)
  - Additionally supports Rust
  - Implements caching like [`ccache`](https://ccache.dev/)
  - Does not play well with multi-architecture nodes in the same cluster [#2560](https://github.com/mozilla/sccache/issues/2560)

When compiling a `.c` file, `icecream` first passes it through the host compiler with the `-frewrite-includes` (Clang) or `-fdirectives-only` (GCC) flag to perform only partial preprocessing such as expanding `#include` directives, making the files self-contained and independent of the system headers/libraries. Then, the file is compressed and transmitted to the remote node, where the compiler is invoked to generate the corresponding `.o` file, and the final link step happens on the host itself

# Setup

```
+-------------------+       +-------------------+
|  Node A (x86_64)  |       |  Node B (arm64)   |
|-------------------|       |-------------------|
|   icecc wrapper   |       |  (cross-)compiler |
|   iceccd daemon   | <---> |  iceccd daemon    |
|   icecc-scheduler | <---> |  iceccd daemon    |
+-------------------+  TCP  +-------------------+
```

In our setup we have Node A (which is the "host"), and Node B (which is the MacBook):

- `icecc-scheduler` facilitates node discovery as the `iceccd` daemon on both nodes connects to it, we're hosting the scheduler on the "host" and also using it as a node

- `iceccd` runs on both nodes and is responsible for actually invoking the compiler (either local or remote as determined by the scheduler)

- When invoking the compiler, we use the `icecc` wrapper (eg. `/usr/lib/icecc/bin/gcc` instead of `/usr/bin/gcc`) which internally connects to `iceccd` to distribute jobs

# Cross-Compilation Adventures

To invoke the compiler on the remote machine, `icecream` creates a tarball containing the bare minimum components of the host's toolchain as a `chroot`-able environment:

```sh
.
└── usr
    ├── bin
    │   ├── as
    │   ├── g++
    │   ├── gcc
    │   └── objcopy
    └── lib
        ├── libgcc_s.so.1
        ├── libstdc++.so.6
        ├── libz.so.1
        └── libzstd.so.1
```

This tarball is then transmitted to the remote machine, and each compiler invocation happens under a `chroot` environment. However, there are a few assumptions that are not true in our case:

1. Both our machines have differing architectures, so the x86_64 toolchain will not run on the other machine

2. It is not easily possible to construct a `chroot` environment for MacOS since shared libraries are not exposed on the filesystem and are instead part of a [global linker cache](https://github.com/icecc/icecream/issues/592), and our Linux chroot would be unusable regardless

For `(1)`, I attempted to use an x86_64 Docker image which internally ran with the Rosetta translation layer. While `icecream` was able to saturate the CPU, the compilations themselves ran very slowly, I assume this had something to do with Rosetta somehow not being able to cache the translated code executed under Docker causing every cold start of `gcc` to trigger a code translation

Next up was a native arm64 Docker image, requiring a cross-compiler that runs on `aarch64-linux-musl` and emits binaries for `x86_64-linux-musl`. [musl-cross-make](https://github.com/richfelker/musl-cross-make) can be used for this purpose, ensuring that we build the same compiler version as the host. `config.mak` contains the build config for gcc, we must ensure that the defaults match, for instance if the host compiler is built with `--enable-default-pie`, the cross-compiler must also be built with that flag, otherwise the final link step for distributed jobs would fail trying to link position-independent and non-position-independent code at once:

```diff
diff --git a/config.mak.dist b/config.mak
index 181976c..c46b6be 100644
--- a/config.mak.dist
+++ b/config.mak
@@ -67,10 +67,9 @@
 
 # Options you can add for faster/simpler build at the expense of features:
 
-# COMMON_CONFIG += --disable-nls
-# GCC_CONFIG += --disable-libquadmath --disable-decimal-float
-# GCC_CONFIG += --disable-libitm
-# GCC_CONFIG += --disable-fixed-point
+COMMON_CONFIG += --disable-nls
+GCC_CONFIG += --disable-fixed-point
+GCC_CONFIG += --enable-__cxa_atexit --enable-default-pie --enable-default-ssp --enable-threads --enable-tls --enable-initfini-array
 # GCC_CONFIG += --disable-lto
 
 # By default C and C++ are the only languages enabled, and these are
```

After this, we can simply run `make install` which builds & installs the toolchain under `./output`. Then, `icecc-create-env ./output/bin/x86_64-pc-linux-musl-cc` creates the chroot environment with the filename `<hash>.tar.gz`. This file must be transmitted to the host so that `icecream` can send it out to the arm64 host when compiling:

```sh
# arm64 toolchain
$ ARM64_CHROOT=/path/to/<arm64_hash>.tar.gz
# x86_64 toolchain (native)
# this is technically redundant but icecream doesn't schedule jobs to the other node
# if both architectures are not present in $ICECC_VERSION
$ icecc-create-env /usr/bin/gcc
adding file /usr/bin/gcc=/usr/bin/gcc
...
creating <x86_64_hash>.tar.gz
$ X86_64_CHROOT=/path/to/<x86_64_hash>.tar.gz
$ export ICECC_VERSION=aarch64:$ARM64_CHROOT,x86_64:$X86_64_CHROOT
```

**NOTE:** We only need to build a cross-compiler for using `gcc`. `clang` is a native cross-compiler, so all we need to do for `clang`-based setups is create a chroot pointing to an arm64 Clang/LLVM toolchain and put that in `ICECC_VERSION`, and `icecream` will pass the `-target` flag automatically

The `ICECC_VERSION` environment variable tells icecream which chroot to use for each architecture and it must be set globally for each `icecc` invocation. It is transmitted to the remote node on the first compilation and re-used thereafter. Finally, these are the commands to setup a "cluster":

On the host:

```sh
# This launches the scheduler (ideally use this with an init system)
$ icecc-scheduler
# This launches the icecc daemon, can pass the -m flag
# to limit the max jobs assigned to this machine
# (ideally use this with an init system)
$ iceccd

# Set MAKEFLAGS to have higher parallelism according to the cluster's core count
# This must be tweaked a bit as the initial `cpp` jobs will be spawned on the host itself
# so we must maintain some buffer instead of specifying all available CPUs
$ export MAKEFLAGS="-j17"
```

On the remote node (inside Docker)

```sh
# The port in -p is the port that will be bound on this node, it must be
# exposed using docker's -p flag as well
$ iceccd -s $HOST_NODE_IP -p $DAEMON_PORT
```

[`icecream-sundae`](https://github.com/JPEWdev/icecream-sundae) is a fancy monitoring tool, my host is providing 6 job slots here while the Mac is providing 11:

[![asciicast](https://asciinema.org/a/zfV5QYu6ufzT9Kl4.svg)](https://asciinema.org/a/zfV5QYu6ufzT9Kl4)

# Conclusion

I've been using `icecream` globally on my system (built 200+ packages ranging from `mesa`, `nodejs`, `qemu`, etc. to the kernel) for the past few weeks and have noticed compile times almost get halved with the extra processing power. However, a few patches need to be applied to make it work universally:

- [Fix for the `-Wp,MD` argument (#644)](https://github.com/icecc/icecream/pull/644/changes)

- [Fix for the `-imacros` argument (#652)](https://github.com/icecc/icecream/pull/652/changes)

- [Workaround to handle large object files (#650)](https://github.com/icecc/icecream/pull/650/changes)

Here is the `Dockerfile` I use on my Mac to build `icecream` from source with an alpine base image (run with `docker run -d --restart always ...`):

```Dockerfile
FROM alpine:latest AS base
RUN apk add g++ libarchive-dev libcap-ng-dev lzo-dev musl-dev zstd-dev

FROM base AS builder
WORKDIR /build
RUN apk add make patch && \
    wget https://github.com/icecc/icecream/releases/download/1.4/icecc-1.4.0.tar.xz && \
    wget https://github.com/git-bruh/icecream/commit/9424b5d45c15477b3557281288d96404a02a82a1.patch && \
    tar --strip-components=1 -xf icecc-1.4.0.tar.xz && \
    patch -p1 < 9424b5d45c15477b3557281288d96404a02a82a1.patch && \
    ./configure --disable-shared --enable-clang-wrappers --enable-clang-rewrite-includes --without-man && \
    make -C services && make -C daemon

FROM base
COPY --from=builder /build/daemon/iceccd /usr/local/sbin/iceccd
ENV SCHEDULER_URL=
ENV DAEMON_PORT=
ENTRYPOINT ["/bin/sh", "-c", "exec iceccd -v -s ${SCHEDULER_URL:?} -p ${DAEMON_PORT:?}"]
```

# Further Reading

- [Cross-compiling with icecream](https://blogs.igalia.com/siglesias/2021/12/09/Cross-compiling-with-icecream/)

- [Distributed Cross-compiling using Icecream](https://blog.sradjoker.cc/posts/linux-distributed-compiling/)

- [The C/C++ Developer’s Guide – Part 2: icecream](https://www.ul.com/sis/blog/cc-developers-guide-part-2-icecream)
