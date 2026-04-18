const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Test steps ────────────────────────────────────────────────────────
    // "zig build test"     → run all tests (net + client)
    // "zig build test-net" → net-layer only

    const net_modules = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "fingerprint", .src = "src/net/fingerprint.zig" },
        .{ .name = "cookie",      .src = "src/net/cookie.zig"      },
        .{ .name = "http1",       .src = "src/net/http1.zig"       },
        .{ .name = "http2",       .src = "src/net/http2.zig"       },
        .{ .name = "pool",        .src = "src/net/pool.zig"        },
        .{ .name = "tls",         .src = "src/net/tls.zig"         },
        .{ .name = "tcp",         .src = "src/net/tcp.zig"         },
        .{ .name = "url",         .src = "src/net/url.zig"         },
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
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        test_net_step.dependOn(&run_t.step);
    }

    // ── client.zig — imports net modules via relative @import paths ───────
    // Zig resolves @import("net/http1.zig") relative to src/client.zig, so
    // all transitive files are included automatically.
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target   = target,
        .optimize = optimize,
    });
    const client_t = b.addTest(.{
        .name        = "client",
        .root_module = client_mod,
    });
    const run_client_t = b.addRunArtifact(client_t);
    test_step.dependOn(&run_client_t.step);
}
