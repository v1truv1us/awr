const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── nghttp2 prefix ────────────────────────────────────────────────────
    // Resolve via `brew --prefix nghttp2` at build time, falling back to the
    // common Homebrew path on Apple Silicon.
    const nghttp2_prefix = b.option(
        []const u8,
        "nghttp2-prefix",
        "Path to nghttp2 installation (default: /opt/homebrew/opt/nghttp2)",
    ) orelse "/opt/homebrew/opt/nghttp2";

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
        .{ .name = "h2session",   .src = "src/net/h2session.zig" },
    };

    const test_step     = b.step("test",     "Run all unit tests");
    const test_net_step = b.step("test-net", "Run src/net unit tests");

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

        // h2session links nghttp2 and compiles the C shim
        if (std.mem.eql(u8, m.name, "h2session")) {
            // Compile the C shim with access to nghttp2 headers
            const nghttp2_include = b.pathJoin(&.{ nghttp2_prefix, "include" });
            t.addCSourceFile(.{
                .file  = b.path("src/net/h2_shim.c"),
                .flags = &.{
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    b.fmt("-I{s}", .{nghttp2_include}),
                },
            });
            t.addIncludePath(.{ .cwd_relative = nghttp2_include });
            t.addIncludePath(b.path("src/net")); // for h2_shim.h

            // Link nghttp2
            const nghttp2_lib = b.pathJoin(&.{ nghttp2_prefix, "lib" });
            t.addLibraryPath(.{ .cwd_relative = nghttp2_lib });
            t.linkSystemLibrary("nghttp2");
            t.linkLibC();
        }

        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        test_net_step.dependOn(&run_t.step);
    }
}
