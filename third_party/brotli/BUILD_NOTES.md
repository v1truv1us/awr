# Brotli Build Notes

Vendored decoder for `Content-Encoding: br` HTTP responses (T3).

- **Source:** Homebrew `brotli` 1.2.0 (`/opt/homebrew/Cellar/brotli/1.2.0`),
  itself built from <https://github.com/google/brotli>.
- **Platform in this commit:** macOS arm64.
- **Archives:** `lib/macos-arm64/libbrotlidec.a` (decoder) +
  `libbrotlicommon.a` (shared tables/dictionary). The decoder archive depends
  on the common archive, so it must be linked first.
- **Headers:** `include/brotli/{decode.h,types.h,port.h,shared_dictionary.h}`,
  vendored for reference. AWR calls the decoder via `extern` declarations in
  `src/client.zig` (no `@cImport`, no C shim), so the headers are not on the
  compile path today.

## Rebuild / refresh

```
brew install brotli            # or build google/brotli from source
cp -L $(brew --prefix brotli)/lib/libbrotlidec.a \
      $(brew --prefix brotli)/lib/libbrotlicommon.a \
      third_party/brotli/lib/macos-arm64/
cp -L $(brew --prefix brotli)/include/brotli/*.h \
      third_party/brotli/include/brotli/
```

## Encoder not vendored

Only the decoder is needed (AWR never sends Brotli request bodies).
`libbrotlienc.a` is intentionally omitted.

## Future follow-up

A pure-Zig brotli decoder would remove this C dependency and make `awr` a
single self-contained binary on this path. Out of scope for T3; the vendored
reference decoder is the correct, low-risk first step (consistent with the
vendored BoringSSL/nghttp2/lexbor C dependencies).
