const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── nghttp2 paths (brew install libnghttp2) ───────────────────────────
    const nghttp2_prefix = "/opt/homebrew/opt/libnghttp2";
    const nghttp2_include = b.path("src/net"); // for h2_shim.h
    const nghttp2_sys_include = std.Build.LazyPath{ .cwd_relative = nghttp2_prefix ++ "/include" };
    const nghttp2_lib = std.Build.LazyPath{ .cwd_relative = nghttp2_prefix ++ "/lib" };

    // ── Net layer modules (pure-Zig, no C deps) ───────────────────────────
    const net_modules = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "fingerprint", .src = "src/net/fingerprint.zig" },
        .{ .name = "cookie",      .src = "src/net/cookie.zig" },
        .{ .name = "http1",       .src = "src/net/http1.zig" },
        .{ .name = "http2",       .src = "src/net/http2.zig" },
        .{ .name = "pool",        .src = "src/net/pool.zig" },
        .{ .name = "tls",         .src = "src/net/tls.zig" },
        .{ .name = "tcp",         .src = "src/net/tcp.zig" },
        .{ .name = "url",         .src = "src/net/url.zig" },
    };

    // ── Test steps ────────────────────────────────────────────────────────
    // "zig build test"        → run all tests (net + client)
    // "zig build test-net"    → net layer only
    // "zig build test-client" → client layer only

    const test_step        = b.step("test",        "Run all unit tests");
    const test_net_step    = b.step("test-net",    "Run src/net unit tests");
    const test_client_step = b.step("test-client", "Run src/client unit tests");

    for (net_modules) |m| {
        const mod = b.createModule(.{
            .root_source_file = b.path(m.src),
            .target   = target,
            .optimize = optimize,
        });
        const t = b.addTest(.{
            .name        = m.name,
            .root_module = mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        test_net_step.dependOn(&run_t.step);
    }

    // ── h2session module (needs C shim + nghttp2) ─────────────────────────
    {
        const h2mod = b.createModule(.{
            .root_source_file = b.path("src/net/h2session.zig"),
            .target   = target,
            .optimize = optimize,
        });
        const h2test = b.addTest(.{
            .name        = "h2session",
            .root_module = h2mod,
        });
        h2test.linkLibC();
        h2test.addCSourceFile(.{
            .file  = b.path("src/net/h2_shim.c"),
            .flags = &.{ "-std=c11", "-Wall" },
        });
        h2test.addIncludePath(nghttp2_include);
        h2test.addIncludePath(nghttp2_sys_include);
        h2test.addLibraryPath(nghttp2_lib);
        h2test.linkSystemLibrary("nghttp2");
        const run_h2 = b.addRunArtifact(h2test);
        test_step.dependOn(&run_h2.step);
        test_net_step.dependOn(&run_h2.step);
    }

    // ── Client module ─────────────────────────────────────────────────────
    // client.zig imports net modules by relative path, so we compile it
    // with the repo root as the module root (all @import paths resolve
    // relative to src/client.zig).
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target   = target,
        .optimize = optimize,
    });
    const client_test = b.addTest(.{
        .name        = "client",
        .root_module = client_mod,
    });
    const run_client = b.addRunArtifact(client_test);
    test_step.dependOn(&run_client.step);
    test_client_step.dependOn(&run_client.step);
}
