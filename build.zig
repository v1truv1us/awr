const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Test steps ────────────────────────────────────────────────────────
    // "zig build test"     → run all net unit tests
    // "zig build test-net" → alias for net-layer only

    const net_modules = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "fingerprint", .src = "src/net/fingerprint.zig" },
        .{ .name = "cookie",      .src = "src/net/cookie.zig" },
        .{ .name = "http1",       .src = "src/net/http1.zig" },
        .{ .name = "http2",       .src = "src/net/http2.zig" },
        .{ .name = "pool",        .src = "src/net/pool.zig" },
        .{ .name = "tls",         .src = "src/net/tls.zig" },
        .{ .name = "tcp",         .src = "src/net/tcp.zig" },
    };

    const test_step     = b.step("test",     "Run all unit tests");
    const test_net_step = b.step("test-net", "Run src/net unit tests");

    for (net_modules) |m| {
        const mod = b.createModule(.{
            .root_source_file = b.path(m.src),
            .target = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{
            .name = m.name,
            .root_module = mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        test_net_step.dependOn(&run_t.step);
    }
}
