// Static replacement for the generated build_options module.
// The generated path (b.addOptions() → b.createModule()) invokes
// atomic_file.link which calls renameat2(RENAME_NOREPLACE) — rejected
// with EINVAL by v9fs (the gVisor 9p filesystem). This fallback lets
// `zig build install` succeed in containerised dev environments.
//
// Kept in sync with the git short hash at commit time; update when the
// version surfaced by `./awr --version` drifts far from HEAD.
pub const git_hash: []const u8 = "4664bf2";
