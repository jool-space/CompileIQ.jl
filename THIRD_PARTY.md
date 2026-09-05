# NVIDIA CompileIQ core

The Julia code in this repository is covered by the MIT license in `LICENSE`.
The NVIDIA optimizer is downloaded separately and is governed by the
[NVIDIA CompileIQ license](https://github.com/NVIDIA/CompileIQ/blob/main/LICENSE).
Use of the optimizer is subject to those terms. Its license and third-party
notices are preserved as `LICENSE` and `NOTICE` alongside the installed files.

`search` and `CompileIQ.sample` are Julia functions. Both launch the same
optimizer subprocess. `search` evaluates proposed candidates with a Julia
objective and sends their scores back; `sample` receives candidates and stops.
Neither function is a separate binary.

On first use, the client downloads the pinned NVIDIA `compileiq` wheel directly
from PyPI, verifies its SHA-256, and creates a local Julia artifact containing:

```text
bin/_core            optimizer executable
bin/core             upstream shell launcher
lib/libciq.so        companion shared library
core-manifest.json   upstream build metadata
LICENSE              NVIDIA license
NOTICE               third-party notices
```

A wheel is a ZIP archive. It also contains the Python client and Python package
metadata; this Julia client only extracts the core and its accompanying files.
It launches `bin/_core` directly with `lib/` on `LD_LIBRARY_PATH`. Python is
not required. The executable and library must be installed together.

The artifact lives in the user's Julia depot. A hash-only `Artifacts.toml`
binding lives in CompileIQ's scratch space, separately for each core version
and architecture. No downloadable artifact metadata or NVIDIA binaries are
published by this repository. This uses Julia's artifact storage without
publishing the core through a JLL or Julia's package servers.

Loading the package and querying `core_available()` or `versioninfo()` does not
download the core. The first search or sample installs it as needed; call
`CompileIQ.install_core!()` to prefetch it for offline use. Existing `core`
preferences, `COMPILEIQ_CORE` overrides, and legacy scratch installs remain
usable. No change to the MIT license grants redistribution rights over the core.

Run `julia --project=. examples/automatic_core.jl` for a small numeric sampling
and search example using the real core, without compiling or launching a GPU
kernel. It prints whether the core was already installed and its resolved path.
