# Lexbor — build instructions

AWR links against [lexbor](https://github.com/lexbor/lexbor) v2.5.0 for its
HTML5-compliant parser. On macOS lexbor is available via Homebrew
(`brew install lexbor`); on Linux it is not in Debian/Ubuntu's apt yet, so
contributors must build it from source into `/usr/local`.

## One-shot build (Linux)

Preferred (repo-managed local install, no sudo):

```bash
./scripts/bootstrap_lexbor.sh
```

This installs lexbor into `third_party/lexbor/install`, which works with:

```bash
zig build -Dlexbor-prefix=third_party/lexbor/install
```

Manual `/usr/local` install path:

```bash
git clone --depth 1 --branch v2.5.0 https://github.com/lexbor/lexbor \
    third_party/lexbor
cd third_party/lexbor
mkdir build && cd build
cmake -DLEXBOR_BUILD_STATIC=ON \
      -DLEXBOR_BUILD_SHARED=OFF \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
      ..
make -j"$(nproc)"
sudo make install
# build.zig searches for liblexbor.a — symlink the static archive:
sudo ln -sf /usr/local/lib/liblexbor_static.a /usr/local/lib/liblexbor.a
```

The cloned tree is listed in the repo's `.gitignore` (it's 59 MB). After
the install step only the compiled artifacts under `/usr/local/{include,lib}`
are needed, so the source tree may be deleted.

## Durable fix

Tracked in `DEV_NOTES.md` entry #4. Add a `-Dlexbor-prefix=<path>` build
option so contributors who already have lexbor elsewhere (Homebrew on
macOS, a custom vendored copy, etc.) can point to it without editing
`build.zig`.
