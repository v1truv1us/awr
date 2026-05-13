const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

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
        .target = target,
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
    const is_mac = host_os == .macos;
    const supports_boringssl = target.result.os.tag == .macos and target.result.cpu.arch == .aarch64;
    const lexbor_prefix_opt = b.option([]const u8, "lexbor-prefix", "Install prefix containing lexbor include/ and lib/");
    // `-Dwith-jsonrpc` opts the daemon-mode JSON-RPC module into the
    // default test gate. The stdlib drift was fixed and the 18 framing
    // + envelope tests are green; flipping the default to true lets the
    // module ride the merge gate now and prevents future drift.
    const with_jsonrpc = b.option(bool, "with-jsonrpc", "Include src/jsonrpc.zig in the default test gate") orelse true;

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
    const boringssl_include = b.path("third_party/boringssl/include");
    const boringssl_lib_ssl = b.path("third_party/boringssl/lib/macos-arm64/libssl.a");
    const boringssl_lib_crpt = b.path("third_party/boringssl/lib/macos-arm64/libcrypto.a");

    // ── Test steps ────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run all unit tests");
    const test_net_step = b.step("test-net", "Run src/net unit tests");
    const test_js_step = b.step("test-js", "Run src/js unit tests");
    const test_html_step = b.step("test-html", "Run src/html unit tests");
    const test_dom_step = b.step("test-dom", "Run src/dom unit tests");
    const test_client_step = b.step("test-client", "Run src/client unit tests");
    const test_h2_step = b.step("test-h2", "Run h2session and HTTP/2 frame tests");
    const test_page_step = b.step("test-page", "Run src/page tests (unit + integration, requires network)");
    const test_tls_step = b.step("test-tls", "Run BoringSSL smoke + tls_conn unit tests");
    const test_e2e_step = b.step("test-e2e", "Run end-to-end integration tests (requires network)");
    const test_wpt_step = b.step("test-wpt", "Run curated WPT browser-runtime tests");
    const test_test262_step = b.step("test-test262", "Run curated Test262 JS runtime tests");
    const test_corpus_step = b.step("test-corpus", "Run real-page render-quality corpus harness");
    const test_image_step = b.step("test-image", "Run image decoder + protocol + cache tests");
    const test_doc_step = b.step("test-doc", "Run \xc2\xa78 \xe2\x86\x94 curated_cases doc-alignment check");
    const test_integration_step = b.step("test-integration", "Run binary-spawning Zig integration tests (requires built awr/awrd binaries)");
    const smoke_step = b.step("smoke", "Run mvp + regression smoke suites against the built binary");
    const bench_daemon_step = b.step("bench-daemon", "Daemon vs per-process chained-flow benchmark (spec §4.5 gate)");

    // ── stb_image vendored paths ──────────────────────────────────────────
    // Header-only library at third_party/stb/stb_image.h with a single C
    // translation unit at third_party/stb/stb_image_impl.c that pulls the
    // implementation. Mirrors the BoringSSL shim discipline.
    const stb_include = b.path("third_party/stb");
    const stb_csrc = b.path("third_party/stb/stb_image_impl.c");

    // ── Net layer modules (pure-Zig, no C deps) ───────────────────────────
    const pure_net_modules = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "fingerprint", .src = "src/net/fingerprint.zig" },
        .{ .name = "cookie", .src = "src/net/cookie.zig" },
        .{ .name = "http1", .src = "src/net/http1.zig" },
        .{ .name = "http2", .src = "src/net/http2.zig" },
        .{ .name = "pool", .src = "src/net/pool.zig" },
        .{ .name = "url", .src = "src/net/url.zig" },
    };

    for (pure_net_modules) |m| {
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
        if (std.mem.eql(u8, m.name, "http2")) test_h2_step.dependOn(&run_t.step);
    }

    // ── telemetry module (pure-Zig, no deps) ──────────────────────────────
    // Per-session structured-metrics emission. Imported by main.zig and
    // page.zig but stands alone for testing.
    {
        const telemetry_mod = b.createModule(.{
            .root_source_file = b.path("src/telemetry.zig"),
            .target = target,
            .optimize = optimize,
        });
        const telemetry_test = b.addTest(.{
            .name = "telemetry",
            .root_module = telemetry_mod,
        });
        const run_telemetry = b.addRunArtifact(telemetry_test);
        test_step.dependOn(&run_telemetry.step);
    }

    // ── jsonrpc module (pure-Zig, no deps) ────────────────────────────────
    // JSON-RPC 2.0 framing + envelope helpers per
    // spec/subspecs/daemon-mode.md §2.3. Foundation for the daemon
    // accept loop (B3.2) and CLI client (B3.4); standalone-testable.
    // Gated behind -Dwith-jsonrpc=true; see top-of-file rationale.
    if (with_jsonrpc) {
        const jsonrpc_mod = b.createModule(.{
            .root_source_file = b.path("src/jsonrpc.zig"),
            .target = target,
            .optimize = optimize,
        });
        const jsonrpc_test = b.addTest(.{
            .name = "jsonrpc",
            .root_module = jsonrpc_mod,
        });
        const run_jsonrpc = b.addRunArtifact(jsonrpc_test);
        test_step.dependOn(&run_jsonrpc.step);
    }

    // ── bookmarks module (pure-Zig, no deps) ──────────────────────────────
    // T-89 / Tier 2 slice T2.1. Tab-delimited bookmark store used by the
    // `awr bookmark add/list/rm` CLI and the `B` TUI binding.
    {
        const bookmarks_mod = b.createModule(.{
            .root_source_file = b.path("src/bookmarks.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const bookmarks_test = b.addTest(.{
            .name = "bookmarks",
            .root_module = bookmarks_mod,
        });
        const run_bookmarks = b.addRunArtifact(bookmarks_test);
        test_step.dependOn(&run_bookmarks.step);
    }

    // ── tcp module (depends on libxev) ────────────────────────────────────
    {
        const tcp_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tcp.zig"),
            .target = target,
            .optimize = optimize,
        });
        tcp_mod.addImport("xev", xev_mod);
        const tcp_test = b.addTest(.{
            .name = "tcp",
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
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        h2mod.addCSourceFile(.{
            .file = b.path("src/net/h2_shim.c"),
            .flags = &.{ "-std=c11", "-Wall" },
        });
        h2mod.addIncludePath(nghttp2_include);
        h2mod.addIncludePath(nghttp2_include_sys);
        h2mod.addLibraryPath(nghttp2_lib);
        h2mod.linkSystemLibrary("nghttp2", .{});
        const h2test = b.addTest(.{
            .name = "h2session",
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
            .target = target,
            .optimize = optimize,
        });
        js_mod.addImport("quickjs", qjs_mod);
        js_mod.addImport("xev", xev_mod);
        js_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));

        const js_test = b.addTest(.{
            .name = "js",
            .root_module = js_mod,
            .use_llvm = true, // required — QuickJS-NG crashes with self-hosted backend
        });
        const run_js = b.addRunArtifact(js_test);
        test_step.dependOn(&run_js.step);
        test_js_step.dependOn(&run_js.step);
    }

    // ── Web Storage backend (Tier 3 — T3.A) — pure Zig, no QuickJS ────────
    // Tested standalone for fast iteration; bridge.zig pulls it transitively
    // via the engine module when the dom-bridge tests run.
    {
        const storage_path_mod = b.createModule(.{
            .root_source_file = b.path("src/util/storage_path.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getenv
        });

        const storage_mod = b.createModule(.{
            .root_source_file = b.path("src/js/storage.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // std.c.getpid for tmp-file naming
        });
        storage_mod.addImport("storage_path", storage_path_mod);

        const storage_test = b.addTest(.{
            .name = "storage",
            .root_module = storage_mod,
        });
        const run_storage = b.addRunArtifact(storage_test);
        test_step.dependOn(&run_storage.step);
        test_js_step.dependOn(&run_storage.step);

        const storage_path_test = b.addTest(.{
            .name = "storage_path",
            .root_module = storage_path_mod,
        });
        const run_storage_path = b.addRunArtifact(storage_path_test);
        test_step.dependOn(&run_storage_path.step);
        test_js_step.dependOn(&run_storage_path.step);
    }

    // ── WebCrypto backend (T-93) — depends on BoringSSL ───────────────────
    // Standalone test target so the SHA / RAND vectors get verified on
    // every `zig build test` without pulling BoringSSL into the lighter
    // js_test target (which stays BoringSSL-free for fast iteration).
    if (supports_boringssl) {
        const webcrypto_mod = b.createModule(.{
            .root_source_file = b.path("src/js/webcrypto_backend.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        webcrypto_mod.addImport("quickjs", qjs_mod);
        webcrypto_mod.addImport("xev", xev_mod);
        webcrypto_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        addBoringSslSupport(b, webcrypto_mod, boringssl_include, boringssl_lib_ssl, boringssl_lib_crpt);

        const webcrypto_test = b.addTest(.{
            .name = "webcrypto_backend",
            .root_module = webcrypto_mod,
            .use_llvm = true, // matches js_test — engine.zig pulls QuickJS-NG
        });
        const run_webcrypto = b.addRunArtifact(webcrypto_test);
        test_step.dependOn(&run_webcrypto.step);
        test_js_step.dependOn(&run_webcrypto.step);
    }

    // ── HTML parser module (depends on lexbor) ────────────────────────────
    {
        const html_mod = b.createModule(.{
            .root_source_file = b.path("src/html/parser.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        html_mod.addIncludePath(lexbor_include);
        html_mod.addLibraryPath(lexbor_lib);
        html_mod.linkSystemLibrary("lexbor", .{});

        const html_test = b.addTest(.{
            .name = "html",
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
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        dom_mod.addIncludePath(lexbor_include);
        dom_mod.addLibraryPath(lexbor_lib);
        dom_mod.linkSystemLibrary("lexbor", .{});

        const dom_test = b.addTest(.{
            .name = "dom",
            .root_module = dom_mod,
        });
        const run_dom = b.addRunArtifact(dom_test);
        test_step.dependOn(&run_dom.step);
        test_dom_step.dependOn(&run_dom.step);
    }

    // ── Markdown extraction module (depends on dom + browse_heuristics) ───
    {
        const extract_mod = b.createModule(.{
            .root_source_file = b.path("src/extract.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        extract_mod.addIncludePath(lexbor_include);
        extract_mod.addLibraryPath(lexbor_lib);
        extract_mod.linkSystemLibrary("lexbor", .{});

        const extract_test = b.addTest(.{
            .name = "extract",
            .root_module = extract_mod,
        });
        const run_extract = b.addRunArtifact(extract_test);
        test_step.dependOn(&run_extract.step);
    }

    // ── Page module (Phase 2 — wires fetch+HTML+JS) ───────────────────────
    {
        const page_mod = b.createModule(.{
            .root_source_file = b.path("src/page.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = supports_boringssl,
        });
        page_mod.addImport("xev", xev_mod);
        page_mod.addImport("quickjs", qjs_mod);
        page_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        page_mod.addIncludePath(lexbor_include);
        page_mod.addLibraryPath(lexbor_lib);
        page_mod.linkSystemLibrary("lexbor", .{});
        if (supports_boringssl) addBoringSslSupport(b, page_mod, boringssl_include, boringssl_lib_ssl, boringssl_lib_crpt);
        if (supports_boringssl) addNgHttp2Support(b, page_mod, nghttp2_include, nghttp2_include_sys, nghttp2_lib);

        // render.zig (transitively imported via page) needs the
        // image_protocol module by name for its RenderOptions field.
        const page_image_protocol_mod = b.createModule(.{
            .root_source_file = b.path("src/image/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        page_mod.addImport("image_protocol", page_image_protocol_mod);

        // page.zig imports telemetry by name. Same pattern as
        // image_protocol — single-file pure-Zig module shared across
        // module instances within the same build unit.
        const page_telemetry_mod = b.createModule(.{
            .root_source_file = b.path("src/telemetry.zig"),
            .target = target,
            .optimize = optimize,
        });
        page_mod.addImport("telemetry", page_telemetry_mod);

        const page_test = b.addTest(.{
            .name = "page",
            .root_module = page_mod,
            .use_llvm = true, // required for QuickJS-NG
        });
        const run_page = b.addRunArtifact(page_test);
        test_step.dependOn(&run_page.step);
        test_page_step.dependOn(&run_page.step);
    }

    // ── Client module ─────────────────────────────────────────────────────
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = supports_boringssl,
        .link_libcpp = supports_boringssl,
    });
    client_mod.addImport("xev", xev_mod);
    if (supports_boringssl) addBoringSslSupport(b, client_mod, boringssl_include, boringssl_lib_ssl, boringssl_lib_crpt);
    if (supports_boringssl) addNgHttp2Support(b, client_mod, nghttp2_include, nghttp2_include_sys, nghttp2_lib);
    const client_test = b.addTest(.{
        .name = "client",
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
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = supports_boringssl,
        });
        exe_page_mod.addImport("xev", xev_mod);
        exe_page_mod.addImport("build_opts", opts_mod);
        exe_page_mod.addImport("quickjs", qjs_mod);
        exe_page_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        exe_page_mod.addIncludePath(lexbor_include);
        exe_page_mod.addLibraryPath(lexbor_lib);
        exe_page_mod.linkSystemLibrary("lexbor", .{});
        if (supports_boringssl) addBoringSslSupport(b, exe_page_mod, boringssl_include, boringssl_lib_ssl, boringssl_lib_crpt);
        if (supports_boringssl) addNgHttp2Support(b, exe_page_mod, nghttp2_include, nghttp2_include_sys, nghttp2_lib);

        // Shared image-protocol module: both main.zig (root) and
        // render.zig (transitively under page) need it. Without a
        // single named module both imports would each try to claim
        // src/image/protocol.zig and Zig errors with "file exists in
        // two modules."  This is the same pattern as `page` itself.
        const exe_image_protocol_mod = b.createModule(.{
            .root_source_file = b.path("src/image/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        exe_page_mod.addImport("image_protocol", exe_image_protocol_mod);

        // Shared telemetry module — same pattern as image_protocol.
        // main.zig (root) and page.zig both `@import("telemetry")`,
        // so we need one module instance both can resolve to.
        const exe_telemetry_mod = b.createModule(.{
            .root_source_file = b.path("src/telemetry.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_page_mod.addImport("telemetry", exe_telemetry_mod);

        // Image pipeline — orchestrates fetch + decode + encode for
        // every <img> on a page. Lives in its own named module so it
        // can pull in stb_image once (via decode.zig) without polluting
        // exe_mod or exe_page_mod with the C source. The pipeline
        // depends on the page module (for ImageLookup type + Page type)
        // and on image_protocol (for the Protocol enum). Encoders
        // (kitty/iterm/braille/sixel) come in via relative imports
        // inside the pipeline source.
        const exe_image_pipeline_mod = b.createModule(.{
            .root_source_file = b.path("src/image/pipeline.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        exe_image_pipeline_mod.addCSourceFile(.{
            .file = stb_csrc,
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-unused-but-set-variable" },
        });
        exe_image_pipeline_mod.addIncludePath(stb_include);
        exe_image_pipeline_mod.addImport("page", exe_page_mod);
        exe_image_pipeline_mod.addImport("image_protocol", exe_image_protocol_mod);


        // Test target for the pipeline's pure helpers (estimateCellDims,
        // pickFromSrcset, evalMedia, evalFeature). The Pipeline.build
        // path itself isn't unit-tested — it requires a live Page +
        // network and is exercised end-to-end via `awr render` smoke.
        const image_pipeline_test = b.addTest(.{
            .name = "image_pipeline",
            .root_module = exe_image_pipeline_mod,
            .use_llvm = true, // page module pulls in QuickJS-NG transitively
        });
        const run_image_pipeline = b.addRunArtifact(image_pipeline_test);
        test_image_step.dependOn(&run_image_pipeline.step);
        test_step.dependOn(&run_image_pipeline.step);

        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = supports_boringssl,
        });
        exe_mod.addImport("page", exe_page_mod);
        exe_mod.addImport("build_opts", opts_mod);
        exe_mod.addImport("image_protocol", exe_image_protocol_mod);
        exe_mod.addImport("image_pipeline", exe_image_pipeline_mod);
        exe_mod.addImport("telemetry", exe_telemetry_mod);

        const exe = b.addExecutable(.{
            .name = "awr",
            .root_module = exe_mod,
            .use_llvm = true,
        });
        b.installArtifact(exe);

        // ── awrd daemon ─────────────────────────────────────────────
        // Minimal v1 per spec/subspecs/daemon-mode.md §6 slice 2:
        // socket listen + accept loop + ping + shutdown. No Page/JS
        // dependency yet — that lands in slice 3+ when fetch/tools/call
        // methods come online. Keeping awrd's deps narrow (jsonrpc +
        // build_opts only) means the daemon binary is small enough to
        // ship as a no-op probe target during incremental development.
        const daemon_mod = b.createModule(.{
            .root_source_file = b.path("src/main_daemon.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = supports_boringssl,
        });
        daemon_mod.addImport("build_opts", opts_mod);
        // Slice 2: daemon depends on page so the fetch method handler
        // can call Page.navigate / Page.navigatePost. Reuses
        // exe_page_mod to share the (already built) module rather
        // than duplicating its lexbor/boringssl/libxev/QuickJS setup.
        daemon_mod.addImport("page", exe_page_mod);
        const awrd_exe = b.addExecutable(.{
            .name = "awrd",
            .root_module = daemon_mod,
            .use_llvm = true, // page transitively pulls in QuickJS-NG
        });
        b.installArtifact(awrd_exe);

        // Daemon unit tests (resolveSocketPath, frame round-trip helpers).
        // Lives in the same module so it picks up the build_opts import.
        const daemon_test = b.addTest(.{
            .name = "daemon",
            .root_module = daemon_mod,
        });
        const run_daemon = b.addRunArtifact(daemon_test);
        test_step.dependOn(&run_daemon.step);

        // ── Binary-spawning Zig integration tests ───────────────────
        // tests/integration_runner.zig spawns awr/awrd via
        // std.process.Child to verify CLI argv parsing, env handling,
        // and Unix-socket round-trips end-to-end. Replaces the .sh
        // smoke suite for hermetic checks; the .sh suite still owns
        // network-dependent regressions.
        //
        // Not wired into the default `test` step because the tests
        // assume the binaries are already installed at ./zig-out/bin/.
        // Run via `zig build test-integration`; depends on the install
        // step so the binaries are fresh.
        const integration_mod = b.createModule(.{
            .root_source_file = b.path("tests/integration_runner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        const integration_test = b.addTest(.{
            .name = "integration",
            .root_module = integration_mod,
        });
        const run_integration = b.addRunArtifact(integration_test);
        run_integration.step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        run_integration.step.dependOn(&b.addInstallArtifact(awrd_exe, .{}).step);
        test_integration_step.dependOn(&run_integration.step);

        // `zig build smoke` — runs the two shell suites against the
        // freshly-built binary. mvp_smoke.sh covers the original
        // acceptance tests against the local mock server;
        // regression_smoke.sh codifies the May 2026 bug-fix
        // regressions (B1/B2/B3 hangs, cookie persistence, end-to-end
        // sign-in) with timing budgets. Each script honors AWR_BIN
        // for non-default binary locations and AWR_SMOKE_OFFLINE=1
        // for network-skipped CI runs.
        const mvp_smoke = b.addSystemCommand(&.{ "scripts/mvp_smoke.sh" });
        mvp_smoke.step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        const regression_smoke = b.addSystemCommand(&.{ "scripts/regression_smoke.sh" });
        regression_smoke.step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        // T-86 / Tier 1 closure smoke (T1.11): Google search round-trip
        // + optional HN sign-in. Honors AWR_SMOKE_OFFLINE=1 like the
        // other smokes; in offline mode it exits 0 immediately.
        const browse_smoke = b.addSystemCommand(&.{ "scripts/browse_smoke.sh" });
        browse_smoke.step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        smoke_step.dependOn(&mvp_smoke.step);
        smoke_step.dependOn(&regression_smoke.step);
        smoke_step.dependOn(&browse_smoke.step);

        // `zig build bench-daemon` — daemon vs per-process chained-flow
        // benchmark per spec/subspecs/daemon-mode.md §4.5. Defaults to
        // hermetic localhost-mock mode (informational; small speedup
        // because TLS+CA-bundle costs don't fire on HTTP). Set
        // BENCH_HTTPS=<url> to gate the spec's 30%-floor against a
        // real HTTPS endpoint. Depends on both binaries being built.
        const bench_daemon = b.addSystemCommand(&.{ "scripts/bench_daemon.sh" });
        bench_daemon.step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        bench_daemon.step.dependOn(&b.addInstallArtifact(awrd_exe, .{}).step);
        bench_daemon_step.dependOn(&bench_daemon.step);
    }

    // ── BoringSSL smoke test (confirms libs link + headers resolve) ───────
    // macOS-only: vendored BoringSSL static libs are macos-arm64 only.
    if (supports_boringssl) {
        const tls_smoke_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tls_smoke_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true, // BoringSSL is C++ (std::variant, exceptions, vtables)
        });
        tls_smoke_mod.addCSourceFile(.{
            .file = b.path("src/net/tls_awr_shim.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
        });
        tls_smoke_mod.addIncludePath(b.path("src/net"));
        tls_smoke_mod.addIncludePath(boringssl_include);
        tls_smoke_mod.addObjectFile(boringssl_lib_ssl);
        tls_smoke_mod.addObjectFile(boringssl_lib_crpt);

        const tls_smoke = b.addTest(.{
            .name = "tls",
            .root_module = tls_smoke_mod,
        });
        const run_tls_smoke = b.addRunArtifact(tls_smoke);
        test_tls_step.dependOn(&run_tls_smoke.step);
        test_step.dependOn(&run_tls_smoke.step);

        // ── tls_conn module (BoringSSL Zig wrapper + shim) ────────────────
        const tls_conn_mod = b.createModule(.{
            .root_source_file = b.path("src/net/tls_conn.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        tls_conn_mod.addCSourceFile(.{
            .file = b.path("src/net/tls_awr_shim.c"),
            .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
        });
        tls_conn_mod.addIncludePath(b.path("src/net"));
        tls_conn_mod.addIncludePath(boringssl_include);
        tls_conn_mod.addObjectFile(boringssl_lib_ssl);
        tls_conn_mod.addObjectFile(boringssl_lib_crpt);

        const tls_conn_test = b.addTest(.{
            .name = "tls_conn",
            .root_module = tls_conn_mod,
        });
        const run_tls_conn = b.addRunArtifact(tls_conn_test);
        test_tls_step.dependOn(&run_tls_conn.step);
        test_step.dependOn(&run_tls_conn.step);
    }

    // ── End-to-end integration tests (network required) ───────────────────
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/test_e2e.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = supports_boringssl,
        .link_libcpp = supports_boringssl,
    });
    e2e_mod.addImport("xev", xev_mod);
    if (supports_boringssl) addBoringSslSupport(b, e2e_mod, boringssl_include, boringssl_lib_ssl, boringssl_lib_crpt);
    const e2e_test = b.addTest(.{
        .name = "e2e",
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
            .link_libcpp = supports_boringssl,
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
            .link_libcpp = supports_boringssl,
        });
        page_import.addImport("xev", xev_mod);
        page_import.addImport("quickjs", qjs_mod);
        page_import.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        page_import.addIncludePath(lexbor_include);
        page_import.addLibraryPath(lexbor_lib);
        page_import.linkSystemLibrary("lexbor", .{});
        if (supports_boringssl) addBoringSslSupport(b, page_import, boringssl_include, boringssl_lib_ssl, boringssl_lib_crpt);
        if (supports_boringssl) addNgHttp2Support(b, page_import, nghttp2_include, nghttp2_include_sys, nghttp2_lib);
        // render.zig (transitively under page) needs image_protocol.
        const wpt_image_protocol_mod = b.createModule(.{
            .root_source_file = b.path("src/image/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        page_import.addImport("image_protocol", wpt_image_protocol_mod);
        // page.zig imports "telemetry"; mirror exe / page_mod patterns.
        const wpt_telemetry_mod = b.createModule(.{
            .root_source_file = b.path("src/telemetry.zig"),
            .target = target,
            .optimize = optimize,
        });
        page_import.addImport("telemetry", wpt_telemetry_mod);
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

    // ── Real-page render-quality corpus runner ────────────────────────────
    // Per spec/subspecs/rendering.md Track B. Same module-graph shape as
    // the WPT runner above (needs Page → DOM → JS → render); the only
    // difference is which `tests/*.zig` is the test root.
    {
        const corpus_mod = b.createModule(.{
            .root_source_file = b.path("tests/corpus_runner.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = supports_boringssl,
        });
        corpus_mod.addImport("xev", xev_mod);
        corpus_mod.addImport("quickjs", qjs_mod);
        corpus_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        corpus_mod.addIncludePath(lexbor_include);
        corpus_mod.addLibraryPath(lexbor_lib);
        corpus_mod.linkSystemLibrary("lexbor", .{});

        const page_import = b.createModule(.{
            .root_source_file = b.path("src/page.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = supports_boringssl,
        });
        page_import.addImport("xev", xev_mod);
        page_import.addImport("quickjs", qjs_mod);
        page_import.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        page_import.addIncludePath(lexbor_include);
        page_import.addLibraryPath(lexbor_lib);
        page_import.linkSystemLibrary("lexbor", .{});
        if (supports_boringssl) addBoringSslSupport(b, page_import, boringssl_include, boringssl_lib_ssl, boringssl_lib_crpt);
        if (supports_boringssl) addNgHttp2Support(b, page_import, nghttp2_include, nghttp2_include_sys, nghttp2_lib);
        // render.zig (transitively under page) needs image_protocol.
        const corpus_image_protocol_mod = b.createModule(.{
            .root_source_file = b.path("src/image/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        page_import.addImport("image_protocol", corpus_image_protocol_mod);
        // page.zig imports "telemetry"; mirror exe / page_mod patterns.
        const corpus_telemetry_mod = b.createModule(.{
            .root_source_file = b.path("src/telemetry.zig"),
            .target = target,
            .optimize = optimize,
        });
        page_import.addImport("telemetry", corpus_telemetry_mod);
        corpus_mod.addImport("page", page_import);

        const corpus_test = b.addTest(.{
            .name = "corpus",
            .root_module = corpus_mod,
            .use_llvm = true,
        });
        const run_corpus = b.addRunArtifact(corpus_test);
        test_corpus_step.dependOn(&run_corpus.step);
        test_step.dependOn(&run_corpus.step);
    }

    // ── Image decoder module (depends on stb_image) ──────────────────────
    // Per spec/subspecs/rendering.md §3.3. The src/image/ tree is
    // text-only at the model layer (decode → encode happens in
    // src/browser.zig:draw); this test target verifies the decoder +
    // cache + protocol detection in isolation.
    {
        const image_decode_mod = b.createModule(.{
            .root_source_file = b.path("src/image/decode.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        image_decode_mod.addCSourceFile(.{
            .file = stb_csrc,
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-unused-but-set-variable" },
        });
        image_decode_mod.addIncludePath(stb_include);

        const image_decode_test = b.addTest(.{
            .name = "image_decode",
            .root_module = image_decode_mod,
        });
        const run_image_decode = b.addRunArtifact(image_decode_test);
        test_image_step.dependOn(&run_image_decode.step);
        test_step.dependOn(&run_image_decode.step);

        // src/image/cache.zig — pure-Zig LRU; depends on decode.zig for the
        // Image type. Same C-source compile because cache imports decode
        // which @cImports stb_image.h.
        const image_cache_mod = b.createModule(.{
            .root_source_file = b.path("src/image/cache.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        image_cache_mod.addCSourceFile(.{
            .file = stb_csrc,
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-unused-but-set-variable" },
        });
        image_cache_mod.addIncludePath(stb_include);

        const image_cache_test = b.addTest(.{
            .name = "image_cache",
            .root_module = image_cache_mod,
        });
        const run_image_cache = b.addRunArtifact(image_cache_test);
        test_image_step.dependOn(&run_image_cache.step);
        test_step.dependOn(&run_image_cache.step);

        // src/image/protocol.zig — pure-Zig capability detection +
        // dispatch policy. Needs libc only for termios/isatty/getenv in
        // the runtime helpers (`probeSixel`, `realEnvSnapshot`,
        // `stdoutIsTty`); the pure `resolve` and `da1HasSixel` paths
        // tested here have no I/O.
        const image_protocol_mod = b.createModule(.{
            .root_source_file = b.path("src/image/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        const image_protocol_test = b.addTest(.{
            .name = "image_protocol",
            .root_module = image_protocol_mod,
        });
        const run_image_protocol = b.addRunArtifact(image_protocol_test);
        test_image_step.dependOn(&run_image_protocol.step);
        test_step.dependOn(&run_image_protocol.step);

        // src/image/braille.zig — pure-Zig 2×4 braille downsampler.
        // Imports decode.zig for the Image type, so it transitively
        // pulls in stb_image — same C-source compile pattern as
        // image_cache_mod.
        const image_braille_mod = b.createModule(.{
            .root_source_file = b.path("src/image/braille.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        image_braille_mod.addCSourceFile(.{
            .file = stb_csrc,
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-unused-but-set-variable" },
        });
        image_braille_mod.addIncludePath(stb_include);

        const image_braille_test = b.addTest(.{
            .name = "image_braille",
            .root_module = image_braille_mod,
        });
        const run_image_braille = b.addRunArtifact(image_braille_test);
        test_image_step.dependOn(&run_image_braille.step);
        test_step.dependOn(&run_image_braille.step);

        // src/image/kitty.zig — Kitty graphics encoder. Same shape as
        // braille_mod (decode-importing → stb_image transitively).
        const image_kitty_mod = b.createModule(.{
            .root_source_file = b.path("src/image/kitty.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        image_kitty_mod.addCSourceFile(.{
            .file = stb_csrc,
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-unused-but-set-variable" },
        });
        image_kitty_mod.addIncludePath(stb_include);

        const image_kitty_test = b.addTest(.{
            .name = "image_kitty",
            .root_module = image_kitty_mod,
        });
        const run_image_kitty = b.addRunArtifact(image_kitty_test);
        test_image_step.dependOn(&run_image_kitty.step);
        test_step.dependOn(&run_image_kitty.step);

        // src/image/iterm.zig — iTerm2 OSC-1337 encoder. Operates on
        // raw file bytes (passes them through to the terminal) so it
        // doesn't need stb_image / decode.zig — pure-Zig module.
        const image_iterm_mod = b.createModule(.{
            .root_source_file = b.path("src/image/iterm.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        const image_iterm_test = b.addTest(.{
            .name = "image_iterm",
            .root_module = image_iterm_mod,
        });
        const run_image_iterm = b.addRunArtifact(image_iterm_test);
        test_image_step.dependOn(&run_image_iterm.step);
        test_step.dependOn(&run_image_iterm.step);

        // src/image/sixel.zig — DCS Sixel encoder with median-cut
        // palette quantization. Same shape as image_kitty_mod
        // (decode-importing → stb_image transitively).
        const image_sixel_mod = b.createModule(.{
            .root_source_file = b.path("src/image/sixel.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        image_sixel_mod.addCSourceFile(.{
            .file = stb_csrc,
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wno-unused-but-set-variable" },
        });
        image_sixel_mod.addIncludePath(stb_include);

        const image_sixel_test = b.addTest(.{
            .name = "image_sixel",
            .root_module = image_sixel_mod,
        });
        const run_image_sixel = b.addRunArtifact(image_sixel_test);
        test_image_step.dependOn(&run_image_sixel.step);
        test_step.dependOn(&run_image_sixel.step);
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

    // ── §8 ↔ curated_cases doc-alignment check ───────────────────────────
    // Pure std: no C libs, no QuickJS. Reads three repo files at runtime.
    {
        const doc_check_mod = b.createModule(.{
            .root_source_file = b.path("tests/wpt_doc_check.zig"),
            .target = target,
            .optimize = optimize,
        });
        const doc_check_test = b.addTest(.{
            .name = "doc_check",
            .root_module = doc_check_mod,
        });
        const run_doc_check = b.addRunArtifact(doc_check_test);
        test_doc_step.dependOn(&run_doc_check.step);
        test_step.dependOn(&run_doc_check.step);
    }

    // ── Page load benchmark ─────────────────────────────────────────────
    // Compares AWR's page load + render time. Run with `zig build test-bench`.
    {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = supports_boringssl,
        });
        bench_mod.addImport("xev", xev_mod);
        bench_mod.addImport("quickjs", qjs_mod);
        bench_mod.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        bench_mod.addIncludePath(lexbor_include);
        bench_mod.addLibraryPath(lexbor_lib);
        bench_mod.linkSystemLibrary("lexbor", .{});

        const page_import = b.createModule(.{
            .root_source_file = b.path("src/page.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = supports_boringssl,
        });
        page_import.addImport("xev", xev_mod);
        page_import.addImport("quickjs", qjs_mod);
        page_import.linkLibrary(qjs_dep.artifact("quickjs-ng"));
        page_import.addIncludePath(lexbor_include);
        page_import.addLibraryPath(lexbor_lib);
        page_import.linkSystemLibrary("lexbor", .{});
        if (supports_boringssl) addBoringSslSupport(b, page_import, boringssl_include, boringssl_lib_ssl, boringssl_lib_crpt);
        const bench_image_protocol_mod = b.createModule(.{
            .root_source_file = b.path("src/image/protocol.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        page_import.addImport("image_protocol", bench_image_protocol_mod);
        bench_mod.addImport("page", page_import);

        const test_bench_step = b.step("test-bench", "Run page load benchmark");

        const bench_test = b.addTest(.{
            .name = "bench",
            .root_module = bench_mod,
            .use_llvm = true,
        });
        const run_bench = b.addRunArtifact(bench_test);
        test_bench_step.dependOn(&run_bench.step);
    }
}

fn addBoringSslSupport(
    b: *std.Build,
    mod: *std.Build.Module,
    boringssl_include: std.Build.LazyPath,
    boringssl_lib_ssl: std.Build.LazyPath,
    boringssl_lib_crpt: std.Build.LazyPath,
) void {
    mod.addCSourceFile(.{
        .file = b.path("src/net/tls_awr_shim.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra" },
    });
    mod.addIncludePath(b.path("src/net"));
    mod.addIncludePath(boringssl_include);
    mod.addObjectFile(boringssl_lib_ssl);
    mod.addObjectFile(boringssl_lib_crpt);
}

/// Wire H2 (nghttp2 + h2_shim.c) into a module that imports
/// `src/net/h2session.zig` as source. Mirrors `addBoringSslSupport` so
/// non-test link units (the `awr` exe; the client test target) can
/// resolve `awr_h2_*` symbols. Without this, every binary that
/// transitively imports `Client` would fail at link time once H2
/// dispatch is in the BoringSSL fallback path.
fn addNgHttp2Support(
    b: *std.Build,
    mod: *std.Build.Module,
    nghttp2_include: std.Build.LazyPath,
    nghttp2_include_sys: std.Build.LazyPath,
    nghttp2_lib: std.Build.LazyPath,
) void {
    mod.addCSourceFile(.{
        .file = b.path("src/net/h2_shim.c"),
        .flags = &.{ "-std=c11", "-Wall" },
    });
    mod.addIncludePath(nghttp2_include);
    mod.addIncludePath(nghttp2_include_sys);
    mod.addLibraryPath(nghttp2_lib);
    mod.linkSystemLibrary("nghttp2", .{});
}
