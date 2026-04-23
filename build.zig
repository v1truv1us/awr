const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Build options shared with Zig modules ──────────────────────────────
    // Historically we built this via `b.addOptions()` + git rev-parse, but
    // that path goes through atomic_file.link → renameat2(RENAME_NOREPLACE),
    // which v9fs (gVisor's 9p FS) rejects with EINVAL. The static module at
    // src/build_opts.zig serves the same role with no runtime fs gymnastics;
    // update the hash literal in that file at release time.
    // TODO(platform): restore addOptions() once the container FS supports
    // renameat2 flags, or add a `-Dgit-hash=<hash>` cli option as an
    // ergonomic alternative for CI builds.
    const opts_mod = b.createModule(.{
        .root_source_file = b.path("src/build_opts.zig"),
        .target   = target,
        .optimize = optimize,
    });

    // ── libxev dependency ─────────────────────────────────────────────────
    const xev_dep = b.dependency("libxev", .{ .target = target, .optimize = optimize });
    const xev_mod = xev_dep.module("xev");

    // ── QuickJS-NG dependency ─────────────────────────────────────────────
    const qjs_dep = b.dependency("quickjs_ng", .{ .target = target, .optimize = optimize });
    const qjs_mod = qjs_dep.module("quickjs");

    // ── Platform-specific library paths ────────────────────────────────────
    // Defaults: macOS uses Homebrew's /opt/homebrew, Linux uses system paths
    // that Debian/Ubuntu install into (plus /usr/local for source builds of
    // libraries that don't ship in apt).
    const host_os = @import("builtin").target.os.tag;
    const is_mac  = host_os == .macos;
    const lexbor_prefix_opt = b.option([]const u8, "lexbor-prefix", "Install prefix containing lexbor include/ and lib/");

    const nghttp2_include_sys: std.Build.LazyPath = if (is_mac)
        .{ .cwd_relative = "/opt/homebrew/opt/libnghttp2/include" }
    else
        .{ .cwd_relative = "/usr/include" };
    const nghttp2_lib: std.Build.LazyPath = if (is_mac)
        .{ .cwd_relative = "/opt/homebrew/opt/libnghttp2/lib" }
    else
        .{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" };
    const nghttp2_include = b.path("src/net"); // for h2_shim.h

    const lexbor_prefix = lexbor_prefix_opt orelse if (is_mac)
        "/opt/homebrew/opt/lexbor"
    else
        "/usr/local";
    const lexbor_include: std.Build.LazyPath =
        .{ .cwd_relative = b.fmt("{s}/include", .{lexbor_prefix}) };
    const lexbor_lib: std.Build.LazyPath =
        .{ .cwd_relative = b.fmt("{s}/lib", .{lexbor_prefix}) };

    // ── BoringSSL paths (vendored in third_party/) ────────────────────────
    // Pre-built static libs for macOS/arm64. See third_party/boringssl/BUILD_NOTES.md to rebuild.
    const boringssl_include  = b.path("third_party/boringssl/include");
    const boringssl_lib_ssl  = b.path("third_party/boringssl/lib/macos-arm64/libssl.a");
    const boringssl_lib_crpt = b.path("third_party/boringssl/lib/macos-arm64/libcrypto.a");

    // ── Test steps ────────────────────────────────────────────────────────
    const test_step        = b.step("test",        "Run all unit tests");
    const test_net_step    = b.step("test-net",    "Run src/net unit tests");
    const test_js_step     = b.step("test-js",     "Run src/js unit tests");
    const test_html_step   = b.step("test-html",   "Run src/html unit tests");
    const test_dom_step    = b.step("test-dom",    "Run src/dom unit tests");
    const test_client_step = b.step("test-client", "Run src/client unit tests");
    const test_h2_step     = b.step("test-h2",     "Run h2session and HTTP/2 frame tests");
    const test_page_step   = b.step("test-page",   "Run src/page tests (unit + integration, requires network)");
    const test_tls_step    = b.step("test-tls",    "Run BoringSSL smoke + tls_conn unit tests");
    const test_e2e_step    = b.step("test-e2e",    "Run end-to-end integration tests (requires network)");
    const test_wpt_step    = b.step("test-wpt",    "Run curated WPT browser-runtime tests");
    const test_test262_step = b.step("test-test262", "Run curated Test262 JS runtime tests");

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
            .link_libc = true,
        });
        h2mod.addCSourceFile(.{
            .file  = b.path("src/net/h2_shim.c"),
            .flags = &.{ "-std=c11", "-Wall" },
        });
        h2mod.addIncludePath(nghttp2_include);
        h2mod.addIncludePath(nghttp2_include_sys);
        h2mod.addLibraryPath(nghttp2_lib);
        h2mod.linkSystemLibrary("nghttp2", .{});
        const h2test = b.addTest(.{
            .name        = "h2session",
            .root_module = h2mod,
        });
        const run_h2 = b.addRunArtifact(h2test);
        test_step.dependOn(&run_h2.step);
        test_net_step.dependOn(&run_h2.step);
        test_h2_step.dependOn(&run_h2.step);
    }

    // ── JS engine module (depends on quickjs-ng + libxev) ─────────────────
    {
        const js_mod = b.createModule(.{
            .root_source_file = b.path("src/js/engine.zig"),
            .target   = target,
            .optimize = optimize,
        });
        js_mod.addImport("quickjs", qjs_mod);
        js_mod.addImport("xev", xev_mod);
        js_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));

        const js_test = b.addTest(.{
            .name        = "js",
            .root_module = js_mod,
            .use_llvm    = true, // required — QuickJS-NG crashes with self-hosted backend
        });
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
            .link_libc = true,
        });
        html_mod.addIncludePath(lexbor_include);
        html_mod.addLibraryPath(lexbor_lib);
        html_mod.linkSystemLibrary("lexbor", .{});

        const html_test = b.addTest(.{
            .name        = "html",
            .root_module = html_mod,
        });
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
            .link_libc = true,
        });
        dom_mod.addIncludePath(lexbor_include);
        dom_mod.addLibraryPath(lexbor_lib);
        dom_mod.linkSystemLibrary("lexbor", .{});

        const dom_test = b.addTest(.{
            .name        = "dom",
            .root_module = dom_mod,
        });
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
            .link_libc = true,
        });
        page_mod.addImport("xev", xev_mod);
        page_mod.addImport("quickjs", qjs_mod);
        page_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        page_mod.addIncludePath(lexbor_include);
        page_mod.addLibraryPath(lexbor_lib);
        page_mod.linkSystemLibrary("lexbor", .{});

        const page_test = b.addTest(.{
            .name        = "page",
            .root_module = page_mod,
            .use_llvm    = true, // required for QuickJS-NG
        });
        const run_page = b.addRunArtifact(page_test);
        test_step.dependOn(&run_page.step);
        test_page_step.dependOn(&run_page.step);
    }

    // ── Client module ─────────────────────────────────────────────────────
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target   = target,
        .optimize = optimize,
    });
    client_mod.addImport("xev", xev_mod);
    const client_test = b.addTest(.{
        .name        = "client",
        .root_module = client_mod,
    });
    const run_client = b.addRunArtifact(client_test);
    test_step.dependOn(&run_client.step);
    test_client_step.dependOn(&run_client.step);

    // ── AWR executable ───────────────────────────────────────────────────────
    {
        // Share one options module instance to avoid "file exists in two modules" error

        const exe_page_mod = b.createModule(.{
            .root_source_file = b.path("src/page.zig"),
            .target   = target,
            .optimize = optimize,
            .link_libc = true,
        });
        exe_page_mod.addImport("xev", xev_mod);
        exe_page_mod.addImport("build_opts", opts_mod);
        exe_page_mod.addImport("quickjs", qjs_mod);
        exe_page_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        exe_page_mod.addIncludePath(lexbor_include);
        exe_page_mod.addLibraryPath(lexbor_lib);
        exe_page_mod.linkSystemLibrary("lexbor", .{});

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
        b.installArtifact(exe);
    }

    // ── BoringSSL smoke test (confirms libs link + headers resolve) ───────
    // macOS-only: vendored BoringSSL static libs are macos-arm64 only.
    if (is_mac) {
        const tls_smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tls_smoke_test.zig"),
            .target   = target,
            .optimize = optimize,
            .link_libc   = true,
            .link_libcpp = true, // BoringSSL is C++ (std::variant, exceptions, vtables)
        });
        tls_smoke_mod.addCSourceFile(.{
            .file  = b.path("src/net/tls_awr_shim.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
        });
        tls_smoke_mod.addIncludePath(b.path("src/net"));
        tls_smoke_mod.addIncludePath(boringssl_include);
        tls_smoke_mod.addObjectFile(boringssl_lib_ssl);
        tls_smoke_mod.addObjectFile(boringssl_lib_crpt);

        const tls_smoke = b.addTest(.{
            .name        = "tls",
            .root_module = tls_smoke_mod,
        });
        const run_tls_smoke = b.addRunArtifact(tls_smoke);
        test_tls_step.dependOn(&run_tls_smoke.step);
        test_step.dependOn(&run_tls_smoke.step);

        // ── tls_conn module (BoringSSL Zig wrapper + shim) ────────────────
        const tls_conn_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tls_conn.zig"),
            .target   = target,
            .optimize = optimize,
            .link_libc   = true,
            .link_libcpp = true,
        });
        tls_conn_mod.addCSourceFile(.{
            .file  = b.path("src/net/tls_awr_shim.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
        });
        tls_conn_mod.addIncludePath(b.path("src/net"));
        tls_conn_mod.addIncludePath(boringssl_include);
        tls_conn_mod.addObjectFile(boringssl_lib_ssl);
        tls_conn_mod.addObjectFile(boringssl_lib_crpt);

        const tls_conn_test = b.addTest(.{
            .name        = "tls_conn",
            .root_module = tls_conn_mod,
        });
        const run_tls_conn = b.addRunArtifact(tls_conn_test);
        test_tls_step.dependOn(&run_tls_conn.step);
        test_step.dependOn(&run_tls_conn.step);
    }

    // ── End-to-end integration tests (network required) ───────────────────
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/test_e2e.zig"),
        .target   = target,
        .optimize = optimize,
    });
    e2e_mod.addImport("xev", xev_mod);
    const e2e_test = b.addTest(.{
        .name        = "e2e",
        .root_module = e2e_mod,
    });
    const run_e2e = b.addRunArtifact(e2e_test);
    test_e2e_step.dependOn(&run_e2e.step);

    // ── Curated WPT runner ────────────────────────────────────────────────
    {
        const wpt_mod = b.createModule(.{
            .root_source_file = b.path("tests/wpt_runner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        wpt_mod.addImport("xev", xev_mod);
        wpt_mod.addImport("quickjs", qjs_mod);
        wpt_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        wpt_mod.addIncludePath(lexbor_include);
        wpt_mod.addLibraryPath(lexbor_lib);
        wpt_mod.linkSystemLibrary("lexbor", .{});

        const page_import = b.createModule(.{
            .root_source_file = b.path("src/page.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        page_import.addImport("xev", xev_mod);
        page_import.addImport("quickjs", qjs_mod);
        page_import.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        page_import.addIncludePath(lexbor_include);
        page_import.addLibraryPath(lexbor_lib);
        page_import.linkSystemLibrary("lexbor", .{});
        wpt_mod.addImport("page", page_import);

        const wpt_test = b.addTest(.{
            .name = "wpt",
            .root_module = wpt_mod,
            .use_llvm = true,
        });
        const run_wpt = b.addRunArtifact(wpt_test);
        test_wpt_step.dependOn(&run_wpt.step);
        test_step.dependOn(&run_wpt.step);
    }

    // ── Curated Test262 runner ────────────────────────────────────────────
    {
        const test262_mod = b.createModule(.{
            .root_source_file = b.path("tests/test262_runner.zig"),
            .target = target,
            .optimize = optimize,
        });
        test262_mod.addImport("quickjs", qjs_mod);
        test262_mod.addImport("xev", xev_mod);

        const engine_import = b.createModule(.{
            .root_source_file = b.path("src/js/engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        engine_import.addImport("quickjs", qjs_mod);
        engine_import.addImport("xev", xev_mod);
        engine_import.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        test262_mod.addImport("engine", engine_import);

        const test262_test = b.addTest(.{
            .name = "test262",
            .root_module = test262_mod,
            .use_llvm = true,
        });
        const run_test262 = b.addRunArtifact(test262_test);
        test_test262_step.dependOn(&run_test262.step);
        test_step.dependOn(&run_test262.step);
    }
}
