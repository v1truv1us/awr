#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

clone_or_update() {
  local dir="$1"
  local remote="$2"
  local commit="$3"

  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --tags --prune origin
  else
    mkdir -p "$(dirname "$dir")"
    git clone "$remote" "$dir"
  fi

  git -C "$dir" checkout --detach "$commit"
}

clone_or_update "$repo_root/third_party/libxev" \
  "https://github.com/mitchellh/libxev.git" \
  "a82a04eabb46b0611c72d6d0e32db2d9dcf2e745"

clone_or_update "$repo_root/third_party/zig-quickjs-ng" \
  "https://github.com/mitchellh/zig-quickjs-ng.git" \
  "eb1d44ce43fd64f8403c1a94fad242ebae04d1fb"

clone_or_update "$repo_root/third_party/quickjs-ng-quickjs" \
  "https://github.com/quickjs-ng/quickjs.git" \
  "85640f81e04bc93940acc2756c792c66076dd768"

python - <<PY
from pathlib import Path

repo_root = Path(r"""$repo_root""")
zon = repo_root / "third_party" / "zig-quickjs-ng" / "build.zig.zon"
text = zon.read_text()
text = text.replace(
    '.url = "https://github.com/quickjs-ng/quickjs/archive/85640f81e04bc93940acc2756c792c66076dd768.tar.gz",\n'
    '            .hash = "N-V-__8AAIZ_PAA7y10jIaLigzkK4qd5-jfKEoTOOfHCsIGM",',
    '.path = "../quickjs-ng-quickjs",',
)
zon.write_text(text)

build_zig = repo_root / "third_party" / "zig-quickjs-ng" / "build.zig"
build_text = build_zig.read_text()
build_text = build_text.replace("    tests.linkLibrary(lib);", "    mod.linkLibrary(lib);")
build_text = build_text.replace("    lib.linkLibC();", "    lib.root_module.link_libc = true;")
build_text = build_text.replace(
    "    lib.addIncludePath(upstream.path(\"\"));",
    "    lib.root_module.addIncludePath(upstream.path(\"\"));",
)
build_text = build_text.replace("    lib.addCSourceFiles(.{", "    lib.root_module.addCSourceFiles(.{")
build_zig.write_text(build_text)
PY

printf 'Bootstrapped dependencies:\n'
git -C "$repo_root/third_party/libxev" rev-parse --short HEAD | sed 's/^/  libxev: /'
git -C "$repo_root/third_party/zig-quickjs-ng" rev-parse --short HEAD | sed 's/^/  zig-quickjs-ng: /'
git -C "$repo_root/third_party/quickjs-ng-quickjs" rev-parse --short HEAD | sed 's/^/  quickjs-ng\/quickjs: /'
