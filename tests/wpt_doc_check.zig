/// doc-check for spec/subspecs/wpt-conformance.md §8 ↔ curated_cases alignment.
/// Pure std: no C libs, no QuickJS, no page pipeline. Wired under zig build test-doc.
/// Reads the three repo files at runtime (project root = cwd when run via zig build).
const std = @import("std");

/// Scan `bytes` for backtick-enclosed *.js tokens with no `/` path separator.
/// Deduplicates: each filename is appended at most once.
fn extractJsFilenames(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == '`') {
            i += 1;
            const start = i;
            while (i < bytes.len and bytes[i] != '`') i += 1;
            const token = bytes[start..i];
            if (std.mem.endsWith(u8, token, ".js") and
                std.mem.indexOfScalar(u8, token, '/') == null)
            {
                const dupe = for (out.items) |x| {
                    if (std.mem.eql(u8, x, token)) break true;
                } else false;
                if (!dupe) try out.append(allocator, token);
            }
            if (i < bytes.len) i += 1;
        } else {
            i += 1;
        }
    }
}

/// Filenames listed in §8a (active) of wpt-conformance.md.
/// § = U+00A7 = 0xC2 0xA7 in UTF-8.
fn section8aFilenames(allocator: std.mem.Allocator, md: []const u8) ![][]const u8 {
    const a_marker = "### \xc2\xa78a";
    const b_marker = "### \xc2\xa78b";
    const a_pos = std.mem.indexOf(u8, md, a_marker) orelse return error.Section8aNotFound;
    const b_rel = std.mem.indexOf(u8, md[a_pos..], b_marker) orelse (md.len - a_pos);
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try extractJsFilenames(allocator, md[a_pos .. a_pos + b_rel], &list);
    return list.toOwnedSlice(allocator);
}

/// Filenames listed in §8b (deferred) of wpt-conformance.md.
fn section8bFilenames(allocator: std.mem.Allocator, md: []const u8) ![][]const u8 {
    const b_marker = "### \xc2\xa78b";
    const b_pos = std.mem.indexOf(u8, md, b_marker) orelse return error.Section8bNotFound;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    try extractJsFilenames(allocator, md[b_pos..], &list);
    return list.toOwnedSlice(allocator);
}

/// Filenames from `.filename = "..."` literals in tests/wpt_runner.zig.
fn runnerFilenames(allocator: std.mem.Allocator, src: []const u8) ![][]const u8 {
    const needle = ".filename = \"";
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (std.mem.indexOf(u8, src[i..], needle)) |off| {
        i += off + needle.len;
        const start = i;
        while (i < src.len and src[i] != '"') i += 1;
        try list.append(allocator, src[start..i]);
    }
    return list.toOwnedSlice(allocator);
}

/// Count `.name = "..."` literals in tests/test262_runner.zig.
fn test262Count(src: []const u8) usize {
    const needle = ".name = \"";
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOf(u8, src[i..], needle)) |off| {
        i += off + needle.len;
        n += 1;
    }
    return n;
}

const HeaderCounts = struct { wpt: usize, t262: usize };

/// Parse the two integers from the §8 header note:
///   "N active curated WPT cases pass via … M Test262 cases pass via …"
fn headerCounts(md: []const u8) !HeaderCounts {
    const wpt_suffix = " active curated WPT cases";
    const t262_suffix = " Test262 cases";

    const wpt_pos = std.mem.indexOf(u8, md, wpt_suffix) orelse return error.WptMarkerNotFound;
    const t262_pos = std.mem.indexOf(u8, md, t262_suffix) orelse return error.T262MarkerNotFound;

    const wpt_n = blk: {
        var j = wpt_pos;
        const end = j;
        while (j > 0 and std.ascii.isDigit(md[j - 1])) j -= 1;
        break :blk try std.fmt.parseInt(usize, md[j..end], 10);
    };
    const t262_n = blk: {
        var j = t262_pos;
        const end = j;
        while (j > 0 and std.ascii.isDigit(md[j - 1])) j -= 1;
        break :blk try std.fmt.parseInt(usize, md[j..end], 10);
    };
    return .{ .wpt = wpt_n, .t262 = t262_n };
}

fn strLt(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

test "§8 ↔ curated_cases alignment" {
    const ally = std.testing.allocator;
    const io = std.testing.io;

    const md = try std.Io.Dir.readFileAlloc(
        .cwd(), io, "spec/subspecs/wpt-conformance.md", ally, .limited(512 * 1024),
    );
    defer ally.free(md);
    const wpt_src = try std.Io.Dir.readFileAlloc(
        .cwd(), io, "tests/wpt_runner.zig", ally, .limited(4 * 1024 * 1024),
    );
    defer ally.free(wpt_src);
    const t262_src = try std.Io.Dir.readFileAlloc(
        .cwd(), io, "tests/test262_runner.zig", ally, .limited(512 * 1024),
    );
    defer ally.free(t262_src);

    const active_doc = try section8aFilenames(ally, md);
    defer ally.free(active_doc);
    const deferred_doc = try section8bFilenames(ally, md);
    defer ally.free(deferred_doc);
    const active_runner = try runnerFilenames(ally, wpt_src);
    defer ally.free(active_runner);
    const t262_n = test262Count(t262_src);
    const hdr = try headerCounts(md);

    std.mem.sort([]const u8, active_doc, {}, strLt);
    std.mem.sort([]const u8, active_runner, {}, strLt);

    // A: §8a active set equals curated_cases filenames.
    if (active_doc.len != active_runner.len) {
        for (active_runner) |f| {
            const ok = for (active_doc) |d| {
                if (std.mem.eql(u8, f, d)) break true;
            } else false;
            if (!ok) std.debug.print("\n  in runner but not §8a: {s}\n", .{f});
        }
        for (active_doc) |d| {
            const ok = for (active_runner) |f| {
                if (std.mem.eql(u8, f, d)) break true;
            } else false;
            if (!ok) std.debug.print("\n  in §8a but not runner: {s}\n", .{d});
        }
    }
    try std.testing.expectEqual(active_runner.len, active_doc.len);
    for (active_doc, active_runner) |d, r| try std.testing.expectEqualStrings(r, d);

    // B: §8b deferred set is disjoint from §8a active set.
    for (deferred_doc) |def| {
        for (active_doc) |act| {
            if (std.mem.eql(u8, def, act)) {
                std.debug.print("\n  '{s}' appears in both §8a and §8b\n", .{def});
                return error.DuplicateInBothSections;
            }
        }
    }

    // C: header-note WPT count equals curated_cases.len.
    if (hdr.wpt != active_runner.len)
        std.debug.print("\n  §8 header: {d} WPT cases; runner: {d}\n", .{ hdr.wpt, active_runner.len });
    try std.testing.expectEqual(active_runner.len, hdr.wpt);

    // D: header-note Test262 count equals test262_runner count.
    if (hdr.t262 != t262_n)
        std.debug.print("\n  §8 header: {d} Test262 cases; runner: {d}\n", .{ hdr.t262, t262_n });
    try std.testing.expectEqual(t262_n, hdr.t262);

    // E: every deferred entry is "(not yet written)" or exists under tests/wpt/.
    const b_pos = std.mem.indexOf(u8, md, "### \xc2\xa78b") orelse return error.Section8bNotFound;
    for (deferred_doc) |def| {
        var rows = std.mem.splitScalar(u8, md[b_pos..], '\n');
        var ok = false;
        while (rows.next()) |row| {
            if (std.mem.indexOf(u8, row, def) == null) continue;
            if (std.mem.indexOf(u8, row, "(not yet written)") != null) {
                ok = true;
                break;
            }
            const path = try std.fmt.allocPrint(ally, "tests/wpt/{s}", .{def});
            defer ally.free(path);
            if (std.Io.Dir.openFile(.cwd(), io, path, .{})) |f| {
                f.close(io);
                ok = true;
            } else |e| switch (e) {
                error.FileNotFound => {
                    std.debug.print(
                        "\n  §8b '{s}': not '(not yet written)' and file not found\n",
                        .{def},
                    );
                    return error.DeferredEntryInvalid;
                },
                else => return e,
            }
            break;
        }
        if (!ok) {
            std.debug.print("\n  §8b: no row found for '{s}'\n", .{def});
            return error.DeferredRowMissing;
        }
    }
}
