const std = @import("std");
const dom = @import("dom/node.zig");

pub const Metrics = struct {
    text_bytes: usize = 0,
    link_text_bytes: usize = 0,
    paragraph_count: usize = 0,
    punctuation_count: usize = 0,
    element_count: usize = 0,
    link_count: usize = 0,
    table_row_count: usize = 0,
    boilerplate_hits: usize = 0,

    pub fn linkDensity(self: Metrics) f64 {
        if (self.text_bytes == 0) return if (self.link_text_bytes > 0) 1.0 else 0.0;
        return @as(f64, @floatFromInt(self.link_text_bytes)) / @as(f64, @floatFromInt(self.text_bytes));
    }

    pub fn punctuationDensity(self: Metrics) f64 {
        if (self.text_bytes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.punctuation_count)) / @as(f64, @floatFromInt(self.text_bytes));
    }

    pub fn textDensity(self: Metrics) f64 {
        const denom = @max(self.element_count, 1);
        return @as(f64, @floatFromInt(self.text_bytes)) / @as(f64, @floatFromInt(denom));
    }
};

pub fn chooseContentRoot(doc: *const dom.Document) ?*const dom.Element {
    const body = doc.body() orelse return doc.htmlElement();

    if (findFirstByTag(body, "main")) |elem| {
        if (bestLinkListContainer(elem)) |inner| return inner;
        return elem;
    }
    if (findFirstByTag(body, "article")) |elem| {
        if (bestLinkListContainer(elem)) |inner| return inner;
        return elem;
    }
    if (findFirstByRole(body, "main")) |elem| {
        if (bestLinkListContainer(elem)) |inner| return inner;
        return elem;
    }
    if (bestLinkListContainer(body)) |elem| return elem;

    const best = bestScoringContainer(body);
    if (best.elem) |elem| {
        if (best.score >= 6.0) return elem;
    }
    return body;
}

pub fn analyzeElement(elem: *const dom.Element) Metrics {
    var metrics = Metrics{};
    collectMetrics(elem, false, &metrics);
    return metrics;
}

pub fn isBoilerplateRegion(elem: *const dom.Element) bool {
    if (!isRegionCandidate(elem.tag)) return false;

    if (isBoilerplateTag(elem.tag)) return true;

    const metrics = analyzeElement(elem);
    if (metrics.boilerplate_hits >= 2) return true;
    if (metrics.linkDensity() >= 0.65 and metrics.paragraph_count == 0) return true;
    if ((eql(elem.tag, "header") or eql(elem.tag, "aside")) and metrics.linkDensity() >= 0.5 and metrics.paragraph_count <= 1) {
        return true;
    }
    return false;
}

pub fn shouldSkipForBrowse(elem: *const dom.Element) bool {
    if (isBoilerplateRegion(elem)) {
        const metrics = analyzeElement(elem);
        return metrics.linkDensity() >= 0.55 or metrics.text_bytes < 120;
    }
    return false;
}

pub fn shouldCollapseForBrowse(elem: *const dom.Element) bool {
    const metrics = analyzeElement(elem);
    if (eql(elem.tag, "nav") or eql(elem.tag, "footer")) return true;
    if (eql(elem.tag, "aside")) return isBoilerplateRegion(elem) or metrics.linkDensity() >= 0.35;
    if (eql(elem.tag, "header")) return isBoilerplateRegion(elem) and metrics.linkDensity() >= 0.4;
    return false;
}

fn bestScoringContainer(root: *const dom.Element) BestCandidate {
    var best = BestCandidate{ .elem = null, .score = -9999.0 };
    visitContainerCandidates(root, &best);
    return best;
}

fn bestLinkListContainer(root: *const dom.Element) ?*const dom.Element {
    var best = BestCandidate{ .elem = null, .score = -9999.0 };
    visitLinkListCandidates(root, &best);
    if (best.score >= 8.0) return best.elem;
    return null;
}

fn visitContainerCandidates(elem: *const dom.Element, best: *BestCandidate) void {
    if (isScoringContainer(elem)) {
        const score = scoreContainer(elem);
        if (score > best.score) {
            best.* = .{ .elem = elem, .score = score };
        }
    }

    for (elem.children.items) |child| {
        if (child == .element) visitContainerCandidates(child.element, best);
    }
}

fn visitLinkListCandidates(elem: *const dom.Element, best: *BestCandidate) void {
    if (isLinkListCandidate(elem)) {
        const score = scoreLinkListContainer(elem);
        if (score > best.score) {
            best.* = .{ .elem = elem, .score = score };
        }
    }

    for (elem.children.items) |child| {
        if (child == .element) visitLinkListCandidates(child.element, best);
    }
}

fn scoreContainer(elem: *const dom.Element) f64 {
    const metrics = analyzeElement(elem);
    var score: f64 = 0.0;

    score += @as(f64, @floatFromInt(metrics.paragraph_count)) * 3.0;
    score += @min(12.0, @as(f64, @floatFromInt(metrics.text_bytes)) / 180.0);
    score += @min(6.0, metrics.punctuationDensity() * 80.0);
    score -= @min(10.0, metrics.linkDensity() * 14.0);
    score -= @as(f64, @floatFromInt(metrics.boilerplate_hits)) * 4.0;

    if (eql(elem.tag, "article")) score += 2.5;
    if (eql(elem.tag, "main")) score += 2.0;
    if (eql(elem.tag, "section")) score += 0.75;
    if (eql(elem.tag, "body")) score -= 6.0;
    if (metrics.paragraph_count == 0) score -= 2.0;
    if (metrics.text_bytes < 140) score -= 2.0;
    if (metrics.linkDensity() >= 0.55) score -= 6.0;

    return score;
}

fn scoreLinkListContainer(elem: *const dom.Element) f64 {
    const metrics = analyzeElement(elem);
    if (metrics.link_count < 6 or metrics.table_row_count < 4 or metrics.text_bytes < 80) return -9999.0;

    const link_density = metrics.linkDensity();
    if (link_density < 0.35 or link_density > 0.98) return -9999.0;

    var score: f64 = 0.0;
    score += @as(f64, @floatFromInt(metrics.table_row_count)) * 0.9;
    score += @min(10.0, @as(f64, @floatFromInt(metrics.link_count)) * 0.5);
    score += @min(6.0, @as(f64, @floatFromInt(metrics.text_bytes)) / 120.0);
    score -= @as(f64, @floatFromInt(metrics.boilerplate_hits)) * 4.0;

    if (eql(elem.tag, "td")) score += 3.0;
    if (eql(elem.tag, "tbody")) score += 1.5;
    if (eql(elem.tag, "tr")) score += 1.0;
    if (metrics.paragraph_count > 0) score -= 1.5;

    return score;
}

fn collectMetrics(elem: *const dom.Element, in_link: bool, metrics: *Metrics) void {
    metrics.element_count += 1;
    if (eql(elem.tag, "a")) metrics.link_count += 1;
    if (eql(elem.tag, "p")) metrics.paragraph_count += 1;
    if (eql(elem.tag, "tr")) metrics.table_row_count += 1;
    if (hasBoilerplateToken(elem)) metrics.boilerplate_hits += 1;

    const child_in_link = in_link or eql(elem.tag, "a");
    for (elem.children.items) |child| {
        switch (child) {
            .text => |text_node| {
                for (text_node.data) |ch| {
                    if (std.ascii.isWhitespace(ch)) continue;
                    metrics.text_bytes += 1;
                    if (child_in_link) metrics.link_text_bytes += 1;
                    if (isPunctuation(ch)) metrics.punctuation_count += 1;
                }
            },
            .element => |child_elem| collectMetrics(child_elem, child_in_link, metrics),
            else => {},
        }
    }
}

fn findFirstByTag(elem: *const dom.Element, tag: []const u8) ?*const dom.Element {
    if (eql(elem.tag, tag)) return elem;
    for (elem.children.items) |child| {
        if (child == .element) {
            if (findFirstByTag(child.element, tag)) |found| return found;
        }
    }
    return null;
}

fn findFirstByRole(elem: *const dom.Element, role: []const u8) ?*const dom.Element {
    if (elem.getAttribute("role")) |elem_role| {
        if (std.ascii.eqlIgnoreCase(elem_role, role)) return elem;
    }
    for (elem.children.items) |child| {
        if (child == .element) {
            if (findFirstByRole(child.element, role)) |found| return found;
        }
    }
    return null;
}

fn isScoringContainer(elem: *const dom.Element) bool {
    return eql(elem.tag, "body") or eql(elem.tag, "main") or eql(elem.tag, "article") or eql(elem.tag, "section") or eql(elem.tag, "div");
}

fn isLinkListCandidate(elem: *const dom.Element) bool {
    return eql(elem.tag, "td") or eql(elem.tag, "tbody") or eql(elem.tag, "tr") or eql(elem.tag, "div") or eql(elem.tag, "section");
}

fn isRegionCandidate(tag: []const u8) bool {
    return eql(tag, "body") or eql(tag, "main") or eql(tag, "article") or eql(tag, "section") or eql(tag, "div") or eql(tag, "header") or eql(tag, "nav") or eql(tag, "aside") or eql(tag, "footer");
}

fn isBoilerplateTag(tag: []const u8) bool {
    return eql(tag, "nav") or eql(tag, "footer");
}

fn hasBoilerplateToken(elem: *const dom.Element) bool {
    if (containsBoilerplateToken(elem.tag)) return true;
    if (elem.getAttribute("id")) |id| {
        if (containsBoilerplateToken(id)) return true;
    }
    if (elem.getAttribute("class")) |class_name| {
        if (containsBoilerplateToken(class_name)) return true;
    }
    return false;
}

fn containsBoilerplateToken(text: []const u8) bool {
    inline for (.{
        "nav",
        "menu",
        "footer",
        "header",
        "sidebar",
        "aside",
        "breadcrumb",
        "breadcrumbs",
        "share",
        "social",
        "promo",
        "banner",
        "related",
        "subscribe",
        "newsletter",
        "pagination",
    }) |token| {
        if (containsIgnoreCase(text, token)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isPunctuation(ch: u8) bool {
    return switch (ch) {
        '.', ',', ';', ':', '!', '?', '"', '\'' => true,
        else => false,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "chooseContentRoot prefers main over nav noise" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <nav><a href="/a">A</a><a href="/b">B</a><a href="/c">C</a></nav>
        \\  <main><p>Lead sentence. Enough punctuation, context, and body text.</p><p>Another content paragraph.</p></main>
        \\</body></html>
    );
    defer doc.deinit();

    const root = chooseContentRoot(&doc) orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("main", root.tag);
}

test "chooseContentRoot prefers article over sidebar-like containers" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <div class="sidebar related"><a href="/1">One</a><a href="/2">Two</a><a href="/3">Three</a></div>
        \\  <article><p>This is the article body. It has sentences, punctuation, and density.</p><p>It should win.</p></article>
        \\</body></html>
    );
    defer doc.deinit();

    const root = chooseContentRoot(&doc) orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("article", root.tag);
}

test "chooseContentRoot falls back to highest scoring container" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <div class="nav-links"><a href="/a">Nav</a></div>
        \\  <div id="story"><p>Primary content lives here. It has two sentences.</p><p>Second paragraph.</p></div>
        \\</body></html>
    );
    defer doc.deinit();

    const root = chooseContentRoot(&doc) orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("story", root.getAttribute("id").?);
}

test "chooseContentRoot prefers inner link-list cell for HN-like tables" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table><tr><td class="nav"><a href="/new">new</a><a href="/past">past</a></td></tr><tr><td id="stories">
        \\  <table>
        \\    <tr><td><a href="https://example.com/1">Alpha story title with enough words to look like content</a></td></tr>
        \\    <tr><td>42 points by alice | <a href="item?id=1">12 comments</a></td></tr>
        \\    <tr><td><a href="https://example.com/2">Beta story title with enough words to look like content</a></td></tr>
        \\    <tr><td>21 points by bob | <a href="item?id=2">8 comments</a></td></tr>
        \\    <tr><td><a href="https://example.com/3">Gamma story title with enough words to look like content</a></td></tr>
        \\    <tr><td>15 points by carol | <a href="item?id=3">5 comments</a></td></tr>
        \\  </table>
        \\</td></tr></table></body></html>
    );
    defer doc.deinit();

    const root = chooseContentRoot(&doc) orelse return error.SkipZigTest;
    try std.testing.expectEqualStrings("stories", root.getAttribute("id").?);
}
const BestCandidate = struct {
    elem: ?*const dom.Element,
    score: f64,
};
