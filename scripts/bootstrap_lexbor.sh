#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lexbor_src="$repo_root/third_party/lexbor/src"
lexbor_build="$repo_root/third_party/lexbor/build"
lexbor_prefix="${LEXBOR_PREFIX:-$repo_root/third_party/lexbor/install}"

if [[ ! -d "$lexbor_src/.git" ]]; then
  mkdir -p "$(dirname "$lexbor_src")"
  git clone --depth 1 --branch v2.5.0 https://github.com/lexbor/lexbor "$lexbor_src"
else
  git -C "$lexbor_src" fetch --tags --prune origin
  git -C "$lexbor_src" checkout v2.5.0
  git -C "$lexbor_src" reset --hard v2.5.0
fi

cmake -S "$lexbor_src" -B "$lexbor_build" \
  -DLEXBOR_BUILD_STATIC=ON \
  -DLEXBOR_BUILD_SHARED=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$lexbor_prefix"

cmake --build "$lexbor_build" --parallel
cmake --install "$lexbor_build"

if [[ -f "$lexbor_prefix/lib/liblexbor_static.a" ]]; then
  ln -sf "$lexbor_prefix/lib/liblexbor_static.a" "$lexbor_prefix/lib/liblexbor.a"
fi

printf 'Lexbor installed at: %s\n' "$lexbor_prefix"
