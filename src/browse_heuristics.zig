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
    const candidate = pickContentCandidate(body);

    // T-72 — preserve interactive forms.
    //
    // The candidate may be a content-only sub-region that excludes
    // the page's primary form. For "form-centric" pages — Google,
    // DuckDuckGo, login pages, search engines — the form *is* the
    // page; pruning it away leaves a useless render with no input
    // box and no submit button.
    //
    // Rule: if `body` contains a non-trivial form (any
    // user-editable input or submit button) that is *not* an
    // ancestor- or descendant-relation to the chosen candidate,
    // fall back to body. Trivial forms (e.g. a hidden newsletter
    // signup nested in a footer) don't trigger fallback because
    // they have no editable surface.
    //
    // The candidate stays as-chosen when it already contains the
    // form, OR when there's no form at all (the heuristic's
    // existing behavior is correct for article pages).
    if (candidate != body and bodyHasFormOutside(body, candidate)) {
        return body;
    }

    return candidate;
}

/// Inner helper for `chooseContentRoot` — runs the historical
/// content-picking logic without the form-preservation guard. Lets
/// the guard layer above this function compose cleanly.
fn pickContentCandidate(body: *const dom.Element) *const dom.Element {
    if (findFirstByTag(body, "main")) |elem| {
        if (hasMeaningfulContent(elem)) {
            if (preferLinkListInsideContainer(elem)) |inner| return inner;
            return elem;
        }
    }
    if (findFirstByTag(body, "article")) |elem| {
        if (hasMeaningfulContent(elem)) {
            if (preferLinkListInsideContainer(elem)) |inner| return inner;
            return elem;
        }
    }
    if (findFirstByRole(body, "main")) |elem| {
        if (hasMeaningfulContent(elem)) {
            if (preferLinkListInsideContainer(elem)) |inner| return inner;
            return elem;
        }
    }
    if (preferLinkListInsideContainer(body)) |elem| return elem;

    const best = bestScoringContainer(body);
    if (best.elem) |elem| {
        if (best.score >= 6.0) return elem;
    }
    return body;
}

/// Walk the subtree rooted at `body` looking for any user-editable
/// form control (`input` text-like / textarea / select / submit
/// button) that is **not** inside `candidate`. Returns true if
/// such a control exists — meaning the candidate would prune
/// interactive surface area the user expects.
///
/// Hidden inputs are skipped — they're CSRF round-trip helpers,
/// not user-facing controls. Forms-with-only-hidden-fields don't
/// trigger fallback.
fn bodyHasFormOutside(body: *const dom.Element, candidate: *const dom.Element) bool {
    return walkLooksForOutsideForm(body, candidate);
}

fn walkLooksForOutsideForm(elem: *const dom.Element, candidate: *const dom.Element) bool {
    if (elem == candidate) return false; // skip subtree under candidate
    if (isUserVisibleFormControl(elem)) return true;
    for (elem.children.items) |child| {
        if (child == .element) {
            if (walkLooksForOutsideForm(child.element, candidate)) return true;
        }
    }
    return false;
}

fn isUserVisibleFormControl(elem: *const dom.Element) bool {
    if (eql(elem.tag, "textarea")) return true;
    if (eql(elem.tag, "select")) return true;
    if (eql(elem.tag, "button")) return true;
    if (eql(elem.tag, "input")) {
        const t = elem.getAttribute("type") orelse "text";
        // Hidden inputs are CSRF round-trip helpers — ignore them.
        if (std.ascii.eqlIgnoreCase(t, "hidden")) return false;
        return true;
    }
    return false;
}

/// Wraps `bestLinkListContainer` with a "the inner candidate must dominate
/// the outer's text content" guard. Without this, real pages that put a
/// link-dense table (Wikipedia infobox/cladogram, navbox, sidebar) inside
/// `<main>` get their entire article body discarded because the
/// link-list scorer ranks the small fragment higher than the full body.
///
/// The HN-style case still works: HN's body IS the story-list table, so
/// the inner candidate's text genuinely dominates body's. The guard
/// rejects the override only when the inner is a fragment.
fn preferLinkListInsideContainer(outer: *const dom.Element) ?*const dom.Element {
    const inner = bestLinkListContainer(outer) orelse return null;
    const inner_metrics = analyzeElement(inner);
    const outer_metrics = analyzeElement(outer);
    if (outer_metrics.text_bytes == 0) return inner;
    const share = @as(f64, @floatFromInt(inner_metrics.text_bytes)) /
        @as(f64, @floatFromInt(outer_metrics.text_bytes));
    // 0.6 chosen empirically: HN's story-list cell is ~95% of body text;
    // Wikipedia's largest cladogram tbody is ~3% of <main> text. Anything
    // in between is rare enough that rejecting the override is safer than
    // accepting it. Tune if a real page demonstrates otherwise.
    if (share < 0.6) return null;
    return inner;
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
    if (!isBoilerplateRegion(elem)) return false;
    const metrics = analyzeElement(elem);

    // Semantic <main> escape hatch: inside <main>, trust the author and only
    // prune on EXPLICIT signals — boilerplate-named tags (nav/footer) or an
    // explicit boilerplate class/id hit on this element ("related",
    // "newsletter", "sidebar", etc.). Drop the density-only and tiny-text
    // heuristics for descendants of <main>: app-shell SSR (Next.js,
    // SvelteKit) emits card grids with high per-card link density that
    // look like nav noise to those signals but are the actual page content.
    // See `.opencode/plans/1777121633483-neon-meadow.md` for the original
    // investigation.
    if (hasAncestorTag(elem, "main")) {
        return isBoilerplateTag(elem.tag) or hasBoilerplateToken(elem);
    }

    return metrics.linkDensity() >= 0.55 or metrics.text_bytes < 120;
}

fn hasAncestorTag(elem: *const dom.Element, tag: []const u8) bool {
    var cur = elem.parent;
    while (cur) |p| : (cur = p.parent) {
        if (eql(p.tag, tag)) return true;
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

fn hasMeaningfulContent(elem: *const dom.Element) bool {
    const metrics = analyzeElement(elem);
    return metrics.text_bytes > 0 or metrics.link_count > 0 or metrics.table_row_count > 0;
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
    return eql(tag, "body") or eql(tag, "main") or eql(tag, "article") or eql(tag, "section") or eql(tag, "header") or eql(tag, "nav") or eql(tag, "aside") or eql(tag, "footer");
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

test "chooseContentRoot ignores empty main and falls back to useful body content" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><main></main><div id=\"fallback\"><p>Useful fallback content appears outside the empty app shell. It has enough words, punctuation, and context to be selected.</p><p>A second paragraph confirms this is readable page content.</p></div></body></html>");
    defer doc.deinit();

    const root = chooseContentRoot(&doc) orelse return error.SkipZigTest;
    try std.testing.expect(!std.ascii.eqlIgnoreCase(root.tag, "main"));
    try std.testing.expectEqualStrings("fallback", root.getAttribute("id").?);
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

test "shouldSkipForBrowse — link-dense card inside <main> is preserved" {
    // App-shell regression case (per .opencode/plans/1777121633483-neon-meadow.md):
    // pages like NVIDIA's models grid emit SSR cards with many links each,
    // pushing per-card link density above 0.55. Without the <main> escape
    // hatch in shouldSkipForBrowse, those cards get pruned and the page
    // renders blank in the TUI even though the DOM contains real content.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><main><section class="cards">
        \\  <article><a href="/m/1">Model 1</a><a href="/m/1/details">Details</a></article>
        \\  <article><a href="/m/2">Model 2</a><a href="/m/2/details">Details</a></article>
        \\</section></main></body></html>
    );
    defer doc.deinit();

    const cards = doc.querySelector("section") orelse return error.SkipZigTest;
    // Without the <main> escape hatch, this card grid hits the
    // `linkDensity() >= 0.55` branch in shouldSkipForBrowse and gets pruned.
    try std.testing.expect(!shouldSkipForBrowse(cards));

    const article = doc.querySelector("article") orelse return error.SkipZigTest;
    try std.testing.expect(!shouldSkipForBrowse(article));
}

test "shouldSkipForBrowse — link-dense aside outside <main> still pruned" {
    // Negative regression: the escape hatch must be limited to <main>
    // descendants. A link-dense <aside> at the body level is still
    // boilerplate and should be pruned, otherwise we'd start rendering
    // sidebars on content-focused pages.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <main><p>The real article content sits here with enough words to qualify.</p></main>
        \\  <aside class="related"><a href="/a">A</a><a href="/b">B</a><a href="/c">C</a><a href="/d">D</a></aside>
        \\</body></html>
    );
    defer doc.deinit();

    const aside = doc.querySelector("aside") orelse return error.SkipZigTest;
    try std.testing.expect(shouldSkipForBrowse(aside));
}

test "chooseContentRoot keeps <main> when a clade table is a fragment of it" {
    // Wikipedia regression case (per the corpus harness's wikipedia_octopus
    // signal). Real Wikipedia featured articles emit a long article body
    // PLUS a "clade" taxonomy table with many <tr> rows that mix link text
    // with non-link labels (so linkDensity stays in scoreLinkListContainer's
    // valid (0.35, 0.98) range). Without an outer-domination guard,
    // bestLinkListContainer scored the clade table high enough to override
    // <main> as the chosen root, dropping the article body from the render.
    // Fix: only return the link-list override when the inner candidate's
    // text dominates the outer's (i.e. the page IS a link list, not just
    // contains one).
    // The clade rows below are deliberately tuned to match real Wikipedia's
    // metrics: each row is a short label plus a long anchor, pushing
    // linkDensity into scoreLinkListContainer's valid (0.35, 0.98) range
    // so the candidate scores high. Without the dominance guard, this
    // test fails — the regression is real, not synthetic-only.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><main>
        \\  <article>
        \\    <h1>Octopus</h1>
        \\    <p>The octopus is a soft-bodied, eight-limbed mollusc of the order Octopoda. Around 300 species are recognised, grouped within the class Cephalopoda with squids, cuttlefish, and nautiloids.</p>
        \\    <p>Like other cephalopods, an octopus is bilaterally symmetric with two eyes and a beaked mouth at the centre point of the eight limbs. The soft body can rapidly alter its shape, enabling octopuses to squeeze through small gaps.</p>
        \\    <p>They trail their eight appendages behind them as they swim. The siphon is used both for respiration and for locomotion, by expelling a jet of water. Octopuses have a complex nervous system and excellent sight, and are among the most intelligent and behaviourally diverse of all invertebrates.</p>
        \\    <p>Octopuses inhabit various regions of the ocean, including coral reefs, pelagic waters, and the seabed; some live in the intertidal zone, and others at abyssal depths. Most species grow quickly, mature early, and are short-lived.</p>
        \\    <p>The earliest known octopus is Pohlsepia, which lived approximately 296 million years ago and is preserved as an impression in shale.</p>
        \\  </article>
        \\  <table class="clade">
        \\    <tbody>
        \\      <tr><td>k:</td><td><a href="/c1">Cephalopoda subclass Coleoidea</a></td></tr>
        \\      <tr><td>p:</td><td><a href="/c2">Decapodiformes superorder Sepia</a></td></tr>
        \\      <tr><td>c:</td><td><a href="/c3">Octopodiformes superorder Vampyroteuthis</a></td></tr>
        \\      <tr><td>o:</td><td><a href="/c4">Octopoda Cirrina suborder deepsea</a></td></tr>
        \\      <tr><td>o:</td><td><a href="/c5">Octopoda Incirrina suborder shallow</a></td></tr>
        \\      <tr><td>f:</td><td><a href="/c6">Cirroteuthidae Stauroteuthidae family</a></td></tr>
        \\      <tr><td>f:</td><td><a href="/c7">Octopodidae Bathypolypodidae family</a></td></tr>
        \\      <tr><td>f:</td><td><a href="/c8">Enteroctopodidae Megaleledonidae family</a></td></tr>
        \\      <tr><td>f:</td><td><a href="/c9">Bolitaenidae Amphitretidae Vitreledonellidae</a></td></tr>
        \\      <tr><td>f:</td><td><a href="/c10">Tremoctopodidae Alloposidae Argonautidae</a></td></tr>
        \\      <tr><td>f:</td><td><a href="/c11">Ocythoidae Octopodoidea Eledonidae family</a></td></tr>
        \\      <tr><td>f:</td><td><a href="/c12">Opisthoteuthidae Cirroctopodidae family</a></td></tr>
        \\    </tbody>
        \\  </table>
        \\</main></body></html>
    );
    defer doc.deinit();

    const root = chooseContentRoot(&doc) orelse return error.SkipZigTest;
    // The root must NOT be the clade table or any of its descendants.
    try std.testing.expect(!std.ascii.eqlIgnoreCase(root.tag, "tbody"));
    try std.testing.expect(!std.ascii.eqlIgnoreCase(root.tag, "tr"));
    try std.testing.expect(!std.ascii.eqlIgnoreCase(root.tag, "td"));
    try std.testing.expect(!std.ascii.eqlIgnoreCase(root.tag, "table"));
    // Affirmative: the root must contain the article body's text.
    const text = try root.textContent(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "soft-bodied") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Pohlsepia") != null);
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
