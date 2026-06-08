/// corpus_runner.zig — real-page render-quality test harness
/// (per spec/subspecs/rendering.md Track B).
///
/// For each fixture in `tests/corpus/fixtures/`:
///   1. processHtml the captured HTML at the fixture's recorded URL,
///   2. renderBrowseModel against terminal-default options,
///   3. snapshot-diff `.text` output against the recorded `.expected.txt`,
///   4. run per-fixture soft assertions (min text bytes, must-contain set).
///
/// On a snapshot mismatch, the runner writes the "actual" output to
/// `tests/corpus/fixtures/<name>.actual.txt` next to the expected file so
/// the human reviewer can `diff` the two before deciding whether to bless
/// the change. Bless via `scripts/update-corpus.sh <name>` (added when
/// regenerate workflow lands) or by overwriting `.expected.txt` from
/// `.actual.txt` manually — the runner does NOT silently rebake.
///
/// Bootstrap: an empty `.expected.txt` means "this fixture has not yet
/// been blessed". The runner treats empty-expected as a soft initial
/// state and seeds it from the live render output, exactly once. Set
/// `AWR_CORPUS_STRICT=1` in the environment to disable that seeding and
/// fail on empty expected files (CI mode).
const std = @import("std");
const page_mod = @import("page");

const Fixture = struct {
    name: []const u8,
    url: []const u8,
    html: []const u8,
    /// Recorded byte snapshot. Empty for soft-only fixtures
    /// (`exact_snapshot = false`), which never reach the diff/seed path.
    expected: []const u8 = "",
    /// Soft floor on rendered text length (in bytes, after whitespace
    /// normalization). Catches "blank screen" regressions even when the
    /// snapshot diff has not yet been blessed.
    min_text_bytes: usize = 0,
    /// Substrings that MUST appear in the rendered output. One assertion
    /// per entry; failure names the fixture and the missing string.
    must_contain: []const []const u8 = &.{},
    /// Substrings that MUST NOT appear — guards against escape-sequence
    /// garbage in non-TTY mode, "[object Object]" tokens, and similar.
    must_not_contain: []const []const u8 = &.{},
    /// When true (default), the rendered output is byte-snapshot-diffed
    /// against `expected`. Set false for fixtures whose exact bytes are not
    /// reproducible across builds — e.g. JS-hydrated pages whose script
    /// execution mutates the DOM in a memory-layout-dependent order (see
    /// `mdn_select`). Those rely on the soft assertions (min_text_bytes +
    /// must_contain/must_not_contain) instead, which guard readability and
    /// blank-page regressions without pinning fragile exact bytes.
    exact_snapshot: bool = true,
};

const fixtures = [_]Fixture{
    .{
        // Category 1 — static baseline.
        .name = "example_com",
        .url = "https://example.com/",
        .html = @embedFile("corpus/fixtures/example_com.html"),
        .expected = @embedFile("corpus/fixtures/example_com.expected.txt"),
        .min_text_bytes = 50,
        .must_contain = &.{ "Example Domain", "Learn more" },
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 8 — discussion / threading. HN is also a tables-as-layout
        // stress case (covered by render-side unit tests, but the real
        // page is denser and noisier).
        .name = "hacker_news",
        .url = "https://news.ycombinator.com/",
        .html = @embedFile("corpus/fixtures/hacker_news.html"),
        .expected = @embedFile("corpus/fixtures/hacker_news.expected.txt"),
        .min_text_bytes = 1000,
        .must_contain = &.{ "Hacker News", "points by" },
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 2 — long-form article / semantic HTML5. This fixture
        // proved the dominance-guard fix in browse_heuristics.zig: before
        // the fix, the cladogram <tbody> overrode <main> as the chosen
        // root and the article rendered at 984 bytes (taxonomy only).
        // After the fix, the full article body comes through (~100 KB
        // of rendered text). Inline citations resolve as [N] footnote
        // refs. The min_text_bytes floor is a regression guard against
        // any future change that drops back to fragment-only renders.
        .name = "wikipedia_octopus",
        .url = "https://en.wikipedia.org/wiki/Octopus",
        .html = @embedFile("corpus/fixtures/wikipedia_octopus.html"),
        .expected = @embedFile("corpus/fixtures/wikipedia_octopus.expected.txt"),
        .min_text_bytes = 50_000,
        .must_contain = &.{ "Octopus", "cephalopod", "Pathogens", "Evolution" },
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 10 — form-heavy page. httpbin's form fixture is the
        // canonical multi-input <form method="post"> that round-trips
        // through the agent-browser pipeline.
        .name = "httpbin_form",
        .url = "https://httpbin.org/forms/post",
        .html = @embedFile("corpus/fixtures/httpbin_form.html"),
        .expected = @embedFile("corpus/fixtures/httpbin_form.expected.txt"),
        .min_text_bytes = 100,
        .must_contain = &.{ "Customer name", "Telephone" },
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 6 — app shell with SSR card grid. The renderer must
        // surface NVIDIA's model-card content via the <main> escape
        // hatch in shouldSkipForBrowse (commit adad620). Without that
        // fix this fixture renders as a blank shell.
        .name = "nvidia_models",
        .url = "https://build.nvidia.com/models?filters=nimType%3Anim_type_preview&label=coding",
        .html = @embedFile("corpus/fixtures/nvidia_models.html"),
        .expected = @embedFile("corpus/fixtures/nvidia_models.expected.txt"),
        .min_text_bytes = 800,
        .must_contain = &.{ "NVIDIA", "Models" },
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 4 — documentation site. MDN's <select> page exercises
        // <main>, deeply nested headings, code blocks (<code>/<pre>),
        // definition lists (<dl>/<dt>/<dd>), and a sidebar <aside> that
        // should collapse via shouldCollapseForBrowse.
        //
        // SOFT-ONLY (exact_snapshot=false): this page is JS-hydrated — its
        // article content is injected by inline scripts at processHtml time.
        // That script execution runs through QuickJS + the pointer-keyed DOM
        // bridge, and its DOM-mutation order is sensitive to memory layout,
        // so the exact rendered bytes are NOT reproducible across builds
        // (any unrelated code change that shifts allocations flips the chosen
        // content root between "article" and "article + top nav"). Both
        // outcomes are readable; pinning exact bytes made the fixture red on
        // benign changes. The underlying JS-path nondeterminism is tracked
        // under T7 (docs/plans/readable-browser-goal.md). Until then the soft
        // floor + must_contain guard readability and catch the scripts-failed
        // ~1.5 KB blank-shell regression.
        .name = "mdn_select",
        .url = "https://developer.mozilla.org/en-US/docs/Web/HTML/Element/select",
        .html = @embedFile("corpus/fixtures/mdn_select.html"),
        .exact_snapshot = false,
        .min_text_bytes = 8000,
        // Strings short enough to survive 78-col word-wrap, present in both
        // hydrated layout outcomes ("menu of options" wraps and is unsafe).
        .must_contain = &.{ "select", "Try it", "Permitted ARIA", "HTML select element" },
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 5 — code-host SSR + CSR. GitHub repo pages are heavy
        // SPAs that nonetheless emit substantial server-rendered HTML
        // (file tree placeholder, README, sidebar with stats). This
        // fixture proves we extract README content rather than choking
        // on the SPA chrome. Captured 2026-04-29 when ziglang/zig had
        // its "Moved to Codeberg" notice; that's the actual page state
        // we're snapshotting.
        .name = "github_zig",
        .url = "https://github.com/ziglang/zig",
        .html = @embedFile("corpus/fixtures/github_zig.html"),
        .expected = @embedFile("corpus/fixtures/github_zig.expected.txt"),
        .min_text_bytes = 1000,
        .must_contain = &.{ "ziglang", "zig" },
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 11 — international CJK. Chinese Wikipedia article
        // 八腕目 ("Octopoda"). Exercises UTF-8 multi-byte handling,
        // CJK display-width math (each Han character occupies 2 cells),
        // and the same chooseContentRoot path as English Wikipedia
        // (proves the dominance guard isn't English-specific).
        .name = "wiki_zh_octopus",
        .url = "https://zh.wikipedia.org/wiki/%E7%AB%A0%E9%B1%BC",
        .html = @embedFile("corpus/fixtures/wiki_zh_octopus.html"),
        .expected = @embedFile("corpus/fixtures/wiki_zh_octopus.expected.txt"),
        .min_text_bytes = 5000,
        // Assert on article-body Han text ("章鱼" = octopus) to verify UTF-8
        // multi-byte survival. The old sentinel "维基百科" (Wikipedia) was
        // site-header branding, which CSSOM now correctly hides via the
        // header's display:none — it lives in body_text but not the render.
        .must_contain = &.{"章鱼"},
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 13 — malformed / edge custom fixture. Stresses the
        // parser with: unclosed elements, duplicate <title>, deeply
        // nested divs, mixed casing, missing </body>/</html>, anchors
        // with no/empty/javascript: hrefs, custom elements, and
        // <script>/<style> content that must NOT appear in rendered
        // output. Soft assertions guard against regressions where
        // any of these crash or leak script source into the body.
        .name = "malformed_edge",
        .url = "http://example.com/malformed",
        .html = @embedFile("corpus/fixtures/malformed_edge.html"),
        .expected = @embedFile("corpus/fixtures/malformed_edge.expected.txt"),
        .min_text_bytes = 200,
        .must_contain = &.{ "Edge cases", "Cell A", "Eleven divs deep" },
        .must_not_contain = &.{
            "[object Object]",
            "\x1b[",
            "console.log",
            "color: red",
            "This is a comment",
        },
    },
    .{
        // Category 3 — news investigation / long-read. ProPublica's IRS
        // Files investigation. Long-form journalism with bylines,
        // pull-quotes, image captions, sidebar callouts, and a long
        // article body. Exercises the renderer's handling of
        // magazine-style nested <section> structures.
        .name = "propublica_irs",
        .url = "https://www.propublica.org/article/the-secret-irs-files-trove-of-never-before-seen-records-reveal-how-the-wealthiest-avoid-income-tax",
        .html = @embedFile("corpus/fixtures/propublica_irs.html"),
        .expected = @embedFile("corpus/fixtures/propublica_irs.expected.txt"),
        .min_text_bytes = 10_000,
        .must_contain = &.{ "ProPublica", "IRS" },
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 7 — heavy SPA with mostly-empty SSR. x.com (Twitter)
        // login page. The page emits no <main>, no <article>, no
        // semantic structure — all content is JS-rendered post-load,
        // and AWR's QuickJS engine cannot drive that. This fixture's
        // job is to assert the renderer DOES NOT CRASH on such pages
        // and produces grep-friendly text output (escape-free) even
        // when there's almost nothing to render. Realistic for any
        // pure-SPA login or app entrypoint.
        .name = "x_login",
        .url = "https://x.com/login",
        .html = @embedFile("corpus/fixtures/x_login.html"),
        .expected = @embedFile("corpus/fixtures/x_login.expected.txt"),
        // SOFT-ONLY (exact_snapshot=false): a pure-SPA shell renders ~0 bytes
        // of reproducible text, so there is no stable snapshot to bless — an
        // empty expected.txt would otherwise perpetually re-seed (and fail
        // hard under AWR_CORPUS_STRICT=1). The real contract here is the soft
        // assertions: no crash, grep-friendly escape-free output, no
        // "[object Object]" leakage.
        .exact_snapshot = false,
        .min_text_bytes = 0, // SPA shell — no SSR content guaranteed
        .must_contain = &.{},
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
    .{
        // Category 12 — international RTL. Arabic Wikipedia article on
        // أخطبوطيات (Octopodiformes). Same chooseContentRoot path as
        // English/Chinese Wikipedia. Renderer outputs LTR-formatted
        // text — RTL display is the terminal's responsibility, not
        // the renderer's. Assertion: doesn't crash, preserves Arabic
        // bytes verbatim (no mojibake), produces meaningful text
        // length.
        .name = "wiki_ar_octopus",
        .url = "https://ar.wikipedia.org/wiki/%D8%A3%D8%AE%D8%B7%D8%A8%D9%88%D8%B7",
        .html = @embedFile("corpus/fixtures/wiki_ar_octopus.html"),
        .expected = @embedFile("corpus/fixtures/wiki_ar_octopus.expected.txt"),
        .min_text_bytes = 5000,
        // Assert on article-subject Arabic text ("أخطبوطيات" = Octopodiformes)
        // to verify UTF-8 multi-byte survival. The old sentinel "ويكيبيديا"
        // (Wikipedia) was site-header branding, which CSSOM now correctly
        // hides — it lives in body_text but not the render.
        .must_contain = &.{"أخطبوطيات"},
        .must_not_contain = &.{ "[object Object]", "\x1b[" },
    },
};

fn renderFixture(allocator: std.mem.Allocator, fixture: Fixture) ![]u8 {
    var page = try page_mod.Page.init(allocator, std.testing.io);
    defer page.deinit();

    var result = try page.processHtml(fixture.url, 200, fixture.html);
    defer result.deinit();

    var screen = try page.renderBrowseModel(allocator, &result, .{
        .max_width = 78,
        .ansi_colors = false, // snapshots are escape-free for grep + diff sanity
        .show_links = true,
        .show_images = true,
    });
    defer screen.deinit();

    return try allocator.dupe(u8, screen.text);
}

fn writeActualBeside(allocator: std.mem.Allocator, fixture: Fixture, actual: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "tests/corpus/fixtures/{s}.actual.txt", .{fixture.name});
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, actual);
}

fn assertContains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Read the named env var via libc and report whether it is set to a
/// non-empty value. Mirrors the env-reading pattern in
/// `src/util/cookie_path.zig` since Zig 0.16 removed
/// `std.process.getEnvVarOwned`.
fn envIsSet(name: []const u8) bool {
    if (!@hasDecl(std.c, "getenv")) return false;
    var name_buf: [64]u8 = undefined;
    if (name.len + 1 > name_buf.len) return false;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&name_buf)) orelse return false;
    const span = std.mem.sliceTo(raw, 0);
    return span.len > 0;
}

fn runFixture(allocator: std.mem.Allocator, fixture: Fixture) !void {
    const actual = try renderFixture(allocator, fixture);
    defer allocator.free(actual);

    // Soft floor: catches blank-screen regressions before snapshot diff.
    if (actual.len < fixture.min_text_bytes) {
        std.debug.print(
            "corpus[{s}] FAIL min_text_bytes: got {d}, want >= {d}\n",
            .{ fixture.name, actual.len, fixture.min_text_bytes },
        );
        try writeActualBeside(allocator, fixture, actual);
        return error.CorpusMinTextBytes;
    }

    for (fixture.must_contain) |needle| {
        if (!assertContains(actual, needle)) {
            std.debug.print(
                "corpus[{s}] FAIL must_contain: missing \"{s}\"\n",
                .{ fixture.name, needle },
            );
            try writeActualBeside(allocator, fixture, actual);
            return error.CorpusMustContain;
        }
    }
    for (fixture.must_not_contain) |needle| {
        if (assertContains(actual, needle)) {
            std.debug.print(
                "corpus[{s}] FAIL must_not_contain: found \"{s}\"\n",
                .{ fixture.name, needle },
            );
            try writeActualBeside(allocator, fixture, actual);
            return error.CorpusMustNotContain;
        }
    }

    // Soft-only fixtures (exact_snapshot=false) stop here: their bytes are
    // not reproducible across builds, so the snapshot/seed steps are skipped
    // and the soft assertions above are the contract.
    if (!fixture.exact_snapshot) return;

    // Empty `.expected.txt` is the bootstrap signal: seed from live render
    // unless AWR_CORPUS_STRICT=1 is set (CI mode). Seeding writes the
    // expected file in-place so a follow-up `git diff` is the bless step.
    if (fixture.expected.len == 0) {
        if (envIsSet("AWR_CORPUS_STRICT")) {
            std.debug.print(
                "corpus[{s}] FAIL empty expected (AWR_CORPUS_STRICT=1)\n",
                .{fixture.name},
            );
            return error.CorpusEmptyExpectedStrict;
        }
        const path = try std.fmt.allocPrint(
            allocator,
            "tests/corpus/fixtures/{s}.expected.txt",
            .{fixture.name},
        );
        defer allocator.free(path);
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .truncate = true });
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, actual);
        std.debug.print(
            "corpus[{s}] SEEDED expected.txt ({d} bytes) — review with `git diff`\n",
            .{ fixture.name, actual.len },
        );
        return;
    }

    if (!std.mem.eql(u8, fixture.expected, actual)) {
        std.debug.print(
            "corpus[{s}] FAIL snapshot diff: expected {d} bytes, got {d} bytes\n",
            .{ fixture.name, fixture.expected.len, actual.len },
        );
        try writeActualBeside(allocator, fixture, actual);
        std.debug.print(
            "  -> actual written to tests/corpus/fixtures/{s}.actual.txt; bless via diff/copy\n",
            .{fixture.name},
        );
        return error.CorpusSnapshotMismatch;
    }
}

test "real-page render-quality corpus" {
    for (fixtures) |fixture| {
        try runFixture(std.testing.allocator, fixture);
    }
}
