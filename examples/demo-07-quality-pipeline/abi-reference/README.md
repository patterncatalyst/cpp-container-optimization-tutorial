# ABI reference

This directory holds the "frozen" ABI snapshot for `libdemo07_channel.so.1`.

## How it gets populated

On first run of the demo, `Containerfile`'s `abi` target sees no reference
and writes the current ABI to `reports/current.abi`. Copy it here and
commit:

```bash
podman build --target abi -t cpp-tut/demo-07:abi ../
podman run --rm cpp-tut/demo-07:abi cat /src/reports/current.abi \
  > libdemo07_channel.so.1.abi
git add libdemo07_channel.so.1.abi
git commit -m "abi: snapshot v1.0 baseline"
```

## How regressions get caught

On subsequent runs, the `abi` target invokes `abidiff` against this
snapshot. Any change to a public header that affects ABI (struct
layout, virtual table, exported symbol mangling) makes `abidiff` exit
non-zero. The tutorial walks through deliberately breaking ABI by
adding a field to `Greeting` to demonstrate the failure.

For deeper coverage of what counts as ABI breakage, see
[libabigail's documentation](https://sourceware.org/libabigail/).
