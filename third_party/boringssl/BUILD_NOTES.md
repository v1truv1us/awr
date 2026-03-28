# BoringSSL Build Notes

Vendored commit: see `COMMIT_HASH` file.
Platform in this commit: **macOS arm64**.

## Prerequisites

```
brew install cmake ninja go
```

Go is required by BoringSSL's assembly code generator.

## Build steps

```bash
git clone https://boringssl.googlesource.com/boringssl /tmp/boringssl-src
cd /tmp/boringssl-src
# Optional: pin to the commit in COMMIT_HASH
# git checkout $(cat /path/to/awr/third_party/boringssl/COMMIT_HASH)

mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release -GNinja ..
ninja ssl crypto
```

## Copy outputs

```bash
REPO=/path/to/awr
PLATFORM=macos-arm64   # or macos-x86_64, linux-x86_64

cp /tmp/boringssl-src/build/libssl.a    $REPO/third_party/boringssl/lib/$PLATFORM/
cp /tmp/boringssl-src/build/libcrypto.a $REPO/third_party/boringssl/lib/$PLATFORM/
cp -r /tmp/boringssl-src/include/openssl $REPO/third_party/boringssl/include/
cd /tmp/boringssl-src && git rev-parse HEAD > $REPO/third_party/boringssl/COMMIT_HASH
```

## Adding a new platform

Create `lib/<new-platform>/` and repeat the build steps on the target machine.
Update `build.zig` to detect the platform via `b.host.result.cpu.arch` and select
the correct lib subdirectory.
