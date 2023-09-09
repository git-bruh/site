# Profiling Function Runtime Using `perf`

In the standard `perf` use-case, we can only retrieve the execution time of each function as a percentage of the total runtime, as opposed to absolute values. This data is then fed into tools like [flamegraph](https://github.com/flamegraph-rs/flamegraph), or just analyzed with `perf report`:

```sh
$ cc garbage.c -g3
$ perf record --call-graph dwarf ./a.out
[ perf record: Woken up <...> times to write data ]
[ perf record: Captured and wrote <...> MB perf.data (<...> samples) ]
$ perf report
...
    99.97%    60.26%  a.out    a.out              [.] main
            |          
            |--60.26%--_start
            |          __libc_start_main
            |          0x7fc76f26ac49
            |          main
            |          
             --39.71%--main
                       |          
                        --39.69%--func
...
```

Now, getting the absolute runtime of each function is fairly straightforward using [perf probes](https://man7.org/linux/man-pages/man1/perf-probe.1.html) but took me a lot of time to figure out the end-to-end usage, which I'll be documenting here.

# Probes

A probe can be registered using the `perf probe` command, passing the executable and the function (symbol) name to be probed:

```sh
perf probe \
    --exec testbin \
    --add func \
    --add func%return
```

This will register two probe events, one for function entry (`probe_testbin:func`) and one for function return (`probe_testbin:func__return`):

```sh
Added new events:
  probe_testbin:func   (on func in /tmp/testbin)
  probe_testbin:func__return (on func%return in /tmp/testbin)
...
```

Now, we can use these probes to profile the individual functions. We use `perf record` with the `-e` flag to match all the events registered by us so we don't have to pass them individually (those events won't be recorded by default):

```sh
# Matches probe_testbin:func and probe_testbin:func__return
perf record \
    -e 'probe_testbin:*' \
    --call-graph dwarf \
    ./testbin
```

Note that the using frame pointers for call graph collection (`--call-graph fp`) likely has lower overhead than stack unwinding (`--call-graph dwarf`) but requires your program to be compiled with the `-fno-omit-frame-pointer` flag.

Finally, we can extract the relevant insights using `perf script`:

```sh
perf script \
    -F "comm,pid,tid,cpu,time,event"
```

We log various other fields like the PID and TID which can be useful to correlate the output with the thread and process a function was executed under. The code runs for 4 iterations, sleeping for 1 second on one iteration, and 2 seconds on the other:

```sh
testbin  4583/4583  [011] 18314.387304:         probe_testbin:func: 
testbin  4583/4583  [011] 18315.388390: probe_testbin:func__return: 
testbin  4583/4583  [011] 18315.388413:         probe_testbin:func: 
testbin  4583/4583  [011] 18317.390484: probe_testbin:func__return: 
testbin  4583/4583  [011] 18317.390504:         probe_testbin:func: 
testbin  4583/4583  [011] 18318.391566: probe_testbin:func__return: 
testbin  4583/4583  [011] 18318.391584:         probe_testbin:func: 
testbin  4583/4583  [011] 18320.393642: probe_testbin:func__return:
```

If we want to add more probes, we can repeat the steps described above. Existing probes can be removed using the `perf probe --del "probe_testbin:*"` command.

# Automating The Process

We can write a few helper scripts for all this to make our lives a bit easier and handle quirks like name mangling for languagues like C++ and Rust.

Example code (C++), compile with `c++ <file> -g3 -o testbin`

```cc
#include <poll.h>
#include <stddef.h>

// Useless class
class Garbage {
public:
  // Useless overload to illustrate demangling quirks
  static void func(int i) {}

  static void func(int i, void *p) {
    // Sleep for 1 seconds for multiples of 2, else 2
    poll(NULL, 0, (i % 2 == 0) ? 1000 : 2000);
  }
};

int main() {
  // nop
  Garbage::func(0);

  // sleep at alternating intervals
  for (auto i = 0; i < 4; i++) {
    Garbage::func(1, NULL);
  }
}
```

First, to extract mangled symbols and their addresses:

```sh
#!/bin/sh

# Dump the symbol table without truncating the output for terminal width
# Eg. 18: 000000000000115d    10 FUNC    WEAK   DEFAULT   15 _ZN7Garbage4funcEi
readelf -sW "$1" | while read -r _ addr _ is_func _ _ _ mangled_name; do
    # We only care about function symbols
    [ "$is_func" = "FUNC" ] || continue

    # Demangle the symbol using c++filt and output the function address, mangled
    # and demangled name
    echo "$addr $mangled_name $(c++filt "$mangled_name")"
done
```

Now, we can use this script to extract the relevant functions we want to profile:

```sh
# Filter out the garbage functions we want to profile
$ ./extract.sh ./testbin | grep Garbage:: | tee extracted
0000000000001174 _ZN7Garbage4funcEi Garbage::func(int)
000000000000117e _ZN7Garbage4funcEiPv Garbage::func(int, void*)
```

Finally we will use this script to parse the extracted output and register probes:

```sh
#!/bin/sh

set -eu

# Argument 1: path to executable
EXE="$1" # /path/to/executable
EXTRACTED="${2:-extracted}" # Extracted symbols
PROBE_PREFIX="$(basename "$EXE")" # executable

# Remove all previously registered probes
perf probe --del "probe_${PROBE_PREFIX}:*"

while read -r addr mangled demangled; do
    perf probe \
        --exec "$EXE" \
        --no-demangle \
        --add "${mangled}" \
        --add "${mangled}%return"
done < "$EXTRACTED"

# Record all the registered events
perf record \
    -e "probe_${PROBE_PREFIX}:*" \
    --call-graph dwarf \
    "$EXE"

# Output the recorded data
perf script \
    -F "comm,pid,tid,cpu,time,event"
```

```sh
$ ./profile.sh ./testbin
Removed event: probe_testbin:_ZN7Garbage4funcEi
Removed event: probe_testbin:_ZN7Garbage4funcEiPv
Removed event: probe_testbin:_ZN7Garbage4funcEiPv__return
Removed event: probe_testbin:_ZN7Garbage4funcEi__return
Added new events:
  probe_testbin:_ZN7Garbage4funcEi (on _ZN7Garbage4funcEi in /tmp/testbin)
  probe_testbin:_ZN7Garbage4funcEi__return (on _ZN7Garbage4funcEi%return in /tmp/testbin)

You can now use it in all perf tools, such as:

	perf record -e probe_testbin:_ZN7Garbage4funcEi__return -aR sleep 1

Added new events:
  probe_testbin:_ZN7Garbage4funcEiPv (on _ZN7Garbage4funcEiPv in /tmp/testbin)
  probe_testbin:_ZN7Garbage4funcEiPv__return (on _ZN7Garbage4funcEiPv%return in /tmp/testbin)

You can now use it in all perf tools, such as:

	perf record -e probe_testbin:_ZN7Garbage4funcEiPv__return -aR sleep 1

[ perf record: Woken up 1 times to write data ]
[ perf record: Captured and wrote 0.170 MB perf.data (20 samples) ]
         testbin 15211/15211 [009] 21554.551586:           probe_testbin:_ZN7Garbage4funcEi: 
         testbin 15211/15211 [009] 21554.551646:   probe_testbin:_ZN7Garbage4funcEi__return: 
         testbin 15211/15211 [009] 21554.551650:         probe_testbin:_ZN7Garbage4funcEiPv: 
         testbin 15211/15211 [009] 21556.553685: probe_testbin:_ZN7Garbage4funcEiPv__return: 
         testbin 15211/15211 [009] 21556.553699:         probe_testbin:_ZN7Garbage4funcEiPv: 
         testbin 15211/15211 [009] 21558.556040: probe_testbin:_ZN7Garbage4funcEiPv__return: 
         testbin 15211/15211 [009] 21558.556065:         probe_testbin:_ZN7Garbage4funcEiPv: 
         testbin 15211/15211 [009] 21560.558114: probe_testbin:_ZN7Garbage4funcEiPv__return: 
         testbin 15211/15211 [009] 21560.558125:         probe_testbin:_ZN7Garbage4funcEiPv: 
         testbin 15211/15211 [009] 21562.560209: probe_testbin:_ZN7Garbage4funcEiPv__return:
```

Note that this is just a janky example of how you can build abstractions atop this infrastructure, it doesn't handle a couple of things:

- The `perf probe` command will fail if a mangled name is too long, or .For such cases, this abstraction should be updated to add probes via function addresses and aliases rather than mangled names directly, eg:

```sh
# This can be an incrementing integer that is correlated to the original order
# of probe event registration by postprocessing the `perf script` output
# Example, if a function was registered with the alias of "1", state can be
# maintained to make back `probe_testbin:1` to the actual function name
func_alias="alias_for_func"
addr="0x000000000000117e"

perf probe \
    --exec "$EXE" \
    --no-demangle \
    --add "${func_alias}=${addr}" \
    --add "${func_alias}=${addr}%return"
```

- It is not possible to directly comprehend the runtime of recursive function calls, since the output would be in the "arrow" pattern:

```sh
testbin 12809/12809 [010] 21286.964017:           probe_testbin:_ZN7Garbage4funcEi: # Call 1
testbin 12809/12809 [010] 21286.964031:           probe_testbin:_ZN7Garbage4funcEi: # Call 2
testbin 12809/12809 [010] 21286.964036:           probe_testbin:_ZN7Garbage4funcEi: # Call 3
testbin 12809/12809 [010] 21286.964041:           probe_testbin:_ZN7Garbage4funcEi: # Call 4
testbin 12809/12809 [010] 21286.964045:           probe_testbin:_ZN7Garbage4funcEi: # Call 5
testbin 12809/12809 [010] 21286.964050:           probe_testbin:_ZN7Garbage4funcEi: # Call 6
testbin 12809/12809 [010] 21286.964057:   probe_testbin:_ZN7Garbage4funcEi__return: # Ret 6
testbin 12809/12809 [010] 21286.964061:   probe_testbin:_ZN7Garbage4funcEi__return: # Ret 5
testbin 12809/12809 [010] 21286.964066:   probe_testbin:_ZN7Garbage4funcEi__return: # Ret 4
testbin 12809/12809 [010] 21286.964070:   probe_testbin:_ZN7Garbage4funcEi__return: # Ret 3
testbin 12809/12809 [010] 21286.964074:   probe_testbin:_ZN7Garbage4funcEi__return: # Ret 2
testbin 12809/12809 [010] 21286.964078:   probe_testbin:_ZN7Garbage4funcEi__return: # Ret 1
```

So again, you'd need to build your own abstraction to correlate this type of output to the actual function invocation (hints in the "Call" and "Ret" comments)
