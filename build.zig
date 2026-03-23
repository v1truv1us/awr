const std = @import("std");

const TlsBackend = enum { stub, std, curl_impersonate };

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── TLS backend option ──────────────────────────────────────────────────
    const tls_backend = b.option(TlsBackend, "tls-backend", "TLS implementation backend (default: stub)") orelse .stub;
    const curl_impersonate_prefix = b.option([]const u8, "curl-impersonate-prefix", "Install prefix for curl-impersonate");

    // ── Build options shared with Zig modules ──────────────────────────────
    const build_opts = b.addOptions();
    build_opts.addOption(TlsBackend, "tls_backend", tls_backend);

    // ── libxev dependency ─────────────────────────────────────────────────
    const xev_dep = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const xev_mod = xev_dep.module("xev");

    // ── QuickJS-NG dependency ─────────────────────────────────────────────
    const qjs_dep = b.dependency("quickjs_ng", .{ .target = target, .optimize = optimize });
    const qjs_mod = qjs_dep.module("quickjs");

    // ── nghttp2 paths (brew install libnghttp2) ───────────────────────────
    const nghttp2_prefix = "/opt/homebrew/opt/libnghttp2";
    const nghttp2_include = b.path("src/net"); // for h2_shim.h
    const nghttp2_sys_include = std.Build.LazyPath{ .cwd_relative = nghttp2_prefix ++ "/include" };
    const nghttp2_lib = std.Build.LazyPath{ .cwd_relative = nghttp2_prefix ++ "/lib" };

    // ── Lexbor paths (brew install lexbor) ───────────────────────────────
    const lexbor_prefix = "/opt/homebrew/opt/lexbor";
    const lexbor_include = std.Build.LazyPath{ .cwd_relative = lexbor_prefix ++ "/include" };
    const lexbor_lib     = std.Build.LazyPath{ .cwd_relative = lexbor_prefix ++ "/lib" };

    // ── Test steps ────────────────────────────────────────────────────────
    // "zig build test"        → run all unit tests
    // "zig build test-net"    → net layer only
    // "zig build test-js"     → JS engine only
    // "zig build test-html"   → HTML parser only
    // "zig build test-dom"    → DOM layer only
    // "zig build test-client" → client layer only
    // "zig build test-h2"     → h2session + h2 frame tests
    // "zig build test-e2e"    → end-to-end integration tests (requires network)
    //
    // Production Phase 1 verification (requires curl-impersonate installed):
    //   zig build test -Dtls-backend=curl_impersonate
    //   zig build test-e2e -Dtls-backend=curl_impersonate

    const test_step        = b.step("test",        "Run all unit tests");
    const test_net_step    = b.step("test-net",    "Run src/net unit tests");
    const test_js_step     = b.step("test-js",     "Run src/js unit tests");
    const test_html_step   = b.step("test-html",   "Run src/html unit tests");
    const test_dom_step    = b.step("test-dom",    "Run src/dom unit tests");
    const test_client_step = b.step("test-client", "Run src/client unit tests");
    const test_h2_step     = b.step("test-h2",     "Run h2session and HTTP/2 frame tests");
    const test_e2e_step    = b.step("test-e2e",    "Run end-to-end integration tests (requires network)");

    // ── Net layer modules (pure-Zig, no C deps) ───────────────────────────
    const pure_net_modules = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "fingerprint", .src = "src/net/fingerprint.zig" },
        .{ .name = "cookie",      .src = "src/net/cookie.zig" },
        .{ .name = "http1",       .src = "src/net/http1.zig" },
        .{ .name = "http2",       .src = "src/net/http2.zig" },
        .{ .name = "pool",        .src = "src/net/pool.zig" },
        .{ .name = "url",         .src = "src/net/url.zig" },
    };

    for (pure_net_modules) |m| {
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
        if (std.mem.eql(u8, m.name, "http2")) test_h2_step.dependOn(&run_t.step);
    }

    // ── TLS module (depends on TLS backend) ────────────────────────────────
    {
        const tls_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tls.zig"),
            .target   = target,
            .optimize = optimize,
        });
        tls_mod.addOptions("build_opts", build_opts);

        if (tls_backend == .curl_impersonate) {
            const ci_prefix: []const u8 = curl_impersonate_prefix orelse "/usr/local";
            const ci_include = std.Build.LazyPath{
                .cwd_relative = b.fmt("{s}/include", .{ci_prefix}),
            };
            const ci_lib = std.Build.LazyPath{
                .cwd_relative = b.fmt("{s}/lib", .{ci_prefix}),
            };

            tls_mod.addIncludePath(ci_include);
            tls_mod.addLibraryPath(ci_lib);
        }

        const tls_test = b.addTest(.{
            .name        = "tls",
            .root_module = tls_mod,
        });
        if (tls_backend == .curl_impersonate) {
            const ci_prefix: []const u8 = curl_impersonate_prefix orelse "/usr/local";
            const ci_include = std.Build.LazyPath{
                .cwd_relative = b.fmt("{s}/include", .{ci_prefix}),
            };
            const ci_lib = std.Build.LazyPath{
                .cwd_relative = b.fmt("{s}/lib", .{ci_prefix}),
            };

            tls_test.linkLibC();
            tls_test.addCSourceFile(.{
                .file  = b.path("src/net/tls_curl_shim.c"),
                .flags = &.{ "-std=c11", "-Wall" },
            });
            tls_test.addIncludePath(b.path("src/net"));
            tls_test.addIncludePath(ci_include);
            tls_test.addLibraryPath(ci_lib);
            tls_test.linkSystemLibrary("curl-impersonate-chrome");
        }
        const run_tls = b.addRunArtifact(tls_test);
        test_step.dependOn(&run_tls.step);
        test_net_step.dependOn(&run_tls.step);
    }

    // ── tcp module (depends on libxev) ────────────────────────────────────
    {
        const tcp_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tcp.zig"),
            .target   = target,
            .optimize = optimize,
        });
        tcp_mod.addImport("xev", xev_mod);
        const tcp_test = b.addTest(.{
            .name        = "tcp",
            .root_module = tcp_mod,
        });
        const run_tcp = b.addRunArtifact(tcp_test);
        test_step.dependOn(&run_tcp.step);
        test_net_step.dependOn(&run_tcp.step);
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
        test_h2_step.dependOn(&run_h2.step);
    }

    // ── JS engine module (depends on quickjs-ng) ─────────────────────────
    {
        const js_mod = b.createModule(.{
            .root_source_file = b.path("src/js/engine.zig"),
            .target   = target,
            .optimize = optimize,
        });
        js_mod.addImport("quickjs", qjs_mod);

        const js_test = b.addTest(.{
            .name        = "js",
            .root_module = js_mod,
            .use_llvm    = true, // required — QuickJS-NG crashes with self-hosted backend
        });
        js_test.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        const run_js = b.addRunArtifact(js_test);
        test_step.dependOn(&run_js.step);
        test_js_step.dependOn(&run_js.step);
    }

    // ── HTML parser module (depends on lexbor) ────────────────────────────
    {
        const html_mod = b.createModule(.{
            .root_source_file = b.path("src/html/parser.zig"),
            .target   = target,
            .optimize = optimize,
        });

        const html_test = b.addTest(.{
            .name        = "html",
            .root_module = html_mod,
        });
        html_test.linkLibC();
        html_test.addIncludePath(lexbor_include);
        html_test.addLibraryPath(lexbor_lib);
        html_test.linkSystemLibrary("lexbor");
        const run_html = b.addRunArtifact(html_test);
        test_step.dependOn(&run_html.step);
        test_html_step.dependOn(&run_html.step);
    }

    // ── DOM module (depends on lexbor) ────────────────────────────────────
    {
        const dom_mod = b.createModule(.{
            .root_source_file = b.path("src/dom/node.zig"),
            .target   = target,
            .optimize = optimize,
        });

        const dom_test = b.addTest(.{
            .name        = "dom",
            .root_module = dom_mod,
        });
        dom_test.linkLibC();
        dom_test.addIncludePath(lexbor_include);
        dom_test.addLibraryPath(lexbor_lib);
        dom_test.linkSystemLibrary("lexbor");
        const run_dom = b.addRunArtifact(dom_test);
        test_step.dependOn(&run_dom.step);
        test_dom_step.dependOn(&run_dom.step);
    }

    // ── Client module ─────────────────────────────────────────────────────
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target   = target,
        .optimize = optimize,
    });
    client_mod.addImport("xev", xev_mod);
    client_mod.addOptions("build_opts", build_opts);
    const client_test = b.addTest(.{
        .name        = "client",
        .root_module = client_mod,
    });
    const run_client = b.addRunArtifact(client_test);
    test_step.dependOn(&run_client.step);
    test_client_step.dependOn(&run_client.step);

    // ── End-to-end integration tests (network required) ───────────────────
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/test_e2e.zig"),
        .target   = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("xev", xev_mod);
    e2e_mod.addOptions("build_opts", build_opts);
    const e2e_test = b.addTest(.{
        .name        = "e2e",
        .root_module = e2e_mod,
    });
    const run_e2e = b.addRunArtifact(e2e_test);
    test_e2e_step.dependOn(&run_e2e.step);
}
