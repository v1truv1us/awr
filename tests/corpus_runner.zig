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
    expected: []const u8,
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
