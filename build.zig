const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Build options shared with Zig modules ──────────────────────────────
    // Embed git short hash for `./awr --version` → "0.0.<hash>"
    const build_opts = b.addOptions();
    const git_hash_raw = b.run(&.{ "git", "rev-parse", "--short", "HEAD" });
    const git_hash = std.mem.trim(u8, git_hash_raw, &[_]u8{ 0x20, 0x0a, 0x0d });
    build_opts.addOption([]const u8, "git_hash", git_hash);

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

    // ── BoringSSL paths (vendored in third_party/) ────────────────────────
    // Pre-built static libs for macOS/arm64. See third_party/boringssl/BUILD_NOTES.md to rebuild.
    const boringssl_include  = b.path("third_party/boringssl/include");
    const boringssl_lib_ssl  = b.path("third_party/boringssl/lib/macos-arm64/libssl.a");
    const boringssl_lib_crpt = b.path("third_party/boringssl/lib/macos-arm64/libcrypto.a");

    // ── Test steps ────────────────────────────────────────────────────────
    // "zig build test"        → run all unit tests
    // "zig build test-net"    → net layer only
    // "zig build test-js"     → JS engine only
    // "zig build test-html"   → HTML parser only
    // "zig build test-dom"    → DOM layer only
    // "zig build test-client" → client layer only
    // "zig build test-h2"     → h2session + h2 frame tests
    // "zig build test-page"   → Page type (unit + integration, requires network)
    // "zig build test-render" → structured text renderer tests
    // "zig build test-e2e"    → end-to-end integration tests (requires network)
    // "zig build test-wpt"    → curated WPT-style DOM harness tests
    // "zig build test-test262"→ curated JS conformance subset

    const test_step        = b.step("test",        "Run all unit tests");
    const test_net_step    = b.step("test-net",    "Run src/net unit tests");
    const test_js_step     = b.step("test-js",     "Run src/js unit tests");
    const test_html_step   = b.step("test-html",   "Run src/html unit tests");
    const test_dom_step    = b.step("test-dom",    "Run src/dom unit tests");
    const test_client_step = b.step("test-client", "Run src/client unit tests");
    const test_h2_step     = b.step("test-h2",     "Run h2session and HTTP/2 frame tests");
    const test_page_step   = b.step("test-page",   "Run src/page tests (unit + integration, requires network)");
    const test_tls_step    = b.step("test-tls",    "Run BoringSSL smoke + tls_conn unit tests");
    const test_render_step = b.step("test-render", "Run src/render unit tests");
    const test_e2e_step    = b.step("test-e2e",    "Run end-to-end integration tests (requires network)");
    const test_wpt_step    = b.step("test-wpt",    "Run curated WPT-style DOM tests");
    const test_test262_step = b.step("test-test262", "Run curated Test262 subset");

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
        h2test.root_module.link_libc = true;
        h2test.root_module.addCSourceFile(.{
            .file  = b.path("src/net/h2_shim.c"),
            .flags = &.{ "-std=c11", "-Wall" },
        });
        h2test.root_module.addIncludePath(nghttp2_include);
        h2test.root_module.addIncludePath(nghttp2_sys_include);
        h2test.root_module.addLibraryPath(nghttp2_lib);
        h2test.root_module.linkSystemLibrary("nghttp2", .{});
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
        js_test.root_module.linkLibrary(qjs_dep.artifact("quickjs-ng"));
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
        html_test.root_module.link_libc = true;
        html_test.root_module.addIncludePath(lexbor_include);
        html_test.root_module.addLibraryPath(lexbor_lib);
        html_test.root_module.linkSystemLibrary("lexbor", .{});
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
        dom_test.root_module.link_libc = true;
        dom_test.root_module.addIncludePath(lexbor_include);
        dom_test.root_module.addLibraryPath(lexbor_lib);
        dom_test.root_module.linkSystemLibrary("lexbor", .{});
        const run_dom = b.addRunArtifact(dom_test);
        test_step.dependOn(&run_dom.step);
        test_dom_step.dependOn(&run_dom.step);
    }

    // ── Page module (Phase 2 — wires fetch+HTML+JS) ───────────────────────
    {
        const page_mod = b.createModule(.{
            .root_source_file = b.path("src/page.zig"),
            .target   = target,
            .optimize = optimize,
        });
        // client deps
        page_mod.addImport("xev", xev_mod);
        page_mod.addIncludePath(b.path("src/net"));            // for tls_awr_shim.h, h2_shim.h
        page_mod.addIncludePath(boringssl_include);             // for openssl/*.h
        // JS engine dep
        page_mod.addImport("quickjs", qjs_mod);

        const page_test = b.addTest(.{
            .name        = "page",
            .root_module = page_mod,
            .use_llvm    = true, // required for QuickJS-NG
        });
        page_test.root_module.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        page_test.root_module.link_libc = true;
        page_test.root_module.link_libcpp = true;
        page_test.root_module.addIncludePath(lexbor_include);
        page_test.root_module.addLibraryPath(lexbor_lib);
        page_test.root_module.linkSystemLibrary("lexbor", .{});
        page_test.root_module.addCSourceFile(.{ .file = b.path("src/net/tls_awr_shim.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
        page_test.root_module.addCSourceFile(.{ .file = b.path("src/net/h2_shim.c"),     .flags = &.{ "-std=c11", "-Wall" } });
        page_test.root_module.addIncludePath(b.path("src/net"));
        page_test.root_module.addIncludePath(boringssl_include);
        page_test.root_module.addIncludePath(nghttp2_include);
        page_test.root_module.addIncludePath(nghttp2_sys_include);
        page_test.root_module.addLibraryPath(nghttp2_lib);
        page_test.root_module.linkSystemLibrary("nghttp2", .{});
        page_test.root_module.addObjectFile(boringssl_lib_ssl);
        page_test.root_module.addObjectFile(boringssl_lib_crpt);
        const run_page = b.addRunArtifact(page_test);
        test_step.dependOn(&run_page.step);
        test_page_step.dependOn(&run_page.step);
    }

    // ── Curated WPT-style DOM harness ─────────────────────────────────────
    {
        const wpt_mod = b.createModule(.{
            .root_source_file = b.path("tests/wpt_runner.zig"),
            .target   = target,
            .optimize = optimize,
        });
        const wpt_page_mod = b.createModule(.{
            .root_source_file = b.path("src/page.zig"),
            .target   = target,
            .optimize = optimize,
        });
        wpt_page_mod.addImport("xev", xev_mod);
        wpt_page_mod.addImport("quickjs", qjs_mod);
        wpt_page_mod.addIncludePath(b.path("src/net"));
        wpt_page_mod.addIncludePath(boringssl_include);
        wpt_page_mod.addIncludePath(lexbor_include);
        wpt_mod.addImport("page", wpt_page_mod);

        const wpt_test = b.addTest(.{
            .name        = "wpt",
            .root_module = wpt_mod,
            .use_llvm    = true,
        });
        wpt_test.root_module.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        wpt_test.root_module.link_libc = true;
        wpt_test.root_module.link_libcpp = true;
        wpt_test.root_module.addIncludePath(lexbor_include);
        wpt_test.root_module.addLibraryPath(lexbor_lib);
        wpt_test.root_module.linkSystemLibrary("lexbor", .{});
        wpt_test.root_module.addCSourceFile(.{ .file = b.path("src/net/tls_awr_shim.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
        wpt_test.root_module.addCSourceFile(.{ .file = b.path("src/net/h2_shim.c"),     .flags = &.{ "-std=c11", "-Wall" } });
        wpt_test.root_module.addIncludePath(b.path("src/net"));
        wpt_test.root_module.addIncludePath(boringssl_include);
        wpt_test.root_module.addIncludePath(nghttp2_include);
        wpt_test.root_module.addIncludePath(nghttp2_sys_include);
        wpt_test.root_module.addLibraryPath(nghttp2_lib);
        wpt_test.root_module.linkSystemLibrary("nghttp2", .{});
        wpt_test.root_module.addObjectFile(boringssl_lib_ssl);
        wpt_test.root_module.addObjectFile(boringssl_lib_crpt);
        const run_wpt = b.addRunArtifact(wpt_test);
        test_step.dependOn(&run_wpt.step);
        test_wpt_step.dependOn(&run_wpt.step);
    }

    // ── Render module (depends on lexbor via dom.parseDocument) ───────────
    {
        const render_mod = b.createModule(.{
            .root_source_file = b.path("src/render.zig"),
            .target   = target,
            .optimize = optimize,
        });

        const render_test = b.addTest(.{
            .name        = "render",
            .root_module = render_mod,
        });
        render_test.root_module.link_libc = true;
        render_test.root_module.addIncludePath(lexbor_include);
        render_test.root_module.addLibraryPath(lexbor_lib);
        render_test.root_module.linkSystemLibrary("lexbor", .{});
        const run_render = b.addRunArtifact(render_test);
        test_step.dependOn(&run_render.step);
        test_render_step.dependOn(&run_render.step);
    }

    // ── Curated Test262-style JS subset ───────────────────────────────────
    {
        const test262_mod = b.createModule(.{
            .root_source_file = b.path("tests/test262_runner.zig"),
            .target   = target,
            .optimize = optimize,
        });
        const js_engine_mod = b.createModule(.{
            .root_source_file = b.path("src/js/engine.zig"),
            .target   = target,
            .optimize = optimize,
        });
        js_engine_mod.addImport("quickjs", qjs_mod);
        test262_mod.addImport("engine", js_engine_mod);

        const test262_test = b.addTest(.{
            .name        = "test262",
            .root_module = test262_mod,
            .use_llvm    = true,
        });
        test262_test.root_module.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        const run_test262 = b.addRunArtifact(test262_test);
        test_step.dependOn(&run_test262.step);
        test_test262_step.dependOn(&run_test262.step);
    }

    // ── Client module ─────────────────────────────────────────────────────
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target   = target,
        .optimize = optimize,
    });
    client_mod.addImport("xev", xev_mod);
    client_mod.addIncludePath(b.path("src/net"));            // for tls_awr_shim.h, h2_shim.h
    client_mod.addIncludePath(boringssl_include);             // for openssl/*.h
    const client_test = b.addTest(.{
        .name        = "client",
        .root_module = client_mod,
    });
    client_test.root_module.link_libc = true;
    client_test.root_module.link_libcpp = true;
    client_test.root_module.addCSourceFile(.{ .file = b.path("src/net/tls_awr_shim.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    client_test.root_module.addCSourceFile(.{ .file = b.path("src/net/h2_shim.c"),     .flags = &.{ "-std=c11", "-Wall" } });
    client_test.root_module.addIncludePath(b.path("src/net"));
    client_test.root_module.addIncludePath(boringssl_include);
    client_test.root_module.addIncludePath(nghttp2_include);
    client_test.root_module.addIncludePath(nghttp2_sys_include);
    client_test.root_module.addLibraryPath(nghttp2_lib);
    client_test.root_module.linkSystemLibrary("nghttp2", .{});
    client_test.root_module.addObjectFile(boringssl_lib_ssl);
    client_test.root_module.addObjectFile(boringssl_lib_crpt);
    const run_client = b.addRunArtifact(client_test);
    test_step.dependOn(&run_client.step);
    test_client_step.dependOn(&run_client.step);

    // ── AWR executable ───────────────────────────────────────────────────────
    {
        // Share one options module instance to avoid "file exists in two modules" error
        const opts_mod = build_opts.createModule();

        const exe_page_mod = b.createModule(.{
            .root_source_file = b.path("src/page.zig"),
            .target   = target,
            .optimize = optimize,
        });
        exe_page_mod.addImport("xev", xev_mod);
        exe_page_mod.addImport("build_opts", opts_mod);
        exe_page_mod.addImport("quickjs", qjs_mod);
        exe_page_mod.addIncludePath(b.path("src/net"));            // for tls_awr_shim.h, h2_shim.h
        exe_page_mod.addIncludePath(boringssl_include);             // for openssl/*.h
        exe_page_mod.addIncludePath(lexbor_include);                // for lexbor/html/html.h

        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target   = target,
            .optimize = optimize,
        });
        exe_mod.addImport("page", exe_page_mod);
        exe_mod.addImport("build_opts", opts_mod);

        const exe = b.addExecutable(.{
            .name        = "awr",
            .root_module = exe_mod,
            .use_llvm    = true,
        });
        exe.root_module.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        exe.root_module.link_libc = true;
        exe.root_module.link_libcpp = true;
        exe.root_module.addIncludePath(lexbor_include);
        exe.root_module.addLibraryPath(lexbor_lib);
        exe.root_module.linkSystemLibrary("lexbor", .{});
        exe.root_module.addIncludePath(b.path("src/net"));
        exe.root_module.addIncludePath(boringssl_include);
        exe.root_module.addCSourceFile(.{
            .file  = b.path("src/net/tls_awr_shim.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
        });
        exe.root_module.addCSourceFile(.{
            .file  = b.path("src/net/h2_shim.c"),
            .flags = &.{ "-std=c11", "-Wall" },
        });
        exe.root_module.addIncludePath(nghttp2_include);
        exe.root_module.addIncludePath(nghttp2_sys_include);
        exe.root_module.addLibraryPath(nghttp2_lib);
        exe.root_module.linkSystemLibrary("nghttp2", .{});
        exe.root_module.addObjectFile(boringssl_lib_ssl);
        exe.root_module.addObjectFile(boringssl_lib_crpt);
        b.installArtifact(exe);
    }

    // ── BoringSSL smoke test (confirms libs link + headers resolve) ───────
    {
        const tls_smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tls_smoke_test.zig"),
            .target   = target,
            .optimize = optimize,
        });
        const tls_smoke = b.addTest(.{
            .name        = "tls",
            .root_module = tls_smoke_mod,
        });
        tls_smoke.root_module.link_libc = true;
        tls_smoke.root_module.link_libcpp = true;
        tls_smoke.root_module.addIncludePath(boringssl_include);
        tls_smoke.root_module.addObjectFile(boringssl_lib_ssl);
        tls_smoke.root_module.addObjectFile(boringssl_lib_crpt);
        const run_tls_smoke = b.addRunArtifact(tls_smoke);
        test_tls_step.dependOn(&run_tls_smoke.step);
        test_step.dependOn(&run_tls_smoke.step);
    }

    // ── tls_conn module (BoringSSL Zig wrapper + shim) ────────────────────
    {
        const tls_conn_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tls_conn.zig"),
            .target   = target,
            .optimize = optimize,
        });
        tls_conn_mod.addIncludePath(b.path("src/net")); // for tls_awr_shim.h
        tls_conn_mod.addIncludePath(boringssl_include);
        const tls_conn_test = b.addTest(.{
            .name        = "tls_conn",
            .root_module = tls_conn_mod,
        });
        tls_conn_test.root_module.link_libc = true;
        tls_conn_test.root_module.link_libcpp = true;
        tls_conn_test.root_module.addCSourceFile(.{
            .file  = b.path("src/net/tls_awr_shim.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
        });
        tls_conn_test.root_module.addIncludePath(b.path("src/net"));
        tls_conn_test.root_module.addIncludePath(boringssl_include);
        tls_conn_test.root_module.addObjectFile(boringssl_lib_ssl);
        tls_conn_test.root_module.addObjectFile(boringssl_lib_crpt);
        const run_tls_conn = b.addRunArtifact(tls_conn_test);
        test_tls_step.dependOn(&run_tls_conn.step);
        test_step.dependOn(&run_tls_conn.step);
    }

    // ── End-to-end integration tests (network required) ───────────────────
    // client.zig now imports tls_conn.zig (BoringSSL) and h2session.zig (nghttp2),
    // so test-e2e needs the same C deps as test-client.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/test_e2e.zig"),
        .target   = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("xev", xev_mod);
    e2e_mod.addIncludePath(b.path("src/net"));   // for tls_awr_shim.h, h2_shim.h
    e2e_mod.addIncludePath(boringssl_include);    // for openssl/*.h
    const e2e_test = b.addTest(.{
        .name        = "e2e",
        .root_module = e2e_mod,
    });
    e2e_test.root_module.link_libc = true;
    e2e_test.root_module.link_libcpp = true;
    e2e_test.root_module.addCSourceFile(.{ .file = b.path("src/net/tls_awr_shim.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra" } });
    e2e_test.root_module.addCSourceFile(.{ .file = b.path("src/net/h2_shim.c"),     .flags = &.{ "-std=c11", "-Wall" } });
    e2e_test.root_module.addIncludePath(b.path("src/net"));
    e2e_test.root_module.addIncludePath(boringssl_include);
    e2e_test.root_module.addIncludePath(nghttp2_include);
    e2e_test.root_module.addIncludePath(nghttp2_sys_include);
    e2e_test.root_module.addLibraryPath(nghttp2_lib);
    e2e_test.root_module.linkSystemLibrary("nghttp2", .{});
    e2e_test.root_module.addObjectFile(boringssl_lib_ssl);
    e2e_test.root_module.addObjectFile(boringssl_lib_crpt);
    const run_e2e = b.addRunArtifact(e2e_test);
    test_e2e_step.dependOn(&run_e2e.step);
}
