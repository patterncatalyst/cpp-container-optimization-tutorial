# Vendored single-header dependencies

This directory holds the single-header `httplib.h` from
[yhirose/cpp-httplib](https://github.com/yhirose/cpp-httplib),
vendored to keep the multi-stage container build hermetic.

To populate it:

```bash
HTTPLIB_VERSION=v0.16.0
curl -fsSL -o httplib.h \
  "https://raw.githubusercontent.com/yhirose/cpp-httplib/${HTTPLIB_VERSION}/httplib.h"
```

`demo.sh` does this automatically on first run if `httplib.h` is absent.
The version is pinned in `demo.sh` so a re-run produces a byte-identical
input to the build, which is the point of vendoring.

License: cpp-httplib is MIT-licensed; see its repo for the full text.
