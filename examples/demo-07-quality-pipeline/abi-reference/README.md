# ABI reference

This directory holds the "frozen" ABI snapshot for `libdemo07_channel.so.1`.
Once a `libdemo07_channel.so.1.abi` file is committed here, the `abi`
stage of the Containerfile runs `abidiff` against it on every build —
any change to a public header that affects ABI causes the build to fail
visibly.

## Bootstrap workflow (first time only)

The repository ships without a committed baseline so the first time you
run the demo, the `abi` stage just records the current ABI. Two commands
to promote it to the official baseline:

```bash
./demo.sh --abi-only       # produces reports/current.abi
./demo.sh --abi-bless      # copies it to abi-reference/
git add abi-reference/
git commit -m "abi: bless v1.0 baseline"
```

That's the entire workflow.

## How regressions get caught

After the baseline is committed, the `abi` stage of `Containerfile` runs:

```dockerfile
abidiff abi-reference/libdemo07_channel.so.1.abi reports/current.abi
```

This catches the classic ABI hazards:

- adding/removing/reordering fields in a struct that crosses the .so boundary
- changing the size or alignment of any exported type
- adding/removing virtual methods (vtable layout)
- changing const-ness, reference, or noexcept on an exported method
- changing the mangled name of an exported symbol

If any of these happen, `abidiff` exits non-zero, the build fails, and
the `reports/abidiff.txt` report shows exactly what changed.

The tutorial uses a deliberate ABI break (adding a field to `Greeting`)
to demonstrate this — see `./demo.sh --abi-break-demo` (Round B).

## Updating the baseline intentionally

When a public-header change is intentional and you mean to ship a new
ABI version, repeat the bootstrap workflow:

```bash
./demo.sh --abi-only          # records the new shape
./demo.sh --abi-bless         # promotes it
git add abi-reference/
git commit -m "abi: bump v2 — added Greeting::timestamp field"
```

You should bump the soname (`SOVERSION` in `CMakeLists.txt`) at the same
time so downstream consumers know to recompile. Bumping just the ABI
file without bumping the soname is what breaks consumers silently —
abidiff catches the technical change, soname signals it to dlopen() and
package managers.

## Further reading

- [libabigail documentation](https://sourceware.org/libabigail/) — the
  underlying tool
- KDE Frameworks' [Binary Compatibility/Issues With C++](https://community.kde.org/Policies/Binary_Compatibility_Issues_With_C%2B%2B)
  — the canonical practitioner's reference for what does and doesn't
  break ABI
