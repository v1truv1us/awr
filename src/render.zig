/// render.zig — Structured terminal text renderer for AWR.
///
/// Walks a DOM tree and produces formatted terminal output suitable for
/// display in a monospaced terminal.  Supports:
///
///   - Decorative headings (h1-h6) with ANSI bold/underline
///   - Word-wrapped paragraphs at a configurable max width
///   - Reference-style link footnotes (e.g. "text[1]" with "[1]: url")
///   - Ordered and unordered lists with proper nesting/indentation
///   - Blockquotes (indented, dimmed)
///   - Preserved whitespace in <pre> blocks
///   - Horizontal rules, line breaks, inline code, images
///   - Inline strong/emphasis with ANSI styling
///   - Simple table formatting with aligned columns
///   - Skipping of invisible elements (script, style, head, etc.)
///
/// Known limitation: nested ANSI formatting (e.g. bold link inside italic
/// paragraph) may not restore the outer style correctly because ANSI SGR
/// codes are not stacked.  This is acceptable for a terminal browser.
const std = @import("std");
const dom = @import("dom/node.zig");
const browse_heuristics = @import("browse_heuristics.zig");
const css_parser = @import("cssom/parser.zig");
const css_style = @import("cssom/style.zig");
const css_cascade = @import("cssom/cascade.zig");
const image_protocol = @import("image_protocol");

// ── Public types ──────────────────────────────────────────────────────────

pub const RenderProfile = enum {
    default,
    browse,
};

/// Pre-computed image bytes lookup. Built before rendering by walking
/// the DOM, fetching every `<img src>`, decoding via stb_image, and
/// encoding to the resolved protocol's byte format (Kitty APC, iTerm
/// OSC-1337, Sixel, or UTF-8 braille glyphs). The renderer queries this
/// at `<img>` emit-time; if `getFn` returns non-null, those bytes go to
/// the output verbatim and the alt-text/footnote fallback is skipped.
///
/// Decoupled from `image_protocol` because the renderer doesn't care
/// *which* protocol — only whether bytes are available. Keeps render.zig
/// free of stb_image / encoder dependencies; the protocol-specific
/// machinery lives in `src/image/{kitty,iterm,sixel,braille}.zig` and is
/// wired from main.zig / browser.zig.
pub const ImageLookup = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, url: []const u8) ?[]const u8,
    /// T5: optional cell-row count for a URL's encoded image. The browse
    /// model uses it to reserve the image's vertical footprint (single-blob
    /// kitty/iterm/sixel images are one model line but occupy `r` terminal
    /// rows). `null` (the default) means "unknown" — no rows are reserved,
    /// preserving the behavior of lookups that don't carry dimensions.
    rowsFn: ?*const fn (ctx: *const anyopaque, url: []const u8) ?u32 = null,

    pub fn get(self: ImageLookup, url: []const u8) ?[]const u8 {
        return self.getFn(self.ctx, url);
    }

    pub fn rows(self: ImageLookup, url: []const u8) ?u32 {
        const f = self.rowsFn orelse return null;
        return f(self.ctx, url);
    }
};

/// T2.4/T2.5: code-block styling mode for `<pre><code>` blocks.
/// `.none` — no highlighting (plain text, line numbers only).
/// `.auto` — detect language from `class="language-XYZ"` and highlight.
/// `.tag`  — always highlight using only the class-hint tag, no fallback.
pub const CodeStyle = enum { none, auto, tag };

/// T2.5: programming language inferred from `class="language-XYZ"`.
const Language = enum { unknown, zig, rust, js, ts, python, html, json, sh };

pub const RenderOptions = struct {
    max_width: usize = 80,
    ansi_colors: bool = true,
    show_links: bool = true,
    show_images: bool = true,
    /// Whether to emit a "References:" footer listing each [N] marker's
    /// URL. When `null`, the default tracks the profile: the `.default`
    /// profile emits the footer (matches the original render path), the
    /// `.browse` profile suppresses it (interactive mode treats links
    /// as hover/click targets, not footnotes). Set explicitly to `true`
    /// for non-interactive `awr render` output piped to a file or LLM,
    /// where orphan `[N]` markers without URLs are dead weight.
    show_references: ?bool = null,
    profile: RenderProfile = .default,
    /// Resolved terminal-image protocol. Default `.none` means no
    /// inline image emit; the renderer falls through to the text alt-ref
    /// path. The actual encoded bytes (the *what to emit*) come from
    /// `image_lookup`; this field carries the *what protocol* metadata
    /// for downstream use (telemetry, error messages, etc.).
    image_protocol: image_protocol.Protocol = .none,
    /// Pre-computed image-bytes lookup. When non-null and `<img src>`
    /// resolves to bytes, those bytes are emitted inline (raw — no
    /// column tracking, no escape mangling) and the alt-text fallback
    /// is skipped. When null, every `<img>` renders as `[alt][N]` —
    /// preserves `test-corpus` determinism since corpus tests never
    /// build a lookup.
    image_lookup: ?ImageLookup = null,
    /// Per-field user-typed-value override. When non-null,
    /// `renderInput` / `renderTextarea` query this lookup with the
    /// field's `name` attribute; if the lookup returns a value, it
    /// replaces the DOM's `value` attribute in the rendered box.
    /// Used by `awr browse` to show what the user has typed in a
    /// focused field as they type, instead of leaving the box empty
    /// while their text accumulates only in the status bar.
    field_value_lookup: ?FieldValueLookup = null,
    /// Pointer-equality identifier of the currently-focused element
    /// (typically `@intFromPtr(elem)` of a form control). When set,
    /// `renderInput` / `renderTextarea` / `renderButton` /
    /// `renderSelect` add a visible highlight (reverse video) to the
    /// matching field's rendered box so the user sees where Tab
    /// landed and where typing will go. `null` means "no focus
    /// highlight" — non-interactive `awr render` and corpus output
    /// stays clean.
    focused_element_ptr: ?usize = null,
    /// T-81: per-element checked-state override for checkbox / radio.
    /// When non-null, `renderInput` queries this with the input's
    /// `element_ptr`; non-null result wins over the DOM's `checked`
    /// attribute. Used by `awr browse` so toggled state shows
    /// immediately (`[x]` / `(*)`) without a re-fetch.
    is_checked_lookup: ?IsCheckedLookup = null,
    /// T-83: per-element selected-value override for `<select>`.
    /// When non-null, `renderSelect` queries this with the select's
    /// `element_ptr`; non-null result wins over the DOM's
    /// `<option selected>` attribute. Used by the inline picker so
    /// the chosen option shows immediately after closing the picker.
    selected_option_lookup: ?SelectedOptionLookup = null,
    /// T2.4: minimum line count before line numbers appear in `<pre><code>`
    /// blocks. 0 = always show; default 5 matches the spec default.
    /// Set to `std.math.maxInt(usize)` to disable entirely.
    code_line_numbers: usize = 5,
    /// T2.4/T2.5: syntax highlight style. `.none` = line numbers only.
    /// `.auto` / `.tag` activate highlighting (T2.5). Stored here so
    /// `awr render --code-style=auto` round-trips through RenderOptions.
    code_style: CodeStyle = .none,
    /// Stylesheet bodies loaded for the current document. The renderer uses
    /// these for the starter CSSOM subset so TUI output reflects simple
    /// `display` / `visibility` author CSS without requiring full layout.
    css_stylesheets: []const []const u8 = &.{},
    /// T2.6: treat every `<pre>` block as a unified diff. Set when
    /// `Content-Type: text/x-diff` or `text/x-patch` is present.
    /// Auto-detection via `looksLikeDiff` runs regardless.
    is_diff: bool = false,
};

pub const FieldValueLookup = struct {
    ctx: *anyopaque,
    lookup_fn: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,

    pub fn lookup(self: FieldValueLookup, name: []const u8) ?[]const u8 {
        return self.lookup_fn(self.ctx, name);
    }
};

pub const IsCheckedLookup = struct {
    ctx: *anyopaque,
    /// Returns true if the user has toggled this element ON, false if
    /// they've toggled it OFF, or null if they haven't touched it
    /// (in which case the renderer falls back to the DOM `checked`
    /// attribute).
    lookup_fn: *const fn (ctx: *anyopaque, element_ptr: usize) ?bool,

    pub fn lookup(self: IsCheckedLookup, element_ptr: usize) ?bool {
        return self.lookup_fn(self.ctx, element_ptr);
    }
};

pub const SelectedOptionLookup = struct {
    ctx: *anyopaque,
    /// Returns the user-selected option *label* (display text) for
    /// the given `<select>` element, or null when the user hasn't
    /// touched it (renderer falls back to DOM `<option selected>`).
    /// We return the label rather than the value because the
    /// renderer's job is display, not submission.
    lookup_fn: *const fn (ctx: *anyopaque, element_ptr: usize) ?[]const u8,

    pub fn lookup(self: SelectedOptionLookup, element_ptr: usize) ?[]const u8 {
        return self.lookup_fn(self.ctx, element_ptr);
    }
};

/// T2.8 — Label association contract:
/// `label` is populated for:
///   - `<button>` / `<input type="submit|reset|button">` — visible button text
///   - `<label>` elements — their rendered text content
/// For generic `<input>` / `<textarea>` / `<select>`, `label` is "" because
/// AWR does not yet traverse the DOM to find an associated `<label for="id">`
/// element at render time. The intended future contract is: if `getAttribute
/// ("id")` returns an id that matches a `<label for="...">` element, that
/// label's text is stored here. Status-bar rendering in browser.zig should
/// show `label` when non-empty and fall back to `name` otherwise.
pub const ScreenField = struct {
    index: usize,
    element_ptr: usize,
    name: []const u8,
    field_type: []const u8,
    label: []const u8,
    line: usize,
    col: usize,
    width: usize,
    is_submit: bool,

    pub fn deinit(self: *const ScreenField, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.field_type);
        allocator.free(self.label);
    }
};

pub const ScreenLink = struct {
    element_ptr: usize,
    index: usize,
    href: []const u8,
    text: []const u8,
    line: usize,
};

pub const ScreenRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const ScreenBox = struct {
    element_ptr: usize,
    rect: ScreenRect,
};

pub const ScreenLine = struct {
    start: usize,
    end: usize,
};

/// T2.7: position of a table header row in the ScreenModel line array.
/// The TUI viewport shows the header as a sticky overlay when scrolled past it.
pub const StickyHeader = struct {
    /// Line range [start, end) of the rendered header row (inclusive of
    /// any separator line that immediately follows the header cells).
    header_line_start: usize,
    header_line_end: usize,
    /// Exclusive end of the table body. Sticky is shown while
    /// `scroll_row ∈ [header_line_end, table_line_end)`.
    table_line_end: usize,
};

pub const ScreenModel = struct {
    allocator: std.mem.Allocator,
    text: []u8,
    lines: []ScreenLine,
    links: []ScreenLink,
    boxes: []ScreenBox,
    fields: []ScreenField,
    sticky_headers: []StickyHeader,

    pub fn deinit(self: *ScreenModel) void {
        for (self.links) |link| {
            self.allocator.free(link.href);
            self.allocator.free(link.text);
        }
        for (self.fields) |field| {
            field.deinit(self.allocator);
        }
        self.allocator.free(self.fields);
        self.allocator.free(self.boxes);
        self.allocator.free(self.links);
        self.allocator.free(self.lines);
        self.allocator.free(self.text);
        self.allocator.free(self.sticky_headers);
    }

    pub fn lineText(self: *const ScreenModel, index: usize) []const u8 {
        const line = self.lines[index];
        return self.text[line.start..line.end];
    }

    pub fn rectForElement(self: *const ScreenModel, elem: *const dom.Element) ?ScreenRect {
        const ptr = @intFromPtr(elem);
        for (self.boxes) |box| {
            if (box.element_ptr == ptr) return box.rect;
        }
        return null;
    }
};

// ── Internal types ────────────────────────────────────────────────────────

const FieldRef = struct {
    index: usize,
    element_ptr: usize,
    name: []const u8,
    field_type: []const u8,
    label: []const u8,
    line: usize,
    col: usize,
    width: usize,
    is_submit: bool,
};

const LinkRef = struct {
    element_ptr: usize,
    index: usize,
    href: []const u8,
    text: []const u8,
    line: usize,
};

/// A stylesheet rule that declares at least one renderer-mapped text property,
/// tagged with its cascade position (sheet + rule index) so precedence is
/// preserved when the per-element pass iterates the filtered subset.
const TextRuleRef = struct {
    rule: *const css_parser.Rule,
    source_index: usize,
    rule_index: usize,
};

const BoxRef = struct {
    element_ptr: usize,
    left: usize = 0,
    top: usize = 0,
    right: usize = 0,
    bottom: usize = 0,
    saw_content: bool = false,
};

const BufferWriter = struct {
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) !void {
        try self.list.append(self.allocator, byte);
    }
};

/// Mutable state threaded through every render call.
/// The `writer` is passed separately as `anytype` so the compiler
/// monomorphises each render function for the concrete writer type.
const RenderState = struct {
    allocator: std.mem.Allocator,
    opts: RenderOptions,
    /// When true, `isCssHidden` ignores the generic `[hidden]`-attribute
    /// `display:none` reset (Tailwind / modern-normalize) so JS-revealed
    /// content stays visible. Off by default — the renderer only sets it on a
    /// rescue re-render when the normal pass produced a blank page (e.g. a
    /// Next.js app whose entire body streams into a single `<div hidden>`).
    /// See `renderModelFromRoot`.
    relax_hidden_attr: bool = false,
    col: usize = 0,
    at_line_start: bool = true,
    line_index: usize = 0,
    pre_depth: usize = 0,
    hang_indent: usize = 0,
    /// §2.1: inter-word spacing carried ACROSS inline node boundaries.
    /// `renderTextNode` and inline elements (`<a>`, `<strong>`, …) all flow
    /// their words through `flowWord`, which consults and updates this flag.
    /// A text node ending in collapsed whitespace sets it; the next word —
    /// whether from the same node, a sibling text node, or an adjacent inline
    /// element — sees it and emits exactly one separating space (or wraps).
    /// Without this, the trailing space of "foo " before `<a>bar</a>` was
    /// dropped, rendering "foobar". Reset at every block/structural newline.
    pending_space: bool = false,
    links: std.ArrayListUnmanaged(LinkRef) = .empty,
    fields: std.ArrayListUnmanaged(FieldRef) = .empty,
    boxes: std.ArrayListUnmanaged(BoxRef) = .empty,
    active_boxes: std.ArrayListUnmanaged(usize) = .empty,
    sticky_hdrs: std.ArrayListUnmanaged(StickyHeader) = .empty,
    /// Author stylesheets parsed ONCE up front. `isCssHidden` and
    /// `isCssWhiteSpacePreserved` run per element, so re-parsing the
    /// sheets inside them was O(elements × sheets) and hung the renderer
    /// on pages with many sheets (Wikipedia ships 14). Mirrors the
    /// body_text fast-path fix in page.zig (commit f9baa84), which only
    /// covered the agent surface — this covers the render/TUI surface.
    parsed_sheets: std.ArrayListUnmanaged(css_parser.Stylesheet) = .empty,
    /// Pre-filtered rule indexes: only rules that can actually flip the
    /// per-element checks. Scanning every rule for every element is still
    /// O(elements × rules); these slices cut the inner loop to the handful
    /// of rules that declare the relevant property. Pointers index into
    /// `parsed_sheets[*].rules.items`, which is heap-stable after parsing.
    hide_rules: std.ArrayListUnmanaged(*const css_parser.Rule) = .empty,
    ws_rules: std.ArrayListUnmanaged(*const css_parser.Rule) = .empty,
    /// True when any author stylesheet declares a text property
    /// (color/font-weight/font-style/text-decoration/text-transform). When
    /// false and the element has no inline `style=`, `computeTextStyle` skips
    /// author-CSS resolution entirely — keeping the unstyled path cheap.
    has_text_css: bool = false,
    /// True when any author stylesheet declares `text-align`. Gates the
    /// single-line block alignment path (TUI only).
    has_align_css: bool = false,
    /// Pre-compiled selectors for `complex` rules (compound/combinator/attr),
    /// keyed by rule pointer. Built once at setup so the per-element render
    /// hot path matches them exactly via the full DOM selector engine without
    /// re-parsing per element (which timed out on large stylesheets).
    compiled_selectors: std.AutoHashMapUnmanaged(*const css_parser.Rule, dom.SelectorList) = .empty,
    /// Only the rules that declare a text property the renderer maps to ANSI,
    /// in cascade (source) order. The per-element style pass matches just
    /// these — large pages (Wikipedia) carry thousands of layout rules but few
    /// text rules, so this is what keeps exact complex-selector matching cheap.
    text_rules: std.ArrayListUnmanaged(TextRuleRef) = .empty,
    /// Whether the render path matches complex (compound/combinator/attribute)
    /// text rules *exactly* via the compiled selector engine. Exact matching
    /// walks the ancestor chain per element, which is too slow when a page
    /// carries many complex text rules (MediaWiki), so above a threshold the
    /// renderer falls back to the fast flat OR approximation. The script-facing
    /// getComputedStyle cascade is always exact regardless of this flag.
    exact_complex_selectors: bool = false,
    /// Computed inline text style for the element currently being rendered.
    /// Inherited by descendants; emitted as ANSI when `opts.ansi_colors`.
    cur_style: TextStyle = .{},

    fn deinit(self: *RenderState) void {
        for (self.links.items) |link| {
            self.allocator.free(link.href);
            self.allocator.free(link.text);
        }
        self.links.deinit(self.allocator);
        for (self.fields.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.field_type);
            self.allocator.free(field.label);
        }
        self.fields.deinit(self.allocator);
        self.boxes.deinit(self.allocator);
        self.active_boxes.deinit(self.allocator);
        self.sticky_hdrs.deinit(self.allocator);
        self.hide_rules.deinit(self.allocator);
        self.ws_rules.deinit(self.allocator);
        var cit = self.compiled_selectors.valueIterator();
        while (cit.next()) |list| list.deinit(self.allocator);
        self.compiled_selectors.deinit(self.allocator);
        self.text_rules.deinit(self.allocator);
        for (self.parsed_sheets.items) |*sheet| sheet.deinit();
        self.parsed_sheets.deinit(self.allocator);
    }

    fn beginElementBox(self: *RenderState, elem: *const dom.Element) !void {
        try self.boxes.append(self.allocator, .{ .element_ptr = @intFromPtr(elem) });
        try self.active_boxes.append(self.allocator, self.boxes.items.len - 1);
    }

    fn endElementBox(self: *RenderState) void {
        _ = self.active_boxes.pop();
    }

    fn noteCell(self: *RenderState, line: usize, col: usize) void {
        for (self.active_boxes.items) |idx| {
            var box = &self.boxes.items[idx];
            if (!box.saw_content) {
                box.left = col;
                box.top = line;
                box.right = col + 1;
                box.bottom = line + 1;
                box.saw_content = true;
                continue;
            }
            box.left = @min(box.left, col);
            box.top = @min(box.top, line);
            box.right = @max(box.right, col + 1);
            box.bottom = @max(box.bottom, line + 1);
        }
    }

    /// Emit pending hang-indent whitespace before actual content.
    fn prepareForContent(self: *RenderState, w: anytype) !void {
        if (self.at_line_start and self.hang_indent > 0) {
            for (0..self.hang_indent) |_| {
                self.noteCell(self.line_index, self.col);
                try w.writeByte(' ');
                self.col += 1;
            }
            self.at_line_start = false;
        }
    }

    /// Write a single byte, tracking column and lazy-indent.
    fn writeByte(self: *RenderState, w: anytype, byte: u8) !void {
        if (byte == '\n') {
            try w.writeByte('\n');
            self.col = 0;
            self.at_line_start = true;
            self.line_index += 1;
        } else {
            try self.prepareForContent(w);
            self.noteCell(self.line_index, self.col);
            try w.writeByte(byte);
            self.col += 1;
        }
    }

    /// Write a byte slice, correctly tracking column across newlines.
    fn writeAll(self: *RenderState, w: anytype, bytes: []const u8) !void {
        for (bytes) |byte| try self.writeByte(w, byte);
    }

    /// §2.1: flow one inline word into the running line, honoring a pending
    /// inter-word space that may have been set by a previous text node or
    /// inline element. Wraps to column 0 when the word would overflow the
    /// width budget — so a linked word crossing the right margin continues at
    /// the start of the next line instead of being stranded at the edge.
    /// Clears `pending_space`; callers set it again to request a separator
    /// before the *next* word.
    fn flowWord(self: *RenderState, w: anytype, word: []const u8) !void {
        if (word.len == 0) return;
        if (self.pending_space and self.col > 0) {
            if (self.col + 1 + word.len > self.opts.max_width) {
                try self.newline(w);
            } else {
                try self.writeByte(w, ' ');
            }
        } else if (self.col > 0 and self.col + word.len > self.opts.max_width) {
            // No pending space — the word is glued to preceding punctuation
            // (e.g. the link text in `(example.com`). It would still overflow
            // the line, so wrap it: AWR must never emit a line wider than the
            // viewport, or the real terminal hard-wraps it mid-word.
            try self.newline(w);
        }
        self.pending_space = false;
        try self.writeAll(w, word);
    }

    /// Emit a structural newline (no hang-indent emitted until next content).
    fn newline(self: *RenderState, w: anytype) !void {
        try w.writeByte('\n');
        self.col = 0;
        self.at_line_start = true;
        self.line_index += 1;
        // §2.1: a structural break consumes any pending inter-word space.
        self.pending_space = false;
    }

    /// If not already at line start, emit a newline.
    fn ensureNewline(self: *RenderState, w: anytype) !void {
        if (!self.at_line_start) try self.newline(w);
    }

    /// Write an ANSI escape sequence (no-op when ansi_colors is false).
    fn ansi(self: *RenderState, w: anytype, code: []const u8) !void {
        if (self.opts.ansi_colors) try w.writeAll(code);
    }

    /// Re-establish the active inline style after an inner renderer emitted a
    /// hard reset. Replaces blanket `ansi(w, RESET)` so nested styling
    /// restores inherited color/emphasis instead of dropping it.
    fn styleReset(self: *RenderState, w: anytype) !void {
        if (!self.opts.ansi_colors) return;
        try emitStyleSeq(w, self.cur_style);
    }

    /// Emit `pad` leading spaces as plain padding (no underline/reverse), then
    /// restore the active style frame. Used for text-align so alignment
    /// whitespace doesn't carry the element's decoration. No-op when pad == 0.
    fn emitAlignPad(self: *RenderState, w: anytype, pad: usize) !void {
        if (pad == 0) return;
        const styled = self.opts.ansi_colors and !self.cur_style.isPlain();
        if (styled) try w.writeAll(RESET);
        var i: usize = 0;
        while (i < pad) : (i += 1) try self.writeByte(w, ' ');
        if (styled) try emitStyleSeq(w, self.cur_style);
    }

    /// Compute an element's inline text style: inherit the parent frame, layer
    /// the UA defaults for its tag, then override with resolved author CSS.
    /// The inline `style=` attribute is parsed at most once here.
    fn computeTextStyle(self: *const RenderState, elem: *const dom.Element, base: TextStyle) TextStyle {
        var s = base;
        // Decoration does not cascade into a fresh decorating box in CSS, but
        // for a terminal we let it inherit — it reads naturally and avoids
        // gaps in underlined links spanning inline children.
        uaTagStyle(elem.tag, &s);

        const style_attr = elem.getAttribute("style");
        const has_inline = style_attr != null;
        // Skip author-CSS resolution when nothing could contribute: no
        // text-affecting stylesheet rules and no inline style.
        if (!self.has_text_css and !has_inline) return s;

        var inline_decl: ?css_style.StyleDeclaration = if (style_attr) |attr|
            css_style.StyleDeclaration.parse(self.allocator, attr) catch null
        else
            null;
        defer if (inline_decl) |*d| d.deinit();
        const inline_ptr: ?*const css_style.StyleDeclaration = if (inline_decl) |*d| d else null;

        applyCssTextStyle(self, elem, inline_ptr, &s);
        return s;
    }

    fn inPre(self: *const RenderState) bool {
        return self.pre_depth > 0;
    }

    fn registerLink(self: *RenderState, element_ptr: usize, href: []const u8, text: []const u8) !usize {
        const idx = self.links.items.len + 1;
        try self.links.append(self.allocator, .{
            .element_ptr = element_ptr,
            .index = idx,
            .href = try self.allocator.dupe(u8, href),
            .text = try self.allocator.dupe(u8, text),
            .line = self.line_index,
        });
        return idx;
    }

    fn registerField(
        self: *RenderState,
        element_ptr: usize,
        name: []const u8,
        field_type: []const u8,
        label: []const u8,
        col: usize,
        width: usize,
        is_submit: bool,
    ) !usize {
        const idx = self.fields.items.len;
        try self.fields.append(self.allocator, .{
            .index = idx,
            .element_ptr = element_ptr,
            .name = try self.allocator.dupe(u8, name),
            .field_type = try self.allocator.dupe(u8, field_type),
            .label = try self.allocator.dupe(u8, label),
            .line = self.line_index,
            .col = col,
            .width = width,
            .is_submit = is_submit,
        });
        return idx;
    }
};

// ── ANSI constants ────────────────────────────────────────────────────────

const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const REVERSE = "\x1b[7m";
const DIM = "\x1b[2m";
const UNDERLINE = "\x1b[4m";
const ITALIC = "\x1b[3m";
const CYAN = "\x1b[36m";
const GREEN = "\x1b[32m"; // T2.5: string literals / diff additions
const YELLOW = "\x1b[33m"; // T2.5: numeric literals
const RED = "\x1b[31m"; // T2.6: diff deletions

// ── Inline text styling (CSS-driven) ──────────────────────────────────────
//
// A small computed-style model threaded through the render walk so author
// CSS (font-weight/style, text-decoration, color, text-transform) and a
// built-in user-agent stylesheet (semantic tags) reach the terminal as ANSI
// SGR attributes. All emission is gated on `opts.ansi_colors`, so the agent
// surfaces (`awr <url>` JSON, `--format=md`, and the `ansi_colors=false`
// corpus snapshots) stay byte-identical — this is a TUI/visual concern only.
//
// Styles cascade by inheritance: each element starts from its parent's
// computed style (so a colored/bold ancestor propagates to descendants the
// way a browser's inherited text properties do), then layers UA defaults and
// finally author CSS. A single style frame is emitted as one reset+SGR run on
// entry and the parent frame is re-emitted on exit, which also fixes the
// long-standing "nested ANSI not restored" limitation noted in the file header.

const Transform = enum { none, upper, lower };

const TextStyle = struct {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    dim: bool = false,
    reverse: bool = false,
    /// ANSI SGR foreground code (30-37 / 90-97); 0 means "terminal default".
    fg: u8 = 0,
    /// text-transform is purely visual; it never alters extracted text.
    transform: Transform = .none,

    /// Two frames are visually equal when their emitted SGR run matches.
    /// `transform` is excluded — it changes text, not escape bytes.
    fn visualEql(a: TextStyle, b: TextStyle) bool {
        return a.bold == b.bold and a.italic == b.italic and
            a.underline == b.underline and a.strike == b.strike and
            a.dim == b.dim and a.reverse == b.reverse and a.fg == b.fg;
    }

    fn isPlain(self: TextStyle) bool {
        return self.visualEql(.{});
    }
};

/// Emit a frame as one `ESC[0;…m` run. Caller guarantees `ansi_colors`.
fn emitStyleSeq(w: anytype, style: TextStyle) !void {
    if (style.isPlain()) {
        try w.writeAll(RESET);
        return;
    }
    try w.writeAll("\x1b[0");
    if (style.bold) try w.writeAll(";1");
    if (style.dim) try w.writeAll(";2");
    if (style.italic) try w.writeAll(";3");
    if (style.underline) try w.writeAll(";4");
    if (style.reverse) try w.writeAll(";7");
    if (style.strike) try w.writeAll(";9");
    if (style.fg != 0) {
        var buf: [4]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, ";{d}", .{style.fg}) catch "";
        try w.writeAll(s);
    }
    try w.writeAll("m");
}

/// Map a CSS color value to a readable ANSI-16 foreground SGR code, or null when
/// unrecognised / deliberately dropped to the terminal default. Deterministic
/// and allocation-free (Rule 5: routing/parsing is plain code, not a model
/// call). Bright variants (90-97) are used for light colors so they read on dark
/// terminals; near-black/dark-gray inputs are made legible by `readableFg`.
fn cssColorToAnsi(raw: []const u8) ?u8 {
    const v = std.mem.trim(u8, raw, " \t\n\r");
    if (v.len == 0) return null;

    // Named colors — the common web set, mapped to the closest ANSI slot.
    const Named = struct { name: []const u8, code: u8 };
    const names = [_]Named{
        .{ .name = "black", .code = 30 },   .{ .name = "red", .code = 31 },
        .{ .name = "green", .code = 32 },   .{ .name = "olive", .code = 33 },
        .{ .name = "yellow", .code = 93 },  .{ .name = "navy", .code = 34 },
        .{ .name = "blue", .code = 34 },    .{ .name = "purple", .code = 35 },
        .{ .name = "magenta", .code = 35 }, .{ .name = "fuchsia", .code = 95 },
        .{ .name = "teal", .code = 36 },    .{ .name = "cyan", .code = 36 },
        .{ .name = "aqua", .code = 96 },    .{ .name = "silver", .code = 37 },
        .{ .name = "gray", .code = 90 },    .{ .name = "grey", .code = 90 },
        .{ .name = "white", .code = 97 },   .{ .name = "maroon", .code = 31 },
        .{ .name = "lime", .code = 92 },    .{ .name = "orange", .code = 33 },
        .{ .name = "pink", .code = 95 },    .{ .name = "brown", .code = 33 },
    };
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(v, n.name)) return readableFg(n.code);
    }

    // Hex (#rgb / #rrggbb) and rgb()/rgba() → nearest ANSI-16 by RGB.
    var r: u16 = undefined;
    var g: u16 = undefined;
    var b: u16 = undefined;
    if (parseRgb(v, &r, &g, &b)) {
        return readableFg(nearestAnsi16(r, g, b));
    }
    return null;
}

/// Rescue foregrounds that are unreadable on a conventionally dark terminal.
/// Browsers assume a light page background, but terminals are dark, so the two
/// near-black ANSI slots picked by `nearestAnsi16` are illegible as literal
/// colors:
///   - code 30 (black, rgb 0,0,0)        — e.g. `#000`, `black`
///   - code 90 (bright-black/dark gray)  — e.g. `#828282`, `gray`
/// Both resolve to the terminal's default foreground (`code = null`), at normal
/// intensity. (An earlier version layered SGR `dim` on code 90 to preserve a
/// "subdued metadata" hierarchy, but dim lowers contrast further and made HN/YC
/// bylines hard to read on dark terminals — readability wins over hierarchy.)
/// All other codes pass through as-is.
fn readableFg(code: u8) ?u8 {
    return switch (code) {
        30, 90 => null,
        else => code,
    };
}

fn parseRgb(v: []const u8, r: *u16, g: *u16, b: *u16) bool {
    if (v[0] == '#') {
        const hex = v[1..];
        if (hex.len == 3) {
            const rv = hexDigit(hex[0]) orelse return false;
            const gv = hexDigit(hex[1]) orelse return false;
            const bv = hexDigit(hex[2]) orelse return false;
            r.* = rv * 17;
            g.* = gv * 17;
            b.* = bv * 17;
            return true;
        }
        if (hex.len == 6) {
            r.* = (hexDigit(hex[0]) orelse return false) * 16 + (hexDigit(hex[1]) orelse return false);
            g.* = (hexDigit(hex[2]) orelse return false) * 16 + (hexDigit(hex[3]) orelse return false);
            b.* = (hexDigit(hex[4]) orelse return false) * 16 + (hexDigit(hex[5]) orelse return false);
            return true;
        }
        return false;
    }
    if (std.ascii.startsWithIgnoreCase(v, "rgb")) {
        const open = std.mem.indexOfScalar(u8, v, '(') orelse return false;
        const close = std.mem.indexOfScalar(u8, v, ')') orelse return false;
        if (close <= open) return false;
        var parts = std.mem.splitScalar(u8, v[open + 1 .. close], ',');
        const rs = parts.next() orelse return false;
        const gs = parts.next() orelse return false;
        const bs = parts.next() orelse return false;
        r.* = std.fmt.parseInt(u16, std.mem.trim(u8, rs, " \t"), 10) catch return false;
        g.* = std.fmt.parseInt(u16, std.mem.trim(u8, gs, " \t"), 10) catch return false;
        b.* = std.fmt.parseInt(u16, std.mem.trim(u8, bs, " \t"), 10) catch return false;
        return true;
    }
    return false;
}

fn hexDigit(c: u8) ?u16 {
    return switch (c) {
        '0'...'9' => @as(u16, c - '0'),
        'a'...'f' => @as(u16, c - 'a' + 10),
        'A'...'F' => @as(u16, c - 'A' + 10),
        else => null,
    };
}

/// Pick the closest of the 8 normal + 8 bright ANSI colors by squared RGB
/// distance against their conventional xterm values.
fn nearestAnsi16(r: u16, g: u16, b: u16) u8 {
    const Slot = struct { code: u8, r: u16, g: u16, b: u16 };
    const slots = [_]Slot{
        .{ .code = 30, .r = 0, .g = 0, .b = 0 },
        .{ .code = 31, .r = 205, .g = 0, .b = 0 },
        .{ .code = 32, .r = 0, .g = 205, .b = 0 },
        .{ .code = 33, .r = 205, .g = 205, .b = 0 },
        .{ .code = 34, .r = 0, .g = 0, .b = 238 },
        .{ .code = 35, .r = 205, .g = 0, .b = 205 },
        .{ .code = 36, .r = 0, .g = 205, .b = 205 },
        .{ .code = 37, .r = 229, .g = 229, .b = 229 },
        .{ .code = 90, .r = 127, .g = 127, .b = 127 },
        .{ .code = 91, .r = 255, .g = 0, .b = 0 },
        .{ .code = 92, .r = 0, .g = 255, .b = 0 },
        .{ .code = 93, .r = 255, .g = 255, .b = 0 },
        .{ .code = 94, .r = 92, .g = 92, .b = 255 },
        .{ .code = 95, .r = 255, .g = 0, .b = 255 },
        .{ .code = 96, .r = 0, .g = 255, .b = 255 },
        .{ .code = 97, .r = 255, .g = 255, .b = 255 },
    };
    var best: u8 = 37;
    var best_dist: i64 = std.math.maxInt(i64);
    for (slots) |s| {
        const dr = @as(i64, r) - @as(i64, s.r);
        const dg = @as(i64, g) - @as(i64, s.g);
        const db = @as(i64, b) - @as(i64, s.b);
        const dist = dr * dr + dg * dg + db * db;
        if (dist < best_dist) {
            best_dist = dist;
            best = s.code;
        }
    }
    return best;
}

/// Built-in user-agent stylesheet: visual defaults for semantic tags so that
/// pages with little/no CSS still render with browser-like emphasis. Returns
/// the attributes a tag contributes ON TOP of inherited style (OR-ed in).
fn uaTagStyle(tag: []const u8, style: *TextStyle) void {
    if (eql(tag, "strong") or eql(tag, "b")) {
        style.bold = true;
    } else if (eql(tag, "em") or eql(tag, "i") or eql(tag, "cite") or eql(tag, "var") or eql(tag, "dfn")) {
        style.italic = true;
    } else if (eql(tag, "u") or eql(tag, "ins")) {
        style.underline = true;
    } else if (eql(tag, "del") or eql(tag, "s") or eql(tag, "strike")) {
        style.strike = true;
    } else if (eql(tag, "mark")) {
        style.reverse = true;
    } else if (eql(tag, "small")) {
        style.dim = true;
    } else if (eql(tag, "kbd") or eql(tag, "samp")) {
        style.reverse = true;
    } else if (eql(tag, "a")) {
        // Links: underlined. Color/focus emphasis is layered by renderLink.
        style.underline = true;
    } else if (eql(tag, "blockquote")) {
        style.dim = true;
    } else if (eql(tag, "h1") or eql(tag, "h2")) {
        style.bold = true;
        style.underline = true;
    } else if (eql(tag, "h3")) {
        style.bold = true;
    } else if (eql(tag, "h4") or eql(tag, "h5") or eql(tag, "h6")) {
        style.bold = true;
        style.dim = true;
    }
}

/// Layer resolved author CSS over `s`. `inline_decl` is the caller-owned
/// parsed inline `style=` declaration (or null). Resolution runs inside the
/// render module so it shares the DOM `Element` type; cascade precedence
/// reuses `css_cascade.MatchResult`.
fn applyCssTextStyle(
    state: *const RenderState,
    elem: *const dom.Element,
    inline_decl: ?*const css_style.StyleDeclaration,
    s: *TextStyle,
) void {
    // Resolve all six text properties in a SINGLE pass over the rules: each
    // rule is matched against `elem` once (the costly step for combinator
    // selectors that walk the ancestor chain), and every property it declares
    // updates that property's best cascade match. Resolving per-property
    // instead re-matched every rule six times, which timed out on large
    // stylesheets.
    const props = [_][]const u8{ "font-weight", "font-style", "text-decoration", "text-decoration-line", "color", "text-transform" };
    var best: [props.len]?css_cascade.MatchResult = .{ null, null, null, null, null, null };

    for (state.text_rules.items) |tr| {
        if (!cssRuleMatches(state, elem, tr.rule)) continue;
        for (props, 0..) |p, pi| {
            const val = tr.rule.declarations.getPropertyValue(p);
            if (val.len == 0) continue;
            const m = css_cascade.MatchResult{
                .specificity = tr.rule.specificity,
                .source_index = tr.source_index,
                .rule_index = tr.rule_index,
                .value = val,
                .important = declImportant(&tr.rule.declarations, p),
            };
            if (best[pi] == null or m.isPrecedentOver(best[pi].?)) best[pi] = m;
        }
    }
    if (inline_decl) |decl| {
        for (props, 0..) |p, pi| {
            const v = decl.getPropertyValue(p);
            if (v.len == 0) continue;
            const m = css_cascade.MatchResult{
                .specificity = .{ .id = 9999, .class = 0, .element = 0 },
                .source_index = std.math.maxInt(usize),
                .rule_index = std.math.maxInt(usize),
                .value = v,
                .important = declImportant(decl, p),
            };
            if (best[pi] == null or m.isPrecedentOver(best[pi].?)) best[pi] = m;
        }
    }

    const fw = if (best[0]) |m| m.value else "";
    if (fw.len > 0) {
        if (isBoldWeight(fw)) {
            s.bold = true;
        } else if (eql(fw, "normal") or eql(fw, "400") or eql(fw, "300") or eql(fw, "200") or eql(fw, "100")) {
            s.bold = false;
        }
    }

    const fs = if (best[1]) |m| m.value else "";
    if (fs.len > 0) {
        if (eql(fs, "italic") or eql(fs, "oblique")) {
            s.italic = true;
        } else if (eql(fs, "normal")) {
            s.italic = false;
        }
    }

    const td = if (best[2]) |m| m.value else "";
    const tdl = if (best[3]) |m| m.value else "";
    if (containsWord(td, "underline") or containsWord(tdl, "underline")) s.underline = true;
    if (containsWord(td, "line-through") or containsWord(tdl, "line-through")) s.strike = true;
    if (containsWord(td, "none") or containsWord(tdl, "none")) {
        s.underline = false;
        s.strike = false;
    }

    const color = if (best[4]) |m| m.value else "";
    if (color.len > 0) {
        // A mapped code sets the foreground; black/dark-gray map to null
        // (terminal default) so they stay legible on dark terminals.
        if (cssColorToAnsi(color)) |code| s.fg = code;
    }

    const tt = if (best[5]) |m| m.value else "";
    if (tt.len > 0) {
        if (eql(tt, "uppercase")) {
            s.transform = .upper;
        } else if (eql(tt, "lowercase")) {
            s.transform = .lower;
        } else if (eql(tt, "none")) {
            s.transform = .none;
        }
    }
}

/// Resolve one CSS property for `elem` across the parsed author stylesheets
/// and the caller-owned inline declaration, honoring specificity, source
/// order, and `!important`. Returns a borrowed slice (valid for the lifetime
/// of the stylesheets / inline declaration) or "" when unset.
fn resolveCssProp(
    state: *const RenderState,
    elem: *const dom.Element,
    prop: []const u8,
    inline_decl: ?*const css_style.StyleDeclaration,
) []const u8 {
    var best: ?css_cascade.MatchResult = null;
    for (state.parsed_sheets.items, 0..) |*sheet, si| {
        for (sheet.rules.items, 0..) |*rule, ri| {
            if (!cssRuleMatches(state, elem, rule)) continue;
            const val = rule.declarations.getPropertyValue(prop);
            if (val.len == 0) continue;
            const m = css_cascade.MatchResult{
                .specificity = rule.specificity,
                .source_index = si,
                .rule_index = ri,
                .value = val,
                .important = declImportant(&rule.declarations, prop),
            };
            if (best == null or m.isPrecedentOver(best.?)) best = m;
        }
    }
    if (inline_decl) |decl| {
        const v = decl.getPropertyValue(prop);
        if (v.len > 0) {
            const m = css_cascade.MatchResult{
                // Inline beats any stylesheet selector (sentinel specificity).
                .specificity = .{ .id = 9999, .class = 0, .element = 0 },
                .source_index = std.math.maxInt(usize),
                .rule_index = std.math.maxInt(usize),
                .value = v,
                .important = declImportant(decl, prop),
            };
            if (best == null or m.isPrecedentOver(best.?)) best = m;
        }
    }
    return if (best) |m| m.value else "";
}

/// Match `elem` against a rule. Compound/combinator/attribute rules
/// (`rule.complex`) match exactly via their pre-compiled selector (built once
/// at setup — see `compiled_selectors`); if compilation was unavailable they
/// fall back to the allocation-free flat OR approximation. Single simple
/// selectors always use the fast flat path.
fn cssRuleMatches(state: *const RenderState, elem: *const dom.Element, rule: *const css_parser.Rule) bool {
    if (rule.media) |m| {
        // Viewport width ≈ render columns × 8 CSS px (matches the matchMedia
        // model); height is approximated since the renderer is width-driven.
        const vw: i64 = @as(i64, @intCast(state.opts.max_width)) * 8;
        if (!css_parser.mediaMatches(m, vw, 24 * 16)) return false;
    }
    if (rule.complex and state.exact_complex_selectors) {
        if (state.compiled_selectors.getPtr(rule)) |list| {
            return dom.matchesCompiled(elem, list);
        }
    }
    if (rule.selectors.items.len == 0) return false;
    for (rule.selectors.items) |sel| {
        switch (sel.sel_type) {
            .universal => return true,
            .tag => if (std.ascii.eqlIgnoreCase(elem.tag, sel.value)) return true,
            .id => {
                if (elem.getAttribute("id")) |id| {
                    if (std.mem.eql(u8, id, sel.value)) return true;
                }
            },
            .class => {
                if (elem.getAttribute("class")) |classes| {
                    var parts = std.mem.splitScalar(u8, classes, ' ');
                    while (parts.next()) |cn| {
                        if (std.mem.eql(u8, cn, sel.value)) return true;
                    }
                }
            },
        }
    }
    return false;
}

fn declImportant(decl: *const css_style.StyleDeclaration, prop: []const u8) bool {
    for (decl.declarations.items) |d| {
        if (std.ascii.eqlIgnoreCase(d.name, prop)) return d.important;
    }
    return false;
}

/// True when a rule declares any text property the renderer maps to an ANSI
/// attribute. Used once at setup to gate the per-element resolution.
fn ruleHasTextProp(rule: *const css_parser.Rule) bool {
    const props = [_][]const u8{
        "color",           "font-weight",          "font-style",
        "text-decoration", "text-decoration-line", "text-transform",
    };
    for (props) |p| {
        if (rule.declarations.getPropertyValue(p).len > 0) return true;
    }
    return false;
}

/// CSS font-weight values that map to terminal bold: the `bold`/`bolder`
/// keywords and numeric weights ≥ 600.
fn isBoldWeight(v: []const u8) bool {
    if (eql(v, "bold") or eql(v, "bolder")) return true;
    const n = std.fmt.parseInt(u16, std.mem.trim(u8, v, " \t"), 10) catch return false;
    return n >= 600;
}

/// True when space-separated `haystack` contains the whole token `needle`
/// (case-insensitive). Used for multi-value `text-decoration`.
fn containsWord(haystack: []const u8, needle: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, haystack, " \t");
    while (it.next()) |word| {
        if (eql(word, needle)) return true;
    }
    return false;
}

/// ASCII text-transform in place (multibyte UTF-8 bytes are left unchanged).
fn applyTransformInPlace(text: []u8, t: Transform) void {
    switch (t) {
        .none => {},
        .upper => for (text) |*c| {
            c.* = std.ascii.toUpper(c.*);
        },
        .lower => for (text) |*c| {
            c.* = std.ascii.toLower(c.*);
        },
    }
}

const Align = enum { start, center, right };

/// Approximate terminal display width (UTF-8 codepoint count; wide CJK/emoji
/// are not double-counted). Good enough for centering single-line text.
fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Resolve a block element's effective horizontal alignment: CSS `text-align`
/// first, then the legacy presentational `align`/`<center>` fallback. Author
/// CSS resolution is skipped when no rule declares text-align and there is no
/// inline style.
fn resolveAlign(state: *const RenderState, elem: *const dom.Element) Align {
    if (eql(elem.tag, "center")) return .center;

    if (state.has_align_css or elem.getAttribute("style") != null) {
        var inline_decl: ?css_style.StyleDeclaration = if (elem.getAttribute("style")) |a|
            css_style.StyleDeclaration.parse(state.allocator, a) catch null
        else
            null;
        defer if (inline_decl) |*d| d.deinit();
        const v = resolveCssProp(state, elem, "text-align", if (inline_decl) |*d| d else null);
        if (eql(v, "center")) return .center;
        if (eql(v, "right") or eql(v, "end")) return .right;
        if (eql(v, "left") or eql(v, "start")) return .start;
    }

    // Legacy presentational attribute (e.g. <p align="center">).
    if (elem.getAttribute("align")) |a| {
        if (eql(a, "center")) return .center;
        if (eql(a, "right")) return .right;
    }
    return .start;
}

/// Leading-pad columns to place `content_width` columns of text at `align`
/// within `max_width`. Zero for start alignment or when content fills the row.
fn alignPad(al: Align, content_width: usize, max_width: usize) usize {
    if (content_width >= max_width) return 0;
    return switch (al) {
        .start => 0,
        .center => (max_width - content_width) / 2,
        .right => max_width - content_width,
    };
}

// ── Public API ────────────────────────────────────────────────────────────

/// Render a DOM document as structured terminal text written to `writer`.
/// The allocator is used for temporary text-content extraction and the
/// link-reference list.
pub fn render(
    allocator: std.mem.Allocator,
    writer: anytype,
    doc: *const dom.Document,
    opts: RenderOptions,
) anyerror!void {
    var model = try renderModel(allocator, doc, opts);
    defer model.deinit();
    try writer.writeAll(model.text);
}

pub fn renderHtml(
    allocator: std.mem.Allocator,
    writer: anytype,
    html: []const u8,
    opts: RenderOptions,
) anyerror!void {
    var doc = try dom.parseDocument(allocator, html);
    defer doc.deinit();
    try render(allocator, writer, &doc, opts);
}

pub fn renderModel(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    opts: RenderOptions,
) !ScreenModel {
    return renderModelFromRoot(allocator, doc.body(), opts);
}

pub fn renderBrowseModel(
    allocator: std.mem.Allocator,
    doc: *const dom.Document,
    opts: RenderOptions,
) !ScreenModel {
    var browse_opts = opts;
    browse_opts.profile = .browse;
    const root = browse_heuristics.chooseContentRoot(doc) orelse doc.body();
    return renderModelFromRoot(allocator, root, browse_opts);
}

pub fn renderBrowseHtmlModel(
    allocator: std.mem.Allocator,
    html: []const u8,
    opts: RenderOptions,
) !ScreenModel {
    var doc = try dom.parseDocument(allocator, html);
    defer doc.deinit();
    return renderBrowseModel(allocator, &doc, opts);
}

pub fn renderModelFromElement(
    allocator: std.mem.Allocator,
    elem: *const dom.Element,
    opts: RenderOptions,
) !ScreenModel {
    return renderModelFromRoot(allocator, elem, opts);
}

/// Renders `root`, then rescues blank app-shell pages: when the normal pass
/// produces no visible text — typically a JS framework that streams its entire
/// body into a single `[hidden]` container (Next.js, see `isCssHidden`) — it
/// re-renders once with the generic `[hidden]` reset relaxed so that content
/// surfaces. The normal pass is kept for pages where `[hidden]` legitimately
/// hides only chrome (Wikipedia nav), so their visible body is unaffected.
fn renderModelFromRoot(
    allocator: std.mem.Allocator,
    root: ?*const dom.Element,
    opts: RenderOptions,
) !ScreenModel {
    var model = try renderModelFromRootOnce(allocator, root, opts, false);
    if (!isBlankRender(model.text)) return model;
    model.deinit();
    return renderModelFromRootOnce(allocator, root, opts, true);
}

/// True when rendered text carries no visible glyphs — only whitespace and the
/// `[Region omitted]` collapse placeholders the browse profile emits for
/// chrome. Such a render is indistinguishable from a blank screen to the user,
/// so it triggers the `[hidden]` rescue pass.
fn isBlankRender(text: []const u8) bool {
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '[')) |open| {
        for (rest[0..open]) |ch| if (!std.ascii.isWhitespace(ch)) return false;
        const close = std.mem.indexOfScalar(u8, rest[open..], ']') orelse return true;
        rest = rest[open + close + 1 ..];
    }
    for (rest) |ch| if (!std.ascii.isWhitespace(ch)) return false;
    return true;
}

fn renderModelFromRootOnce(
    allocator: std.mem.Allocator,
    root: ?*const dom.Element,
    opts: RenderOptions,
    relax_hidden_attr: bool,
) !ScreenModel {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var writer = BufferWriter{ .allocator = allocator, .list = &buf };
    var state = RenderState{
        .allocator = allocator,
        .opts = opts,
        .relax_hidden_attr = relax_hidden_attr,
    };
    defer state.deinit();

    // Parse author stylesheets once; the per-element visibility/white-space
    // checks below iterate pre-filtered rule indexes instead of re-parsing
    // and re-scanning every sheet for every element.
    for (opts.css_stylesheets) |css| {
        var sheet = css_parser.parseStylesheet(allocator, css) catch continue;
        state.parsed_sheets.append(allocator, sheet) catch {
            sheet.deinit();
            continue;
        };
    }
    // Build filtered indexes only after all sheets are parsed (rule heap
    // storage is stable; the outer list may have reallocated during append).
    for (state.parsed_sheets.items, 0..) |*sheet, si| {
        for (sheet.rules.items, 0..) |*rule, ri| {
            const disp = rule.declarations.getPropertyValue("display");
            const vis = rule.declarations.getPropertyValue("visibility");
            if (disp.len > 0 or vis.len > 0) {
                state.hide_rules.append(allocator, rule) catch {};
            }
            if (rule.declarations.getPropertyValue("white-space").len > 0) {
                state.ws_rules.append(allocator, rule) catch {};
            }
            // Collect text rules (in cascade order) so the per-element style
            // pass matches only these — not the thousands of layout rules a
            // large stylesheet carries. Complex text rules get their selector
            // pre-compiled once for exact (combinator/attr) matching.
            if (ruleHasTextProp(rule)) {
                state.has_text_css = true;
                state.text_rules.append(allocator, .{ .rule = rule, .source_index = si, .rule_index = ri }) catch {};
                if (rule.complex) {
                    if (dom.compileSelectorList(allocator, rule.selector_text)) |list| {
                        state.compiled_selectors.put(allocator, rule, list) catch {
                            var l = list;
                            l.deinit(allocator);
                        };
                    } else |_| {}
                }
            }
            if (!state.has_align_css and rule.declarations.getPropertyValue("text-align").len > 0) {
                state.has_align_css = true;
            }
        }
    }
    // Exact complex matching is affordable only when few complex text rules
    // exist; above this the per-element ancestor walk is too slow (MediaWiki).
    state.exact_complex_selectors = state.compiled_selectors.count() <= 48;

    if (root) |elem| {
        if (eql(elem.tag, "body")) {
            try renderChildren(&state, &writer, elem);
        } else {
            try renderElement(&state, &writer, elem);
        }

        const emit_refs = opts.show_references orelse (opts.profile == .default);
        if (emit_refs and opts.show_links and state.links.items.len > 0) {
            try state.ensureNewline(&writer);
            try state.newline(&writer);
            try state.ansi(&writer, BOLD);
            try state.writeAll(&writer, "References:");
            try state.ansi(&writer, RESET);
            try state.newline(&writer);
            for (state.links.items) |link| {
                const num = try std.fmt.allocPrint(allocator, "{d}", .{link.index});
                defer allocator.free(num);
                try writer.writeAll("  [");
                try state.ansi(&writer, CYAN);
                try writer.writeAll(num);
                try state.ansi(&writer, RESET);
                try writer.writeAll("]: ");
                try state.ansi(&writer, UNDERLINE);
                try writer.writeAll(link.href);
                try state.ansi(&writer, RESET);
                try state.newline(&writer);
            }
        }
    }

    return buildScreenModel(allocator, try buf.toOwnedSlice(allocator), state.links.items, state.fields.items, state.boxes.items, state.sticky_hdrs.items);
}

pub fn renderHtmlModel(
    allocator: std.mem.Allocator,
    html: []const u8,
    opts: RenderOptions,
) !ScreenModel {
    var doc = try dom.parseDocument(allocator, html);
    defer doc.deinit();
    return renderModel(allocator, &doc, opts);
}

fn buildScreenModel(
    allocator: std.mem.Allocator,
    text: []u8,
    link_refs: []const LinkRef,
    field_refs: []const FieldRef,
    box_refs: []const BoxRef,
    sticky_header_refs: []const StickyHeader,
) !ScreenModel {
    errdefer allocator.free(text);

    const line_count = countScreenLines(text);
    const lines = try allocator.alloc(ScreenLine, line_count);
    errdefer allocator.free(lines);

    if (line_count > 0) {
        var line_start: usize = 0;
        var line_index: usize = 0;
        for (text, 0..) |ch, i| {
            if (ch == '\n') {
                if (line_index < lines.len) {
                    lines[line_index] = .{ .start = line_start, .end = i };
                    line_index += 1;
                }
                line_start = i + 1;
            }
        }
        if (line_index < lines.len) {
            lines[line_index] = .{ .start = line_start, .end = text.len };
        }
    }

    const links = try allocator.alloc(ScreenLink, link_refs.len);
    var built_links: usize = 0;
    errdefer {
        for (links[0..built_links]) |link| {
            allocator.free(link.href);
            allocator.free(link.text);
        }
        allocator.free(links);
    }
    for (link_refs, 0..) |link, i| {
        links[i] = .{
            .element_ptr = link.element_ptr,
            .index = link.index,
            .href = try allocator.dupe(u8, link.href),
            .text = try allocator.dupe(u8, link.text),
            .line = link.line,
        };
        built_links += 1;
    }

    const boxes = try allocator.alloc(ScreenBox, box_refs.len);
    errdefer allocator.free(boxes);
    for (box_refs, 0..) |box, i| {
        boxes[i] = .{
            .element_ptr = box.element_ptr,
            .rect = .{
                .x = box.left,
                .y = box.top,
                .width = if (box.saw_content) box.right - box.left else 0,
                .height = if (box.saw_content) box.bottom - box.top else 0,
            },
        };
    }

    const fields = try allocator.alloc(ScreenField, field_refs.len);
    var built_fields: usize = 0;
    errdefer {
        for (fields[0..built_fields]) |field| {
            field.deinit(allocator);
        }
        allocator.free(fields);
    }
    for (field_refs, 0..) |field, i| {
        fields[i] = .{
            .index = field.index,
            .element_ptr = field.element_ptr,
            .name = try allocator.dupe(u8, field.name),
            .field_type = try allocator.dupe(u8, field.field_type),
            .label = try allocator.dupe(u8, field.label),
            .line = field.line,
            .col = field.col,
            .width = field.width,
            .is_submit = field.is_submit,
        };
        built_fields += 1;
    }

    const sticky_headers = try allocator.dupe(StickyHeader, sticky_header_refs);
    errdefer allocator.free(sticky_headers);

    return .{
        .allocator = allocator,
        .text = text,
        .lines = lines,
        .links = links,
        .fields = fields,
        .boxes = boxes,
        .sticky_headers = sticky_headers,
    };
}

fn countScreenLines(text: []const u8) usize {
    if (text.len == 0) return 0;

    var count: usize = 1;
    for (text) |ch| {
        if (ch == '\n') count += 1;
    }
    if (text[text.len - 1] == '\n') count -= 1;
    return count;
}

// ── Tree-walking renderers ────────────────────────────────────────────────

fn renderNode(state: *RenderState, w: anytype, node: dom.Node) anyerror!void {
    switch (node) {
        .text => |t| try renderTextNode(state, w, t),
        .element => |e| try renderElement(state, w, e),
        .comment => {}, // skip comments
        else => {},
    }
}

fn renderChildren(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    for (elem.children.items) |child| {
        try renderNode(state, w, child);
    }
}

fn renderElement(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const tag = elem.tag;

    if (isHiddenTag(tag)) return;
    if (isCssHidden(state, elem)) return;

    if (state.opts.profile == .browse) {
        if (isCompactLandmarkTag(tag)) {
            if (browse_heuristics.shouldCollapseForBrowse(elem)) {
                try renderCollapsedLandmark(state, w, tag);
            } else if (browse_heuristics.shouldSkipForBrowse(elem)) {
                return;
            } else {
                try renderBrowseCompactLandmark(state, w, elem);
            }
            return;
        }

        if (isStrongLandmarkTag(tag)) {
            if (browse_heuristics.shouldSkipForBrowse(elem)) return;
            try renderBrowseStrongLandmark(state, w, elem);
            return;
        }

        if (browse_heuristics.shouldSkipForBrowse(elem)) return;
    }

    try state.beginElementBox(elem);
    defer state.endElementBox();

    // CSSOM §4.6.3: honor `white-space: pre|pre-wrap|pre-line` from inline
    // style or author stylesheet by reusing the existing <pre> preservation
    // path. The per-element bump matches how `renderPre` toggles `pre_depth`,
    // so all descendant text nodes flow through the inPre() branch of
    // `renderTextNode`.
    const ws_preserve = isCssWhiteSpacePreserved(state, elem);
    if (ws_preserve) state.pre_depth += 1;
    defer if (ws_preserve) {
        state.pre_depth -= 1;
    };

    // CSS-driven inline text style. Inherit the parent frame, layer UA + author
    // CSS, emit the SGR run on entry and restore the parent frame on exit.
    // Gated on `ansi_colors`, so the agent/JSON/Markdown surfaces and the
    // `ansi_colors=false` corpus snapshots stay byte-identical. `cur_style` is
    // always updated (even with colors off) so `text-transform` can act.
    const saved_style = state.cur_style;
    const new_style = state.computeTextStyle(elem, saved_style);
    const style_changed = state.opts.ansi_colors and !TextStyle.visualEql(new_style, saved_style);
    state.cur_style = new_style;
    if (style_changed) try emitStyleSeq(w, new_style);
    defer {
        state.cur_style = saved_style;
        if (style_changed) emitStyleSeq(w, saved_style) catch {};
    }

    // Step 10: CSS background-image emit. For content-bearing landmarks
    // (`<header>`, `<section>`, `<figure>`) with inline `style="...
    // background-image: url(...)..."`, surface the bg image as an
    // image-bearing row before the element's children render. The
    // pipeline pre-fetches these URLs into the same lookup as `<img>`
    // sources; this hook just queries it. Per
    // `spec/subspecs/rendering.md §3.1`.
    if (state.opts.image_lookup) |lookup| {
        if (eql(tag, "header") or eql(tag, "section") or eql(tag, "figure")) {
            tryEmitBackgroundImage(state, w, elem, lookup) catch {};
        }
    }

    // ── Heading ──────────────────────────────────────────────────────
    if (headingLevel(tag)) |level| {
        try renderHeading(state, w, elem, level);
        return;
    }

    // ── Paragraph ────────────────────────────────────────────────────
    if (eql(tag, "p")) {
        try renderParagraph(state, w, elem);
        return;
    }

    // ── Anchor / link ────────────────────────────────────────────────
    if (eql(tag, "a")) {
        try renderLink(state, w, elem);
        return;
    }

    // ── Lists ────────────────────────────────────────────────────────
    if (eql(tag, "ul") or eql(tag, "ol")) {
        try renderList(state, w, elem);
        return;
    }
    if (eql(tag, "li")) {
        var one: usize = 1;
        try renderListItem(state, w, elem, false, &one);
        return;
    }

    // ── Blockquote ───────────────────────────────────────────────────
    if (eql(tag, "blockquote")) {
        try renderBlockquote(state, w, elem);
        return;
    }

    // ── Preformatted ─────────────────────────────────────────────────
    if (eql(tag, "pre")) {
        try renderPre(state, w, elem);
        return;
    }

    // ── Inline code ──────────────────────────────────────────────────
    if (eql(tag, "code")) {
        try renderCode(state, w, elem);
        return;
    }

    // ── Horizontal rule ──────────────────────────────────────────────
    if (eql(tag, "hr")) {
        try renderHr(state, w);
        return;
    }

    // ── Line break ───────────────────────────────────────────────────
    if (eql(tag, "br")) {
        try state.newline(w);
        return;
    }

    // ── Form elements ────────────────────────────────────────────────
    if (eql(tag, "input")) {
        try renderInput(state, w, elem);
        return;
    }
    if (eql(tag, "button")) {
        try renderButton(state, w, elem);
        return;
    }
    if (eql(tag, "select")) {
        try renderSelect(state, w, elem);
        return;
    }
    if (eql(tag, "textarea")) {
        try renderTextarea(state, w, elem);
        return;
    }

    // ── Image ────────────────────────────────────────────────────────
    if (eql(tag, "img")) {
        try renderImage(state, w, elem);
        return;
    }

    // ── Strong / bold ────────────────────────────────────────────────
    if (eql(tag, "strong") or eql(tag, "b")) {
        try renderStrong(state, w, elem);
        return;
    }

    // ── Emphasis / italic ────────────────────────────────────────────
    if (eql(tag, "em") or eql(tag, "i")) {
        try renderEm(state, w, elem);
        return;
    }

    // ── Table ────────────────────────────────────────────────────────
    if (eql(tag, "table")) {
        try renderTable(state, w, elem);
        return;
    }

    // ── Focusable non-native controls (tabindex / role=button) ───────
    // ARIA / custom widgets: a `<div tabindex="0">` or `<span role="button">`
    // is keyboard-focusable and click-activatable even though it is not a
    // native control. Register it so Tab reaches it and Enter/Space dispatches
    // a click (which runs the page's onclick handler). T1.
    if (genericFocusable(elem)) {
        try renderFocusable(state, w, elem);
        return;
    }

    // ── Generic block / inline fallback ──────────────────────────────
    if (isBlockTag(tag) or eql(tag, "center")) {
        // TUI-only center/right alignment for single-line block content
        // (e.g. <div style="text-align:center"> or legacy <center>).
        if (try renderAlignedBlock(state, w, elem)) return;
        try state.ensureNewline(w);
        try renderChildren(state, w, elem);
        try state.ensureNewline(w);
    } else {
        try renderChildren(state, w, elem);
    }
}

// ── Specific element renderers ────────────────────────────────────────────

fn renderHeading(state: *RenderState, w: anytype, elem: *const dom.Element, level: u8) anyerror!void {
    try state.ensureNewline(w);

    const text = elem.textContentForExtract(state.allocator) catch return;
    defer state.allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;

    // CSS text-align (center/right) — TUI only, single-line heading text.
    const pad = if (state.opts.ansi_colors)
        alignPad(resolveAlign(state, elem), displayWidth(trimmed), state.opts.max_width)
    else
        0;
    try state.emitAlignPad(w, pad);

    // Style (h1/h2 bold+underline, h3 bold, h4-h6 bold+dim) is supplied by the
    // UA stylesheet via the inline style stack in `renderElement`.
    try state.writeAll(w, trimmed);
    try state.newline(w);

    // Decorative underline for h1 ("=") and h2 ("-"), aligned under the text.
    if (level <= 2) {
        const ch: u8 = if (level == 1) '=' else '-';
        // Byte length (not display width) preserves the established agent/JSON
        // snapshot for the ansi-off path; the alignment pad above is ansi-only.
        const len = @min(trimmed.len, state.opts.max_width);
        try state.emitAlignPad(w, pad);
        for (0..len) |_| try w.writeByte(ch);
        try state.newline(w);
    }
    try state.newline(w);
}

fn renderParagraph(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    if (try renderAlignedBlock(state, w, elem)) {
        try state.newline(w);
        return;
    }
    try state.ensureNewline(w);
    try renderChildren(state, w, elem);
    try state.ensureNewline(w);
    try state.newline(w);
}

/// TUI-only: when `elem` is center/right aligned and its flattened text fits on
/// one line, render it aligned and return true; otherwise return false so the
/// caller renders it normally. Restricted to a single line to avoid a layout
/// rewrite — multi-line alignment is deferred (browser-roadmap Tier 2+).
fn renderAlignedBlock(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!bool {
    if (!state.opts.ansi_colors) return false;
    const al = resolveAlign(state, elem);
    if (al == .start) return false;
    const text = elem.textContentForExtract(state.allocator) catch return false;
    defer state.allocator.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    const wdt = displayWidth(trimmed);
    if (wdt == 0 or wdt >= state.opts.max_width) return false; // would wrap → leave to normal flow
    try state.ensureNewline(w);
    try state.emitAlignPad(w, alignPad(al, wdt, state.opts.max_width));
    // Drop any inter-word space carried in from a previous sibling: with the
    // alignment pad already placing the cursor, a phantom leading space would
    // push a right-aligned line (pad + text == max_width) over the margin and
    // wrap it back to column 0, discarding the alignment.
    state.pending_space = false;
    try renderChildren(state, w, elem);
    try state.ensureNewline(w);
    return true;
}

/// Column width of a footnote ref `[n]` (brackets + digits).
fn footnoteRefWidth(n: usize) usize {
    var digits: usize = 1;
    var v = n;
    while (v >= 10) : (v /= 10) digits += 1;
    return digits + 2;
}

fn renderLink(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const href = if (state.opts.show_links) (elem.getAttribute("href") orelse "") else "";

    // Reserve room for the trailing footnote ref while flowing the link text so
    // flowWord wraps the last word early enough to keep `text[N]` together on
    // one line — instead of appending the ref past max_width (which the real
    // terminal then hard-wraps mid-word, e.g. the YC jobs board) or orphaning it
    // onto its own line. Registration order is left unchanged (footnote numbers
    // stay stable); the ref width is predicted from the current link count, so a
    // rare digit-boundary off-by-one only costs a single column.
    const saved_max = state.opts.max_width;
    if (href.len > 0) {
        const reserve = footnoteRefWidth(state.links.items.len + 1);
        if (state.opts.max_width > reserve) state.opts.max_width -= reserve;
    }

    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    if (focused and state.opts.ansi_colors) {
        // Focus emphasis layered on top of the link's UA underline + any
        // inherited/author color, then restored to that frame afterwards.
        try state.ansi(w, REVERSE);
        try state.ansi(w, BOLD);
        try renderChildren(state, w, elem);
        try state.styleReset(w);
    } else {
        // Underline (UA) and color (author CSS) come from the style stack.
        try renderChildren(state, w, elem);
    }

    state.opts.max_width = saved_max;

    if (href.len > 0) {
        const raw_text = elem.textContentForExtract(state.allocator) catch return;
        defer state.allocator.free(raw_text);
        const idx = state.registerLink(@intFromPtr(elem), href, std.mem.trim(u8, raw_text, " \t\r\n")) catch return;
        const ref = try std.fmt.allocPrint(state.allocator, "[{d}]", .{idx});
        defer state.allocator.free(ref);
        try state.ansi(w, DIM);
        try state.writeAll(w, ref);
        try state.styleReset(w);
    }
}

fn renderList(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);
    const is_ordered = eql(elem.tag, "ol");
    var item_num: usize = 1;

    for (elem.children.items) |child| {
        if (child == .element) {
            if (eql(child.element.tag, "li")) {
                try renderListItem(state, w, child.element, is_ordered, &item_num);
                if (is_ordered) item_num += 1;
            } else {
                try renderNode(state, w, child);
            }
        }
    }
}

fn renderListItem(
    state: *RenderState,
    w: anytype,
    elem: *const dom.Element,
    is_ordered: bool,
    item_num: *usize,
) anyerror!void {
    // Skip list items whose visible content is empty after extraction
    // (script/style stripped, decorative images skipped). Otherwise we
    // emit a bare bullet `•` with no text — pure noise. T-76: surfaced
    // by Google's homepage where suggestion `<li>` elements with only
    // empty-alt icons rendered as a column of stranded bullets.
    const probe = elem.textContentForExtract(state.allocator) catch "";
    defer if (probe.len > 0) state.allocator.free(probe);
    if (std.mem.trim(u8, probe, " \t\r\n").len == 0 and !hasVisibleControl(elem)) return;

    const saved_indent = state.hang_indent;

    try state.ensureNewline(w);

    if (is_ordered) {
        const prefix = try std.fmt.allocPrint(state.allocator, "  {d}. ", .{item_num.*});
        defer state.allocator.free(prefix);
        try state.writeAll(w, prefix);
    } else {
        try state.writeAll(w, "  \xe2\x80\xa2 "); // UTF-8 bullet: "•"
    }
    // hang_indent = absolute column after prefix (works for nesting)
    state.hang_indent = state.col;
    // §2.1: the marker prefix ("  • " / "  N. ") already separates the
    // bullet from the item text. Clear any pending inter-word space so the
    // first child's leading source whitespace doesn't add a phantom space
    // after the marker.
    state.pending_space = false;

    try renderChildren(state, w, elem);
    try state.newline(w);

    state.hang_indent = saved_indent;
}

/// True when an element subtree contains a focusable form control we
/// want the user to be able to Tab into (input/select/textarea/button).
/// Used by `renderListItem` to keep an `<li>` that wraps a button even
/// if the textual content is empty (icon-only buttons).
fn hasVisibleControl(elem: *const dom.Element) bool {
    for (elem.children.items) |child| {
        if (child != .element) continue;
        const tag = child.element.tag;
        if (eql(tag, "input") or eql(tag, "textarea") or eql(tag, "select") or eql(tag, "button")) {
            // hidden inputs are not visible controls
            if (eql(tag, "input")) {
                const t = child.element.getAttribute("type") orelse "text";
                if (eql(t, "hidden")) continue;
            }
            return true;
        }
        if (hasVisibleControl(child.element)) return true;
    }
    return false;
}

fn renderBlockquote(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);
    // Dim styling for the quote is supplied by the UA stylesheet via the
    // inline style stack in `renderElement`; here we only add the indent.
    const saved_indent = state.hang_indent;
    state.hang_indent += 2;
    try renderChildren(state, w, elem);
    try state.ensureNewline(w);
    state.hang_indent = saved_indent;
}

fn renderPre(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);

    // T2.6: diff/patch coloring — checked first so diffs skip the gutter.
    diff: {
        const text = elem.textContent(state.allocator) catch break :diff;
        defer state.allocator.free(text);
        if (!state.opts.is_diff and !looksLikeDiff(text)) break :diff;
        try renderDiffBlock(state, w, text);
        try state.ensureNewline(w);
        return;
    }

    // T2.4/T2.5: `<pre><code>` blocks with enough lines get a numbered gutter
    // and (when code_style != .none) syntax highlighting.
    line_numbers: {
        if (state.opts.code_line_numbers == std.math.maxInt(usize)) break :line_numbers;
        const code = elem.firstChildByTag("code") orelse break :line_numbers;
        const text = code.textContent(state.allocator) catch break :line_numbers;
        defer state.allocator.free(text);
        const line_count = std.mem.count(u8, text, "\n") + 1;
        if (line_count <= state.opts.code_line_numbers) break :line_numbers;
        const lang: Language = if (state.opts.code_style != .none)
            detectLanguage(code)
        else
            .unknown;
        try renderCodeBlockWithLineNumbers(state, w, text, line_count, lang);
        try state.ensureNewline(w);
        return;
    }

    state.pre_depth += 1;
    try renderChildren(state, w, elem);
    state.pre_depth -= 1;
    try state.ensureNewline(w);
}

/// Render a code-block text with line-number gutter (T2.4) and optional
/// syntax highlighting (T2.5).  `lang` is `.unknown` when highlighting
/// is disabled; the gutter is always dim regardless of language.
fn renderCodeBlockWithLineNumbers(
    state: *RenderState,
    w: anytype,
    text: []const u8,
    line_count: usize,
    lang: Language,
) !void {
    var digit_count: usize = 1;
    {
        var n = line_count;
        while (n >= 10) : (n /= 10) digit_count += 1;
    }

    const highlight = state.opts.code_style != .none and lang != .unknown;

    var line_num: usize = 1;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (state.opts.ansi_colors) try w.writeAll(DIM);
        var num_buf: [20]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "";
        var pad = if (digit_count > num_str.len) digit_count - num_str.len else 0;
        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
        try w.writeAll(num_str);
        try w.writeAll(" \u{2502} "); // │
        if (state.opts.ansi_colors) try w.writeAll(RESET);
        if (highlight) {
            try writeHighlightedLine(w, line, lang, state.opts.ansi_colors);
        } else {
            try w.writeAll(line);
        }
        try w.writeByte('\n');
        state.col = 0;
        line_num += 1;
    }
}

/// True if `text` contains unified-diff markers in its first 10 lines.
/// Detects `--- `, `+++ `, `diff --git`, and `@@ ` as unambiguous signals.
fn looksLikeDiff(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= 10) break;
        if (std.mem.startsWith(u8, line, "--- ") or
            std.mem.startsWith(u8, line, "+++ ") or
            std.mem.startsWith(u8, line, "diff --") or
            std.mem.startsWith(u8, line, "@@ ")) return true;
    }
    return false;
}

/// Render a unified diff block with ANSI color: additions green, deletions
/// red, hunk headers bold, file headers bold.  Falls back to plain text when
/// `ansi_colors` is false.
fn renderDiffBlock(state: *RenderState, w: anytype, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "+++ ") or
            std.mem.startsWith(u8, line, "--- ") or
            std.mem.startsWith(u8, line, "diff --"))
        {
            if (state.opts.ansi_colors) try w.writeAll(BOLD);
            try w.writeAll(line);
            if (state.opts.ansi_colors) try w.writeAll(RESET);
        } else if (std.mem.startsWith(u8, line, "@@")) {
            if (state.opts.ansi_colors) try w.writeAll(BOLD);
            try w.writeAll(line);
            if (state.opts.ansi_colors) try w.writeAll(RESET);
        } else if (line.len > 0 and line[0] == '+') {
            if (state.opts.ansi_colors) try w.writeAll(GREEN);
            try w.writeAll(line);
            if (state.opts.ansi_colors) try w.writeAll(RESET);
        } else if (line.len > 0 and line[0] == '-') {
            if (state.opts.ansi_colors) try w.writeAll(RED);
            try w.writeAll(line);
            if (state.opts.ansi_colors) try w.writeAll(RESET);
        } else {
            try w.writeAll(line);
        }
        try w.writeByte('\n');
        state.col = 0;
    }
}

/// Return true if `word` is a reserved keyword in `lang`.
fn isKeyword(word: []const u8, lang: Language) bool {
    return switch (lang) {
        .zig => isIn(word, &.{
            "const",   "var",      "fn",             "pub",         "return",   "if",     "else",     "while", "for",
            "switch",  "break",    "continue",       "defer",       "errdefer", "try",    "catch",    "error", "union",
            "struct",  "enum",     "packed",         "extern",      "export",   "inline", "noreturn", "void",  "bool",
            "anytype", "comptime", "usingnamespace", "test",        "orelse",   "and",    "or",       "not",   "true",
            "false",   "null",     "undefined",      "unreachable",
        }),
        .rust => isIn(word, &.{
            "fn",    "let",      "mut",   "const",  "pub",    "use",   "mod",   "struct", "enum",
            "impl",  "trait",    "for",   "if",     "else",   "while", "loop",  "match",  "return",
            "break", "continue", "where", "self",   "Self",   "super", "async", "await",  "move",
            "ref",   "type",     "dyn",   "unsafe", "extern", "true",  "false", "None",   "Some",
            "Ok",    "Err",
        }),
        .js, .ts => isIn(word, &.{
            "const",   "let",        "var",     "function", "return", "if",         "else",  "for",
            "while",   "do",         "switch",  "case",     "break",  "continue",   "class", "extends",
            "import",  "export",     "default", "from",     "async",  "await",      "try",   "catch",
            "finally", "throw",      "new",     "this",     "typeof", "instanceof", "true",  "false",
            "null",    "undefined",  "void",    "delete",   "in",     "of",         "type",  "interface",
            "enum",    "implements",
        }),
        .python => isIn(word, &.{
            "def",    "class", "return",   "if",     "elif",  "else",   "for",      "while",
            "import", "from",  "as",       "with",   "try",   "except", "finally",  "raise",
            "pass",   "break", "continue", "lambda", "yield", "global", "nonlocal", "and",
            "or",     "not",   "in",       "is",     "True",  "False",  "None",
        }),
        .sh => isIn(word, &.{
            "if",   "then",  "else", "elif",     "fi",     "for",   "while",  "do",   "done",
            "case", "esac",  "in",   "function", "return", "local", "export", "echo", "exit",
            "true", "false",
        }),
        .json => isIn(word, &.{ "true", "false", "null" }),
        .html, .unknown => false,
    };
}

fn isIn(word: []const u8, list: []const []const u8) bool {
    for (list) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

/// Detect language from `class="language-XYZ"` on a `<code>` element.
fn detectLanguage(code: *const dom.Element) Language {
    const cls = code.getAttribute("class") orelse return .unknown;
    var it = std.mem.splitScalar(u8, cls, ' ');
    while (it.next()) |tok| {
        if (!std.mem.startsWith(u8, tok, "language-")) continue;
        const name = tok["language-".len..];
        if (std.mem.eql(u8, name, "zig")) return .zig;
        if (std.mem.eql(u8, name, "rust")) return .rust;
        if (std.mem.eql(u8, name, "js") or std.mem.eql(u8, name, "javascript")) return .js;
        if (std.mem.eql(u8, name, "ts") or std.mem.eql(u8, name, "typescript")) return .ts;
        if (std.mem.eql(u8, name, "py") or std.mem.eql(u8, name, "python")) return .python;
        if (std.mem.eql(u8, name, "html") or std.mem.eql(u8, name, "xml")) return .html;
        if (std.mem.eql(u8, name, "json")) return .json;
        if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "bash") or
            std.mem.eql(u8, name, "shell")) return .sh;
    }
    return .unknown;
}

/// Emit one line of source code with simple token-based highlighting.
///
/// State machine: normal → string (on quote) → back; normal → comment
/// (on // or #) → rest of line dim.  Keywords get BOLD; strings GREEN;
/// numbers YELLOW; comments DIM.  When `ansi` is false, all control
/// sequences are suppressed and plain text is emitted.
fn writeHighlightedLine(w: anytype, line: []const u8, lang: Language, ansi: bool) !void {
    var i: usize = 0;
    var word_start: ?usize = null;

    while (i <= line.len) {
        const at_end = i == line.len;
        const ch: u8 = if (at_end) 0 else line[i];

        // Flush accumulated identifier/keyword word on boundary.
        if (word_start) |ws| {
            const continuing = !at_end and (std.ascii.isAlphanumeric(ch) or ch == '_');
            if (!continuing) {
                const word = line[ws..i];
                if (ansi and isKeyword(word, lang)) {
                    try w.writeAll(BOLD);
                    try w.writeAll(word);
                    try w.writeAll(RESET);
                } else {
                    try w.writeAll(word);
                }
                word_start = null;
                // Fall through to process ch without advancing i.
            } else {
                i += 1;
                continue;
            }
        }

        if (at_end) break;

        // Line comments.
        if ((lang == .zig or lang == .rust or lang == .js or lang == .ts) and
            ch == '/' and i + 1 < line.len and line[i + 1] == '/')
        {
            if (ansi) try w.writeAll(DIM);
            try w.writeAll(line[i..]);
            if (ansi) try w.writeAll(RESET);
            break;
        }
        if ((lang == .python or lang == .sh) and ch == '#') {
            if (ansi) try w.writeAll(DIM);
            try w.writeAll(line[i..]);
            if (ansi) try w.writeAll(RESET);
            break;
        }

        // String literals (' or ").
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            const str_start = i;
            i += 1;
            while (i < line.len) : (i += 1) {
                if (line[i] == '\\') {
                    i += 1; // skip escape char (loop will add one more)
                } else if (line[i] == quote) {
                    i += 1;
                    break;
                }
            }
            if (ansi) try w.writeAll(GREEN);
            try w.writeAll(line[str_start..i]);
            if (ansi) try w.writeAll(RESET);
            continue;
        }
        // Template literals (JS/TS only).
        if ((lang == .js or lang == .ts) and ch == '`') {
            const str_start = i;
            i += 1;
            while (i < line.len and line[i] != '`') {
                if (line[i] == '\\') i += 1;
                i += 1;
            }
            if (i < line.len) i += 1;
            if (ansi) try w.writeAll(GREEN);
            try w.writeAll(line[str_start..i]);
            if (ansi) try w.writeAll(RESET);
            continue;
        }

        // Numeric literals.
        if (std.ascii.isDigit(ch)) {
            const num_start = i;
            while (i < line.len and
                (std.ascii.isAlphanumeric(line[i]) or line[i] == '.' or line[i] == '_'))
            {
                i += 1;
            }
            if (ansi) try w.writeAll(YELLOW);
            try w.writeAll(line[num_start..i]);
            if (ansi) try w.writeAll(RESET);
            continue;
        }

        // Identifier start → accumulate for keyword check.
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            word_start = i;
            i += 1;
            continue;
        }

        // Punctuation / whitespace — emit verbatim.
        try w.writeByte(ch);
        i += 1;
    }
}

fn renderCode(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const text = elem.textContentForExtract(state.allocator) catch return;
    defer state.allocator.free(text);
    if (text.len == 0) return;
    try state.writeAll(w, "`");
    try state.writeAll(w, text);
    try state.writeAll(w, "`");
}

fn renderHr(state: *RenderState, w: anytype) anyerror!void {
    try state.ensureNewline(w);
    for (0..state.opts.max_width) |_| {
        try w.writeByte('-');
    }
    try state.newline(w);
}

/// Step 10: surface a `<header>` / `<section>` / `<figure>` element's
/// CSS `background-image: url(...)` (or `background:` shorthand) as
/// an inline image — same protocol bytes as a regular `<img>`. Only
/// fires when the pipeline pre-fetched matching bytes (i.e., the URL
/// passed `extractBackgroundUrl` and the fetch + encode succeeded).
///
/// The URL extractor MUST match `pipeline.extractBackgroundUrl`'s
/// output for the same `style` value — they're the two halves of the
/// pipeline → renderer key contract. Any divergence becomes a silent
/// "fetched image but never emitted" loss.
fn tryEmitBackgroundImage(state: *RenderState, w: anytype, elem: *const dom.Element, lookup: ImageLookup) !void {
    const style = elem.getAttribute("style") orelse return;
    const url = extractBgUrlFromStyle(style) orelse return;
    if (lookup.get(url)) |bytes| {
        try state.ensureNewline(w);
        try w.writeAll(bytes);
        try state.newline(w);
    }
}

/// Extract the URL from a CSS `background` / `background-image`
/// declaration. Mirrors `pipeline.extractBackgroundUrl` exactly —
/// see the pipeline source for design notes. Duplicated here because
/// the page module (where this lives) and the image_pipeline module
/// can't share private helpers without expanding the named-module
/// surface.
fn extractBgUrlFromStyle(style: []const u8) ?[]const u8 {
    var idx: usize = 0;
    while (idx < style.len) {
        const bg = indexOfICaseFromStart(style, idx, "background") orelse return null;
        var probe = bg + "background".len;
        if (probe + 6 <= style.len and std.ascii.eqlIgnoreCase(style[probe .. probe + 6], "-image")) {
            probe += 6;
        }
        while (probe < style.len and (style[probe] == ' ' or style[probe] == '\t')) : (probe += 1) {}
        if (probe >= style.len or style[probe] != ':') {
            idx = bg + 1;
            continue;
        }
        probe += 1;
        const end = std.mem.indexOfScalarPos(u8, style, probe, ';') orelse style.len;
        const value = style[probe..end];
        if (indexOfICaseFromStart(value, 0, "gradient") != null) return null;
        if (indexOfICaseFromStart(value, 0, "image-set") != null) return null;
        const url_kw = indexOfICaseFromStart(value, 0, "url(") orelse return null;
        const url_start = url_kw + 4;
        const url_close = std.mem.indexOfScalarPos(u8, value, url_start, ')') orelse return null;
        const inner = std.mem.trim(u8, value[url_start..url_close], " \t\"'");
        if (inner.len == 0) return null;
        return inner;
    }
    return null;
}

fn indexOfICaseFromStart(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or start >= haystack.len) return null;
    if (haystack.len < needle.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn renderImage(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    if (!state.opts.show_images) return;

    // Inline-image fast path: if a lookup is configured and the URL
    // resolves to encoded bytes, emit them raw and skip the alt-ref.
    // The bytes contain protocol-specific control sequences (APC, OSC,
    // DCS) that must NOT pass through `state.writeAll`'s column-
    // tracking byte-by-byte path — that would mis-account columns.
    // Use `w.writeAll` directly and reset structural state to
    // line-start afterwards so the next sibling lays out cleanly.
    if (state.opts.image_lookup) |lookup| {
        const src = elem.getAttribute("src") orelse "";
        if (src.len > 0) {
            if (lookup.get(src)) |bytes| {
                try state.ensureNewline(w);
                try w.writeAll(bytes);
                try state.newline(w);
                try reserveImageRows(state, w, lookup, src);
                return;
            }
        }
    }

    // HTML spec: an explicit `alt=""` marks the image as decorative —
    // screen readers skip it. Treat it the same way in the terminal
    // render: emit nothing (no `[]` placeholder, no link footnote).
    // Real-world payoff: Google/X/etc. use `alt=""` for icons inside
    // text links, which would otherwise spam the page with `[]` and
    // duplicate footnote refs that aren't useful targets.
    const alt_attr = elem.getAttribute("alt");
    if (alt_attr) |alt_val| {
        if (alt_val.len == 0) return;
    }
    const alt = alt_attr orelse "image";

    try state.writeAll(w, "[");
    try state.writeAll(w, alt);
    try state.writeAll(w, "]");
    if (state.opts.show_links) {
        const src = elem.getAttribute("src") orelse "";
        if (src.len > 0) {
            const idx = state.registerLink(@intFromPtr(elem), src, alt) catch return;
            if (state.opts.profile == .default) {
                const ref = try std.fmt.allocPrint(state.allocator, "[{d}]", .{idx});
                defer state.allocator.free(ref);
                try state.writeAll(w, ref);
            }
        }
    }
}

/// T5: reserve a single-blob image's vertical footprint in the browse model.
///
/// kitty / iterm / sixel images encode to one logical line of protocol bytes
/// but paint `r` terminal rows; without reservation the browse model counts
/// them as a single line and the TUI lays following content over the image.
/// Emitting `r - 1` blank lines after the image line makes `ScreenModel.lines`
/// account for every row the image occupies, so the next content starts below
/// it. Skipped when:
///   • not the browse profile — the streaming `awr render` path relies on the
///     terminal advancing the cursor as it paints the image, and extra blank
///     lines there would double the gap;
///   • braille — those bytes already carry internal newlines (one model line
///     per row), so the footprint is reserved by construction;
///   • the lookup carries no row count (rows() == null) — nothing to reserve.
fn reserveImageRows(state: *RenderState, w: anytype, lookup: ImageLookup, src: []const u8) anyerror!void {
    if (state.opts.profile != .browse) return;
    if (state.opts.image_protocol == .braille) return;
    const r = lookup.rows(src) orelse return;
    var i: u32 = 1; // the image's own line is already emitted
    while (i < r) : (i += 1) try state.newline(w);
}

fn renderInput(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const input_type = elem.getAttribute("type") orelse "text";
    const name = elem.getAttribute("name") orelse "";

    if (eql(input_type, "hidden")) {
        // Hidden inputs are invisible to the renderer but must still be
        // registered as fields so `BrowserSession.submitForm` can include
        // their `value` attribute in the encoded body — this is the
        // CSRF-token round-trip required by spec/subspecs/agent-browser.md §2.
        // Visible-nav helpers in `browser.zig` filter hidden fields out so
        // they do not show up in tab order or status counts.
        _ = state.registerField(
            @intFromPtr(elem),
            name,
            "hidden",
            "",
            state.col,
            0,
            false,
        ) catch {};
        return;
    }
    if (eql(input_type, "submit") or eql(input_type, "reset") or eql(input_type, "button")) {
        const label = elem.getAttribute("value") orelse if (eql(input_type, "submit")) "Submit" else if (eql(input_type, "reset")) "Reset" else "Button";
        const col = state.col;
        const focused = focusMatches(state.opts.focused_element_ptr, elem);
        try state.prepareForContent(w);
        // T2.8: apply REVERSE over BOLD when focused so the button is visually
        // distinct regardless of which control is active.
        if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
        try state.ansi(w, BOLD);
        try state.writeAll(w, "[");
        try state.writeAll(w, label);
        try state.writeAll(w, "]");
        try state.ansi(w, RESET);
        const width = label.len + 2;
        _ = state.registerField(
            @intFromPtr(elem),
            name,
            input_type,
            label,
            col,
            width,
            true,
        ) catch {};
        return;
    }

    if (eql(input_type, "checkbox") or eql(input_type, "radio")) {
        const is_radio = eql(input_type, "radio");
        // Resolve checked state: user toggle wins; otherwise DOM
        // `checked` attribute. T-81.
        const checked: bool = if (state.opts.is_checked_lookup) |l|
            l.lookup(@intFromPtr(elem)) orelse (elem.getAttribute("checked") != null)
        else
            (elem.getAttribute("checked") != null);

        const focused = focusMatches(state.opts.focused_element_ptr, elem);
        try state.prepareForContent(w);
        if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
        const glyph: []const u8 = if (is_radio)
            (if (checked) "(*)" else "( )")
        else
            (if (checked) "[x]" else "[ ]");
        try state.writeAll(w, glyph);
        if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
        _ = state.registerField(
            @intFromPtr(elem),
            name,
            input_type,
            "",
            state.col - 3,
            3,
            false,
        ) catch {};
        return;
    }

    const field_width: usize = 20;
    // T-72b: prefer the user's typed value (from BrowserSession's
    // field_values map) over the DOM's value attribute. The lookup
    // returns null for fields the user hasn't touched yet, falling
    // back to whatever the DOM had (server-side default, hidden
    // pre-fill, etc.).
    const dom_value = elem.getAttribute("value") orelse "";
    const value: []const u8 = if (state.opts.field_value_lookup) |fvl|
        fvl.lookup(name) orelse dom_value
    else
        dom_value;
    const col = state.col;
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    try state.prepareForContent(w);
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.writeAll(w, "[");
    if (eql(input_type, "password")) {
        for (0..@min(value.len, field_width)) |_| {
            try state.writeByte(w, '*');
        }
    } else {
        const shown = if (value.len > field_width) value[0..field_width] else value;
        try state.writeAll(w, shown);
    }
    const remaining = field_width - @min(value.len, field_width);
    for (0..remaining) |_| {
        try state.writeByte(w, '_');
    }
    try state.writeAll(w, "]");
    if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
    _ = state.registerField(
        @intFromPtr(elem),
        name,
        if (eql(input_type, "password")) "password" else "text",
        "",
        col,
        field_width + 2,
        false,
    ) catch {};
}

fn focusMatches(focused_ptr: ?usize, elem: *const dom.Element) bool {
    const fp = focused_ptr orelse return false;
    return fp == @intFromPtr(elem);
}

fn renderButton(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const label = elem.textContentForExtract(state.allocator) catch "Button";
    defer state.allocator.free(label);
    const trimmed_text = std.mem.trim(u8, label, " \t\r\n");

    // T-76: icon-only buttons (Google's voice/lens/etc.) have empty text
    // content — they used to render as `[]`. Fall back to aria-label /
    // title / value / name in priority order so the user sees *what*
    // they're focusing. This matches screen-reader resolution.
    const display: []const u8 = if (trimmed_text.len > 0)
        trimmed_text
    else if (elem.getAttribute("aria-label")) |al|
        al
    else if (elem.getAttribute("title")) |t|
        t
    else if (elem.getAttribute("value")) |v|
        v
    else if (elem.getAttribute("name")) |n|
        n
    else
        "button";

    const col = state.col;
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    try state.prepareForContent(w);
    // T2.8: uniform focus highlight — REVERSE overlaid on BOLD when focused.
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.ansi(w, BOLD);
    try state.writeAll(w, "[");
    try state.writeAll(w, display);
    try state.writeAll(w, "]");
    try state.ansi(w, RESET);
    const name = elem.getAttribute("name") orelse "";
    const btn_type = elem.getAttribute("type") orelse "submit";
    _ = state.registerField(
        @intFromPtr(elem),
        name,
        btn_type,
        display,
        col,
        display.len + 2,
        eql(btn_type, "submit"),
    ) catch {};
}

/// True when a generic element is a non-native keyboard-focusable control:
/// `role="button"` or a non-negative `tabindex`. Native controls
/// (input/button/select/textarea/a) are dispatched by their own renderers
/// before this point, so this only catches generic elements (div/span/…). T1.
fn genericFocusable(elem: *const dom.Element) bool {
    if (elem.getAttribute("role")) |r| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, r, " \t\r\n"), "button")) return true;
    }
    if (elem.getAttribute("tabindex")) |t| {
        const v = std.fmt.parseInt(i32, std.mem.trim(u8, t, " \t\r\n"), 10) catch return false;
        return v >= 0; // negative tabindex is script-focusable only, not in Tab order
    }
    return false;
}

/// Render a non-native focusable (see `genericFocusable`): its content with a
/// focus highlight when selected, registered as a non-submit "button" field so
/// Tab reaches it and Enter/Space dispatches a click (T1, browser.zig).
///
/// Only elements that render visible content of their own become focusable
/// targets. Icon-only generic focusables (e.g. GitHub's `<summary role="button">`
/// that merely wraps a native close button) are left to their normal rendering
/// — synthesizing a label marker for them would duplicate adjacent native
/// controls and add noise. Native `<button>`/`<input>` still handle the
/// icon-only case via their own renderers.
fn renderFocusable(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    if (isBlockTag(elem.tag)) try state.ensureNewline(w);
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    const label: []const u8 = elem.getAttribute("aria-label") orelse
        (elem.getAttribute("title") orelse "button");
    try state.prepareForContent(w);
    const col = state.col;
    const line = state.line_index;
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try renderChildren(state, w, elem);
    if (focused and state.opts.ansi_colors) try state.styleReset(w);
    // Register as a focusable button only when the element produced visible
    // content (advanced the column on this line, or wrapped to a later line).
    if (state.line_index != line or state.col != col) {
        const width = if (state.line_index == line and state.col > col) state.col - col else label.len;
        _ = state.registerField(@intFromPtr(elem), "", "button", label, col, width, false) catch {};
    }
}

fn renderSelect(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    // T-83 priority: user-selected option (from inline picker) wins
    // over DOM `<option selected>`, which wins over first option.
    // The user-selected label is borrowed from the session — no dupe
    // needed; it lives at least until the next page change.
    var first_option: ?[]const u8 = null;
    var selected_option: ?[]const u8 = null;
    for (elem.children.items) |child| {
        if (child != .element) continue;
        if (!eql(child.element.tag, "option")) continue;
        const text = child.element.textContentForExtract(state.allocator) catch continue;
        defer state.allocator.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (child.element.getAttribute("selected") != null) {
            if (selected_option) |opt| state.allocator.free(opt);
            selected_option = try state.allocator.dupe(u8, trimmed);
            break;
        }
        if (first_option == null) {
            first_option = try state.allocator.dupe(u8, trimmed);
        }
    }
    defer if (first_option) |opt| state.allocator.free(opt);
    defer if (selected_option) |opt| state.allocator.free(opt);

    const user_selected: ?[]const u8 = if (state.opts.selected_option_lookup) |l|
        l.lookup(@intFromPtr(elem))
    else
        null;
    const display = user_selected orelse selected_option orelse first_option orelse "";
    const col = state.col;
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    try state.prepareForContent(w);
    // T2.8: uniform focus highlight.
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.writeAll(w, "[");
    try state.writeAll(w, display);
    try state.writeAll(w, " ▼]");
    if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
    const name = elem.getAttribute("name") orelse "";
    _ = state.registerField(
        @intFromPtr(elem),
        name,
        "select",
        display,
        col,
        display.len + 4,
        false,
    ) catch {};
}

fn renderTextarea(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    const dom_value = elem.textContentForExtract(state.allocator) catch "";
    defer state.allocator.free(dom_value);
    const name = elem.getAttribute("name") orelse "";
    // T-72b: user-typed value beats the DOM-default if present.
    const raw_value: []const u8 = if (state.opts.field_value_lookup) |fvl|
        fvl.lookup(name) orelse dom_value
    else
        dom_value;
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    const col = state.col;
    const focused = focusMatches(state.opts.focused_element_ptr, elem);
    const rows: usize = blk: {
        const rows_str = elem.getAttribute("rows") orelse "2";
        break :blk std.fmt.parseInt(usize, rows_str, 10) catch 2;
    };
    const cols: usize = blk: {
        const cols_str = elem.getAttribute("cols") orelse "20";
        break :blk std.fmt.parseInt(usize, cols_str, 10) catch 20;
    };
    try state.prepareForContent(w);
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.writeAll(w, "+");
    for (0..cols) |_| try state.writeByte(w, '-');
    try state.writeAll(w, "+");
    if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
    try state.newline(w);
    var line_idx: usize = 0;
    var byte_idx: usize = 0;
    while (line_idx < rows) : (line_idx += 1) {
        try state.prepareForContent(w);
        if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
        try state.writeByte(w, '|');
        var char_count: usize = 0;
        while (char_count < cols and byte_idx < trimmed.len) {
            if (trimmed[byte_idx] == '\n') {
                byte_idx += 1;
                break;
            }
            try state.writeByte(w, trimmed[byte_idx]);
            byte_idx += 1;
            char_count += 1;
        }
        while (char_count < cols) {
            try state.writeByte(w, ' ');
            char_count += 1;
        }
        try state.writeByte(w, '|');
        if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
        if (line_idx < rows - 1) try state.newline(w);
    }
    try state.newline(w);
    try state.prepareForContent(w);
    if (focused and state.opts.ansi_colors) try state.ansi(w, REVERSE);
    try state.writeAll(w, "+");
    for (0..cols) |_| try state.writeByte(w, '-');
    try state.writeAll(w, "+");
    if (focused and state.opts.ansi_colors) try state.ansi(w, RESET);
    _ = state.registerField(
        @intFromPtr(elem),
        name,
        "textarea",
        "",
        col,
        cols + 2,
        false,
    ) catch {};
}

fn renderBrowseStrongLandmark(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try ensureSectionBreak(state, w);
    try renderChildren(state, w, elem);
    try state.ensureNewline(w);
    try state.newline(w);
}

fn renderBrowseCompactLandmark(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);
    try state.ansi(w, DIM);
    try renderChildren(state, w, elem);
    try state.ansi(w, RESET);
    try state.ensureNewline(w);
    try state.newline(w);
}

fn renderCollapsedLandmark(state: *RenderState, w: anytype, tag: []const u8) anyerror!void {
    try state.ensureNewline(w);
    try state.ansi(w, DIM);
    try state.writeAll(w, collapsedLabel(tag));
    try state.ansi(w, RESET);
    try state.newline(w);
    try state.newline(w);
}

fn ensureSectionBreak(state: *RenderState, w: anytype) !void {
    try state.ensureNewline(w);
    if (state.line_index > 0) try state.newline(w);
}

fn collapsedLabel(tag: []const u8) []const u8 {
    if (eql(tag, "nav")) return "[Navigation omitted]";
    if (eql(tag, "aside")) return "[Sidebar omitted]";
    if (eql(tag, "footer")) return "[Footer omitted]";
    return "[Header omitted]";
}

// strong/b and em/i carry their emphasis through the UA stylesheet
// (`uaTagStyle`) and the inline style stack applied in `renderElement`, which
// composes with inherited color/emphasis instead of clobbering it (no blanket
// RESET — fixes the nested-ANSI limitation noted in the file header).
fn renderStrong(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try renderChildren(state, w, elem);
}

fn renderEm(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try renderChildren(state, w, elem);
}

// ── Text node renderer ────────────────────────────────────────────────────

fn renderTextNode(state: *RenderState, w: anytype, text_node: *const dom.Text) anyerror!void {
    const raw = text_node.data;
    if (raw.len == 0) return;

    // Inside <pre>: preserve whitespace verbatim.
    if (state.inPre()) {
        try state.writeAll(w, raw);
        return;
    }

    // Outside <pre>: normalise whitespace, then word-wrap. §2.1: inter-word
    // spacing is tracked on `state.pending_space` so it carries across node
    // boundaries — a leading space here honors a word emitted by a previous
    // sibling/inline element, and a trailing space requests a separator
    // before whatever inline content follows (e.g. an adjacent `<a>`).
    var buf: [8192]u8 = undefined;
    const normalized = normalizeWhitespace(&buf, raw);
    if (normalized.len == 0) return;

    // CSS text-transform (visual only): applied to TUI output, never to the
    // extracted/JSON text. ASCII-only; multibyte UTF-8 is left untouched.
    if (state.opts.ansi_colors and state.cur_style.transform != .none) {
        applyTransformInPlace(@constCast(normalized), state.cur_style.transform);
    }

    // A normalized leading space means this node was preceded by whitespace
    // in the source; honor it as a pending separator before the first word.
    if (normalized[0] == ' ') state.pending_space = true;

    var it = std.mem.splitScalar(u8, normalized, ' ');
    while (it.next()) |word| {
        if (word.len == 0) continue;
        try state.flowWord(w, word);
        state.pending_space = true;
    }

    // A normalized trailing space means the next inline node must be
    // separated from this one; leave `pending_space` set. Otherwise the
    // text ended flush against following content (rare after normalize, but
    // possible mid-word splits) — clear it so we don't inject a phantom space.
    if (normalized[normalized.len - 1] != ' ') state.pending_space = false;
}

// ── Table renderer ────────────────────────────────────────────────────────

fn countTableLinkMetricsInner(
    elem: *const dom.Element,
    in_link: bool,
    link_count: *usize,
    text_bytes: *usize,
    link_text_bytes: *usize,
    paragraph_count: *usize,
) void {
    const is_link = eql(elem.tag, "a");
    if (is_link) link_count.* += 1;
    if (eql(elem.tag, "p")) paragraph_count.* += 1;

    const child_in_link = in_link or is_link;
    for (elem.children.items) |child| {
        switch (child) {
            .text => |text_node| {
                for (text_node.data) |ch| {
                    if (!std.ascii.isWhitespace(ch)) {
                        text_bytes.* += 1;
                        if (child_in_link) link_text_bytes.* += 1;
                    }
                }
            },
            .element => |child_elem| {
                countTableLinkMetricsInner(child_elem, child_in_link, link_count, text_bytes, link_text_bytes, paragraph_count);
            },
            else => {},
        }
    }
}

fn isLinkListTable(elem: *const dom.Element) bool {
    var link_count: usize = 0;
    var text_bytes: usize = 0;
    var link_text_bytes: usize = 0;
    var paragraph_count: usize = 0;
    countTableLinkMetricsInner(elem, false, &link_count, &text_bytes, &link_text_bytes, &paragraph_count);
    if (link_count < 3) return false;
    if (text_bytes < 80) return false;
    if (paragraph_count > 0) return false;
    const density = if (text_bytes == 0) @as(f64, 0.0) else @as(f64, @floatFromInt(link_text_bytes)) / @as(f64, @floatFromInt(text_bytes));
    return density >= 0.35;
}

/// §2.4: true if the table subtree contains any `<th>` element.
/// A `<th>` indicates a proper data table; its absence means the author
/// is using `<table>` for layout purposes (e.g. HN, YC jobs, infoboxes).
fn hasThCell(elem: *const dom.Element) bool {
    for (elem.children.items) |child| {
        if (child == .element) {
            if (eql(child.element.tag, "th")) return true;
            if (hasThCell(child.element)) return true;
        }
    }
    return false;
}

/// §2.4: emit a layout table (one with no `<th>`) in DOM reading order.
/// Each row's cells flow inline, separated by the §2.1 pending-space
/// mechanism; rows are separated by newlines. No column alignment, no
/// row separators — just readable left-to-right text flow.
fn renderLayoutTable(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    var rows: std.ArrayList(*const dom.Element) = .empty;
    defer rows.deinit(state.allocator);
    collectTableRows(state.allocator, elem, &rows);

    for (rows.items) |row| {
        state.pending_space = false;
        var had_content = false;
        for (row.children.items) |cell| {
            if (cell == .element and isCellTag(cell.element.tag)) {
                try renderChildren(state, w, cell.element);
                state.pending_space = true;
                had_content = true;
            }
        }
        // §2.4: use `col > 0` to detect whether content was actually written
        // to the current line, rather than `at_line_start`. With hang_indent=0,
        // `prepareForContent` never clears `at_line_start`, so `ensureNewline`
        // would be a no-op. `state.col` is authoritative for actual content width.
        if (had_content and state.col > 0) try state.newline(w);
    }
}

fn renderTable(state: *RenderState, w: anytype, elem: *const dom.Element) anyerror!void {
    try state.ensureNewline(w);

    // T-72: layout-table detection. Tables containing user-editable
    // form controls (textarea / select / non-hidden input / button) are
    // structural layout, not tabular data. Real data tables never have
    // form fields in their cells — but legacy + old-school sites
    // (Google's homepage, login pages, w3c form examples) routinely
    // wrap forms in `<table>` for column alignment. The columnar
    // renderer flattens cell content via collectTableCellDisplayText,
    // which strips form controls down to text and never dispatches to
    // renderTextarea / renderInput. Switching to block flow lets the
    // cell's children reach their proper renderers and produce visible
    // input boxes.
    if (containsLayoutFormControl(elem)) {
        try renderChildren(state, w, elem);
        return;
    }

    // §2.4: tables with no `<th>` are used for layout, not tabular data.
    // Emit cells in DOM reading order so HN, YC jobs, and similar sites
    // render as readable prose instead of scrambled positional columns.
    if (!hasThCell(elem)) {
        try renderLayoutTable(state, w, elem);
        return;
    }

    // Collect all <tr> rows (may be inside thead/tbody/tfoot).
    var rows: std.ArrayList(*const dom.Element) = .empty;
    defer rows.deinit(state.allocator);
    collectTableRows(state.allocator, elem, &rows);
    if (rows.items.len == 0) return;

    // Determine column count.
    var max_cols: usize = 0;
    for (rows.items) |row| {
        var count: usize = 0;
        for (row.children.items) |cell| {
            if (cell == .element and isCellTag(cell.element.tag)) count += 1;
        }
        max_cols = @max(max_cols, count);
    }
    if (max_cols == 0) return;

    const per_col_width = tableColumnWidthLimit(state.opts.max_width, max_cols);

    // Measure column widths.
    var widths = try state.allocator.alloc(usize, max_cols);
    defer state.allocator.free(widths);
    @memset(widths, 0);
    var preview_link_index = state.links.items.len;
    for (rows.items) |row| {
        var ci: usize = 0;
        for (row.children.items) |cell| {
            if (cell == .element and isCellTag(cell.element.tag)) {
                if (ci < max_cols) {
                    if (collectTableCellDisplayText(state, cell.element, &preview_link_index)) |text| {
                        defer state.allocator.free(text);
                        widths[ci] = @max(widths[ci], measureWrappedWidth(text, per_col_width));
                    } else |_| {}
                }
                ci += 1;
            }
        }
    }
    for (widths) |*width| {
        width.* = @max(@min(width.*, per_col_width), 1);
    }

    const is_link_list = isLinkListTable(elem);

    // T2.7: sticky-header tracking.
    const has_header = rows.items.len > 1 and rowHasHeader(rows.items[0]);
    var header_line_start: usize = 0;
    var header_line_end: usize = 0;

    // Render each row.
    for (rows.items, 0..) |row, ri| {
        // T2.7: snap start-of-header before row 0.
        if (ri == 0 and has_header) header_line_start = state.line_index;

        // Separator between rows.
        if (ri > 0 and !is_link_list) {
            for (0..max_cols) |ci| {
                if (ci > 0) try state.writeByte(w, ' ');
                for (0..widths[ci] + 2) |_| try state.writeByte(w, '-');
            }
            try state.newline(w);
        }
        var cells = try state.allocator.alloc(WrappedCell, max_cols);
        defer state.allocator.free(cells);
        for (cells) |*cell| cell.* = .{};
        defer {
            for (cells) |*cell| cell.deinit(state.allocator);
        }

        var row_height: usize = 1;
        var ci: usize = 0;
        for (row.children.items) |cell| {
            if (cell == .element and isCellTag(cell.element.tag)) {
                if (ci < max_cols) {
                    cells[ci] = try wrapTableCell(state, state.allocator, cell.element, widths[ci]);
                    row_height = @max(row_height, cells[ci].lines.items.len);
                }
                ci += 1;
            }
        }

        for (0..row_height) |line_idx| {
            for (0..max_cols) |col_idx| {
                if (col_idx > 0) try state.writeByte(w, ' ');
                try state.writeByte(w, ' ');
                const line = if (line_idx < cells[col_idx].lines.items.len) cells[col_idx].lines.items[line_idx] else "";
                try state.writeAll(w, line);
                if (line.len < widths[col_idx]) {
                    for (0..widths[col_idx] - line.len) |_| try state.writeByte(w, ' ');
                }
                try state.writeByte(w, ' ');
            }
            try state.newline(w);
        }

        // T2.7: snap end-of-header after row 0 (includes the separator drawn
        // at ri==1 below, so we record *before* that separator).
        if (ri == 0 and has_header) header_line_end = state.line_index;
    }

    // T2.7: record the sticky header once the whole table is rendered.
    if (has_header) {
        state.sticky_hdrs.append(state.allocator, .{
            .header_line_start = header_line_start,
            .header_line_end = header_line_end,
            .table_line_end = state.line_index,
        }) catch {};
    }
}

/// True if the first row of a table has at least one `<th>` cell.
fn rowHasHeader(row: *const dom.Element) bool {
    for (row.children.items) |child| {
        if (child == .element and eql(child.element.tag, "th")) return true;
    }
    return false;
}

const WrappedCell = struct {
    text: []u8 = &.{},
    lines: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *WrappedCell, allocator: std.mem.Allocator) void {
        self.lines.deinit(allocator);
        if (self.text.len > 0) allocator.free(self.text);
    }
};

const WrappedLineIterator = struct {
    text: []const u8,
    width: usize,

    fn init(text: []const u8, width: usize) WrappedLineIterator {
        return .{
            .text = std.mem.trim(u8, text, " \t\r\n"),
            .width = @max(width, 1),
        };
    }

    fn next(self: *WrappedLineIterator) ?[]const u8 {
        self.text = std.mem.trim(u8, self.text, " ");
        if (self.text.len == 0) return null;
        if (self.text.len <= self.width) {
            const line = self.text;
            self.text = "";
            return line;
        }

        var break_at = self.width;
        while (break_at > 0 and self.text[break_at] != ' ') : (break_at -= 1) {}
        if (break_at == 0) break_at = self.width;

        const line = std.mem.trim(u8, self.text[0..break_at], " ");
        self.text = self.text[break_at..];
        return line;
    }
};

fn tableColumnWidthLimit(max_width: usize, cols: usize) usize {
    const safe_cols = @max(cols, 1);
    const separators = safe_cols - 1;
    const padding = safe_cols * 2;
    const reserved = separators + padding;
    if (max_width <= reserved) return 1;
    return @max((max_width - reserved) / safe_cols, 1);
}

fn wrapTableCell(
    state: *RenderState,
    allocator: std.mem.Allocator,
    elem: *const dom.Element,
    width: usize,
) !WrappedCell {
    var wrapped = WrappedCell{ .text = try collectTableCellDisplayText(state, elem, null) };
    errdefer wrapped.deinit(allocator);

    var it = WrappedLineIterator.init(wrapped.text, width);
    while (it.next()) |line| {
        try wrapped.lines.append(allocator, line);
    }
    if (wrapped.lines.items.len == 0) {
        try wrapped.lines.append(allocator, "");
    }
    return wrapped;
}

fn measureWrappedWidth(text: []const u8, width: usize) usize {
    var it = WrappedLineIterator.init(text, width);
    var max_line: usize = 0;
    while (it.next()) |line| {
        max_line = @max(max_line, line.len);
    }
    return max_line;
}

/// True if any descendant of `elem` is a user-editable form control.
/// Hidden inputs don't count (CSRF round-trip helpers don't make
/// a table "interactive"). Buttons + select + textarea + non-hidden
/// input do.
fn containsLayoutFormControl(elem: *const dom.Element) bool {
    for (elem.children.items) |child| {
        if (child != .element) continue;
        const e = child.element;
        if (eql(e.tag, "textarea") or eql(e.tag, "select") or eql(e.tag, "button")) return true;
        if (eql(e.tag, "input")) {
            const t = e.getAttribute("type") orelse "text";
            if (!std.ascii.eqlIgnoreCase(t, "hidden")) return true;
        }
        if (containsLayoutFormControl(e)) return true;
    }
    return false;
}

fn collectTableCellDisplayText(
    state: *RenderState,
    elem: *const dom.Element,
    preview_link_index: ?*usize,
) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(state.allocator);
    collectTableCellDisplayFragments(state, preview_link_index, elem, &raw);

    const normalized_buf = try state.allocator.alloc(u8, raw.items.len);
    defer state.allocator.free(normalized_buf);

    const normalized = normalizeWhitespace(normalized_buf, raw.items);
    return state.allocator.dupe(u8, std.mem.trim(u8, normalized, " \t\r\n"));
}

fn collectTableCellDisplayFragments(
    state: *RenderState,
    preview_link_index: ?*usize,
    elem: *const dom.Element,
    buf: *std.ArrayList(u8),
) void {
    for (elem.children.items) |child| {
        switch (child) {
            .text => |text_node| buf.appendSlice(state.allocator, text_node.data) catch {},
            .element => |child_elem| {
                // Defensive parity with renderElement's isHiddenTag
                // gate: a <script> / <style> / <noscript> nested
                // inside a table cell otherwise leaks its raw source
                // into the rendered text. Real browsers never paint
                // these. Caught by the Google homepage which puts
                // inline scripts inside the layout <table>; without
                // this check the script body is rendered as visible
                // text alongside neighbor cells.
                if (isHiddenTag(child_elem.tag)) continue;
                if (eql(child_elem.tag, "a")) {
                    collectTableCellDisplayFragments(state, preview_link_index, child_elem, buf);
                    appendTableCellLinkMarker(state, preview_link_index, child_elem, buf);
                    continue;
                }

                const boundary = isTableCellBoundaryTag(child_elem.tag);
                if (boundary) buf.append(state.allocator, ' ') catch {};
                collectTableCellDisplayFragments(state, preview_link_index, child_elem, buf);
                if (boundary) buf.append(state.allocator, ' ') catch {};
            },
            else => {},
        }
    }
}

fn appendTableCellLinkMarker(
    state: *RenderState,
    preview_link_index: ?*usize,
    elem: *const dom.Element,
    buf: *std.ArrayList(u8),
) void {
    if (!state.opts.show_links) return;

    const href = elem.getAttribute("href") orelse return;
    if (href.len == 0) return;

    const raw_text = elem.textContentForExtract(state.allocator) catch return;
    defer state.allocator.free(raw_text);
    const trimmed = std.mem.trim(u8, raw_text, " \t\r\n");

    const idx = if (preview_link_index) |next| blk: {
        next.* += 1;
        break :blk next.*;
    } else state.registerLink(@intFromPtr(elem), href, trimmed) catch return;

    if (state.opts.profile == .default) {
        const marker = std.fmt.allocPrint(state.allocator, "[{d}]", .{idx}) catch return;
        defer state.allocator.free(marker);
        buf.appendSlice(state.allocator, marker) catch {};
    }
}

fn isTableCellBoundaryTag(tag: []const u8) bool {
    return eql(tag, "table") or
        eql(tag, "thead") or
        eql(tag, "tbody") or
        eql(tag, "tfoot") or
        eql(tag, "tr") or
        eql(tag, "td") or
        eql(tag, "th") or
        eql(tag, "div") or
        eql(tag, "p") or
        eql(tag, "ul") or
        eql(tag, "ol") or
        eql(tag, "li") or
        eql(tag, "br");
}

fn collectTableRows(
    allocator: std.mem.Allocator,
    elem: *const dom.Element,
    rows: *std.ArrayList(*const dom.Element),
) void {
    for (elem.children.items) |child| {
        if (child != .element) continue;
        const tag = child.element.tag;
        if (eql(tag, "tr")) {
            rows.append(allocator, child.element) catch {};
        } else if (eql(tag, "thead") or eql(tag, "tbody") or eql(tag, "tfoot")) {
            collectTableRows(allocator, child.element, rows);
        }
    }
}

fn isCellTag(tag: []const u8) bool {
    return eql(tag, "td") or eql(tag, "th");
}

// ── Tag classification helpers ────────────────────────────────────────────

fn isHiddenTag(tag: []const u8) bool {
    inline for (.{
        "script", "style", "noscript", "head", "svg", "math",
    }) |h| {
        if (std.ascii.eqlIgnoreCase(tag, h)) return true;
    }
    return false;
}

fn isCssHidden(state: *RenderState, elem: *const dom.Element) bool {
    for (state.hide_rules.items) |rule| {
        var selectors = std.mem.splitScalar(u8, rule.selector_text, ',');
        var matched = false;
        while (selectors.next()) |sel| {
            if (elem.matches(sel)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        if (isHiddenCssValue(rule.declarations.getPropertyValue("display"), "none")) {
            // `[hidden]`-attribute resets (e.g. Tailwind / modern-normalize
            // `[hidden]:where(:not([hidden=until-found]))`) hide content that
            // frameworks reveal client-side via JS: React/Next.js stream SSR
            // markup into `<div hidden>` containers and relocate it into the
            // visible tree on hydration; tab panels and disclosure widgets do
            // the same. AWR runs no hydration, so honoring this reset blanks
            // pages whose entire body lives in such a container (every
            // streaming Next.js app). Surface that content instead — it
            // approximates the post-hydration state a real user sees.
            // Explicit inline `display:none` and class/id chrome hides below
            // still apply, so this only relaxes the generic `[hidden]` reset.
            // Gated on the rescue flag so the normal pass still hides small
            // `[hidden]` chrome (e.g. Wikipedia nav) — the relaxation only
            // kicks in on the blank-page rescue re-render.
            if (state.relax_hidden_attr and ruleHidesViaHiddenAttr(rule, elem)) continue;
            return true;
        }
        if (isHiddenCssValue(rule.declarations.getPropertyValue("visibility"), "hidden")) return true;
    }

    if (elem.getAttribute("style")) |style_attr| {
        var style = css_style.StyleDeclaration.parse(state.allocator, style_attr) catch return false;
        defer style.deinit();
        if (isHiddenCssValue(style.getPropertyValue("display"), "none")) return true;
        if (isHiddenCssValue(style.getPropertyValue("visibility"), "hidden")) return true;
    }

    return false;
}

/// True when a `display:none` rule matches `elem` *because of* its `hidden`
/// HTML attribute — i.e. the generic `[hidden]` UA/reset rule, not a content
/// selector. Used to keep JS-revealed content (Next.js streaming containers,
/// tab panels) visible on AWR's non-JS browse surface. Requires both that the
/// element actually carries `hidden` and that the rule's selector references
/// the `[hidden]` attribute, so a `.chrome{display:none}` that happens to land
/// on a `hidden` element still hides as the author intended.
fn ruleHidesViaHiddenAttr(rule: *const css_parser.Rule, elem: *const dom.Element) bool {
    if (elem.getAttribute("hidden") == null) return false;
    return containsIgnoreCaseAscii(rule.selector_text, "[hidden");
}

fn containsIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isHiddenCssValue(value: []const u8, expected: []const u8) bool {
    if (value.len == 0) return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, value, " \t\r\n"), expected);
}

/// True when the element's resolved `white-space` is `pre`, `pre-wrap`, or
/// `pre-line` — all three preserve newlines/whitespace. Mirrors the
/// stylesheet+inline scan in `isCssHidden`. CSSOM §4.6.3 closure gate.
fn isCssWhiteSpacePreserved(state: *RenderState, elem: *const dom.Element) bool {
    // Inline style wins over stylesheets per the cascade (specificity 1,0,0,0).
    if (elem.getAttribute("style")) |style_attr| {
        var style = css_style.StyleDeclaration.parse(state.allocator, style_attr) catch return false;
        defer style.deinit();
        const inline_val = style.getPropertyValue("white-space");
        if (inline_val.len > 0) return whiteSpacePreservesWhitespace(inline_val);
    }

    for (state.ws_rules.items) |rule| {
        var selectors = std.mem.splitScalar(u8, rule.selector_text, ',');
        var matched = false;
        while (selectors.next()) |sel| {
            if (elem.matches(sel)) {
                matched = true;
                break;
            }
        }
        if (!matched) continue;
        const val = rule.declarations.getPropertyValue("white-space");
        if (val.len > 0) return whiteSpacePreservesWhitespace(val);
    }

    return false;
}

fn whiteSpacePreservesWhitespace(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "pre") or
        std.ascii.eqlIgnoreCase(trimmed, "pre-wrap") or
        std.ascii.eqlIgnoreCase(trimmed, "pre-line");
}

fn isBlockTag(tag: []const u8) bool {
    inline for (.{
        "div",        "p",        "h1",      "h2",      "h3",         "h4",      "h5",    "h6",
        "blockquote", "pre",      "ul",      "ol",      "li",         "table",   "thead", "tbody",
        "tfoot",      "tr",       "td",      "th",      "section",    "article", "main",  "header",
        "footer",     "nav",      "aside",   "figure",  "figcaption", "dl",      "dt",    "dd",
        "form",       "fieldset", "address", "details", "summary",
    }) |b| {
        if (std.ascii.eqlIgnoreCase(tag, b)) return true;
    }
    return false;
}

fn isCompactLandmarkTag(tag: []const u8) bool {
    return eql(tag, "header") or eql(tag, "nav") or eql(tag, "aside") or eql(tag, "footer");
}

fn isStrongLandmarkTag(tag: []const u8) bool {
    return eql(tag, "main") or eql(tag, "article") or eql(tag, "section");
}

fn headingLevel(tag: []const u8) ?u8 {
    if (tag.len == 2 and
        (tag[0] == 'h' or tag[0] == 'H') and
        tag[1] >= '1' and tag[1] <= '6')
    {
        return tag[1] - '0';
    }
    return null;
}

/// Case-insensitive ASCII equality shortcut.
fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ── Text normalization ────────────────────────────────────────────────────

/// Collapse consecutive whitespace characters to a single space.
fn normalizeWhitespace(buf: []u8, text: []const u8) []u8 {
    var i: usize = 0;
    var in_ws = false;
    for (text) |c| {
        const is_ws = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (is_ws) {
            if (!in_ws and i < buf.len) {
                buf[i] = ' ';
                i += 1;
                in_ws = true;
            }
        } else {
            if (i < buf.len) {
                buf[i] = c;
                i += 1;
            }
            in_ws = false;
        }
    }
    return buf[0..i];
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "render — empty document produces no output" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body></body></html>");
    defer doc.deinit();
    var buf: [256]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    try std.testing.expectEqual(@as(usize, 0), fbs.buffered().len);
}

test "render — heading with decorative underline" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><h1>Hello</h1></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "=====") != null);
}

test "render — heading h2 uses dashes" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><h2>Subtitle</h2></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Subtitle") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-------") != null);
}

test "render — paragraph text" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><p>Hello world.</p></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello world.") != null);
}

test "render §2.1 — space preserved between text and adjacent inline link" {
    // Regression: the space before <a> was dropped because renderTextNode
    // tracked inter-word spacing with a call-local flag, so cross-node
    // whitespace ("foo <a>bar</a> baz") collapsed into "foobar baz".
    var doc = try dom.parseDocument(
        std.testing.allocator,
        "<html><body><p>eight-limbed <a href=\"/m\">mollusc</a> creature</p></body></html>",
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false, .show_links = true });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "eight-limbed mollusc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mollusc") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "creature") != null);
    // The bug signature must be gone.
    try std.testing.expect(std.mem.indexOf(u8, out, "eight-limbedmollusc") == null);
}

test "render §2.1 — linked word wrapping continues at column 0" {
    // A link whose text crosses the right margin must continue at column 0
    // of the next line, not be stranded at the right edge. We render a long
    // run of words followed by a link into a narrow width and assert no
    // rendered line exceeds the width budget (the old bug overflowed).
    const width: usize = 20;
    var doc = try dom.parseDocument(
        std.testing.allocator,
        "<html><body><p>alpha beta gamma delta epsilon <a href=\"/z\">zetawordlong</a> eta</p></body></html>",
    );
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false, .show_links = true, .max_width = width });
    const out = fbs.buffered();
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        // renderLink reserves the footnote ref's width during flow, so the
        // glued "[N]" stays on-line and nothing overflows the budget. (The old
        // behavior appended the ref past the margin, which the real terminal
        // then hard-wrapped mid-word.)
        try std.testing.expect(line.len <= width);
    }
}

test "render — tabindex/role=button elements become focusable button fields (T1)" {
    // T1: non-native controls (tabindex>=0 / role=button) must enter the focus
    // order as click-activatable "button" fields; tabindex<0 and plain elements
    // must not. Wrapped in <main> so the readability picker keeps the content.
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><main>" ++
        "<div tabindex=\"0\">Open dialog</div>" ++
        "<span role=\"button\">Run it</span>" ++
        "<div tabindex=\"-1\">script only</div>" ++
        "<div>plain block of text</div>" ++
        "</main></body></html>");
    defer doc.deinit();
    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 2), model.fields.len);
    for (model.fields) |f| try std.testing.expect(std.mem.eql(u8, f.field_type, "button"));
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Open dialog") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Run it") != null);
}

test "render — links produce reference footnotes" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><a href=\"/page\">Click</a></body></html>");
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_links = true,
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Click") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "References:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/page") != null);
}

test "render — no link footnotes when show_links is false" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><a href=\"/page\">Click</a></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_links = false,
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Click") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "References:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/page") == null);
}

test "render — unordered list" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><ul><li>One</li><li>Two</li><li>Three</li></ul></body></html>");
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "One") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Three") != null);
    // Should contain the bullet character (UTF-8: e2 80 a2)
    try std.testing.expect(std.mem.indexOf(u8, out, "\xe2\x80\xa2") != null);
}

test "render — ordered list" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><ol><li>First</li><li>Second</li></ol></body></html>");
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "1.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "First") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Second") != null);
}

test "render — nested list items" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><ul>
        \\  <li>Item 1
        \\    <ul><li>Sub A</li><li>Sub B</li></ul>
        \\  </li>
        \\  <li>Item 2</li>
        \\</ul></body></html>
    );
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Item 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Sub A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Sub B") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Item 2") != null);
}

test "render — skips script and style content" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <script>var x = 1;</script>
        \\  <style>.a { color: red; }</style>
        \\  <p>Visible</p>
        \\</body></html>
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "var x") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "color") == null);
}

test "render browse profile can surface template content after empty main fallback" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><main></main><template><section><h1>Streamed title</h1><p>Server-rendered fallback text.</p></section></template></body></html>");
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Streamed title") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Server-rendered fallback text") != null);
}

test "render — blockquote content is present" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><blockquote><p>Quoted text.</p></blockquote></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Quoted text.") != null);
}

test "render — pre block preserves whitespace" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><pre>  line1\n  line2\n</pre></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "  line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  line2") != null);
}

test "render — horizontal rule width matches max_width" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><p>Before</p><hr><p>After</p></body></html>");
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .max_width = 20,
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "After") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--------------------") != null);
}

test "render — image alt text and link reference" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><img alt=\"A photo\" src=\"/photo.jpg\"></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[A photo]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/photo.jpg") != null);
}

const TestImageLookup = struct {
    /// Single-entry mock lookup: matches one URL → returns one byte slice.
    /// Lifetime of the returned bytes is the lifetime of this struct.
    url: []const u8,
    bytes: []const u8,
    /// T5: optional cell-row count reported for the matching URL.
    rows: ?u32 = null,

    fn get(ctx: *const anyopaque, url: []const u8) ?[]const u8 {
        const self: *const TestImageLookup = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, url, self.url)) return self.bytes;
        return null;
    }

    fn getRows(ctx: *const anyopaque, url: []const u8) ?u32 {
        const self: *const TestImageLookup = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, url, self.url)) return self.rows;
        return null;
    }

    fn lookup(self: *const TestImageLookup) ImageLookup {
        return .{ .ctx = self, .getFn = get, .rowsFn = getRows };
    }
};

test "render — image_lookup hit emits raw bytes and skips alt-ref" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><img alt=\"A photo\" src=\"/photo.jpg\"></body></html>");
    defer doc.deinit();

    // Sentinel byte sequence — easier to assert on than real Kitty APC.
    const sentinel = "<<IMAGE-BYTES-HERE>>";
    const tl = TestImageLookup{ .url = "/photo.jpg", .bytes = sentinel };

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, sentinel) != null);
    // Alt-ref must NOT appear when the lookup hit.
    try std.testing.expect(std.mem.indexOf(u8, out, "[A photo]") == null);
}

test "render — image_lookup miss falls back to alt-ref" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><img alt=\"A photo\" src=\"/photo.jpg\"></body></html>");
    defer doc.deinit();

    const tl = TestImageLookup{ .url = "/different.jpg", .bytes = "unused" };

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    const out = fbs.buffered();
    // Lookup miss → alt-ref text path engages, identical to no-lookup.
    try std.testing.expect(std.mem.indexOf(u8, out, "[A photo]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unused") == null);
}

test "render — no image_lookup keeps current alt-ref behavior verbatim" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><img alt=\"A photo\" src=\"/photo.jpg\"></body></html>");
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .none,
        // image_lookup explicitly omitted (null default).
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[A photo]") != null);
}

test "render browse — image line reserves its cell rows in the model" {
    // T5: a kitty image paints `rows` terminal rows but encodes to one
    // logical line. The browse model must reserve the remaining rows-1
    // lines so following content lays out below the image. Render the
    // same DOM with and without a row count and compare newline counts —
    // robust against unrelated spacing changes.
    const html = "<html><body><main><img alt=\"pic\" src=\"/photo.jpg\"><p>After</p></main></body></html>";
    const sentinel = "<<IMAGE-BYTES>>";

    var doc_base = try dom.parseDocument(std.testing.allocator, html);
    defer doc_base.deinit();
    const tl_base = TestImageLookup{ .url = "/photo.jpg", .bytes = sentinel };
    var model_base = try renderBrowseModel(std.testing.allocator, &doc_base, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl_base.lookup(),
    });
    defer model_base.deinit();

    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();
    const tl = TestImageLookup{ .url = "/photo.jpg", .bytes = sentinel, .rows = 4 };
    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    defer model.deinit();

    const base_nl = std.mem.count(u8, model_base.text, "\n");
    const reserved_nl = std.mem.count(u8, model.text, "\n");
    // rows=4 → 3 extra reserved lines beyond the image's own line.
    try std.testing.expectEqual(base_nl + 3, reserved_nl);
    // Following content still renders, below the reservation.
    const img_at = std.mem.indexOf(u8, model.text, sentinel).?;
    const after_at = std.mem.indexOf(u8, model.text, "After").?;
    try std.testing.expect(after_at > img_at);
}

test "render — default profile and braille do not reserve image rows" {
    // T5 skip paths: the streaming default profile relies on the terminal
    // cursor advancing as it paints (extra blanks would double the gap),
    // and braille bytes carry their own internal newlines.
    const html = "<html><body><img alt=\"pic\" src=\"/photo.jpg\"><p>After</p></body></html>";
    const sentinel = "<<IMAGE-BYTES>>";
    const tl = TestImageLookup{ .url = "/photo.jpg", .bytes = sentinel, .rows = 4 };
    const tl_base = TestImageLookup{ .url = "/photo.jpg", .bytes = sentinel };

    // Default (streaming) profile: rows present vs absent → identical output.
    inline for (.{ image_protocol.Protocol.kitty, image_protocol.Protocol.braille }) |proto| {
        var doc = try dom.parseDocument(std.testing.allocator, html);
        defer doc.deinit();
        var buf: [1024]u8 = undefined;
        var fbs = std.Io.Writer.fixed(&buf);
        try render(std.testing.allocator, &fbs, &doc, .{
            .ansi_colors = false,
            .show_images = true,
            .image_protocol = proto,
            .image_lookup = tl.lookup(),
        });

        var doc_base = try dom.parseDocument(std.testing.allocator, html);
        defer doc_base.deinit();
        var buf_base: [1024]u8 = undefined;
        var fbs_base = std.Io.Writer.fixed(&buf_base);
        try render(std.testing.allocator, &fbs_base, &doc_base, .{
            .ansi_colors = false,
            .show_images = true,
            .image_protocol = proto,
            .image_lookup = tl_base.lookup(),
        });

        try std.testing.expectEqualStrings(fbs_base.buffered(), fbs.buffered());
    }

    // Browse profile + braille: rows must NOT add lines either.
    var doc_br = try dom.parseDocument(std.testing.allocator, html);
    defer doc_br.deinit();
    var model_br = try renderBrowseModel(std.testing.allocator, &doc_br, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .braille,
        .image_lookup = tl.lookup(),
    });
    defer model_br.deinit();
    var doc_br_base = try dom.parseDocument(std.testing.allocator, html);
    defer doc_br_base.deinit();
    var model_br_base = try renderBrowseModel(std.testing.allocator, &doc_br_base, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .braille,
        .image_lookup = tl_base.lookup(),
    });
    defer model_br_base.deinit();
    try std.testing.expectEqual(
        std.mem.count(u8, model_br_base.text, "\n"),
        std.mem.count(u8, model_br.text, "\n"),
    );
}

test "render — <section style=background-image> emits bg bytes when lookup hits" {
    var doc = try dom.parseDocument(
        std.testing.allocator,
        "<html><body><section style=\"background-image: url('hero.jpg')\"><p>Hello</p></section></body></html>",
    );
    defer doc.deinit();

    const sentinel = "<<HERO-BG-BYTES>>";
    const tl = TestImageLookup{ .url = "hero.jpg", .bytes = sentinel };

    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, sentinel) != null);
    // Section's text content still renders normally after the bg emit.
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello") != null);
}

test "render — bg-image rejects gradients (no emit)" {
    var doc = try dom.parseDocument(
        std.testing.allocator,
        "<html><body><header style=\"background: linear-gradient(red, blue)\"><p>Banner</p></header></body></html>",
    );
    defer doc.deinit();

    const tl = TestImageLookup{ .url = "anything", .bytes = "<<SHOULD-NOT-APPEAR>>" };
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .show_images = true,
        .image_protocol = .kitty,
        .image_lookup = tl.lookup(),
    });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "<<SHOULD-NOT-APPEAR>>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Banner") != null);
}

test "extractBgUrlFromStyle: matches pipeline extractor output" {
    // Pipeline-side and renderer-side extractors must agree byte-for-
    // byte on the URL string they pull out of a given style value.
    // Spot-check a handful of common shapes.
    try std.testing.expectEqualStrings("hero.jpg", extractBgUrlFromStyle("background-image: url('hero.jpg')").?);
    try std.testing.expectEqualStrings("/cdn/x.png", extractBgUrlFromStyle("background: url(/cdn/x.png) center").?);
    try std.testing.expect(extractBgUrlFromStyle("background: linear-gradient(red, blue)") == null);
    try std.testing.expect(extractBgUrlFromStyle("background-color: red") == null);
}

test "render — word wrapping at max_width" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><p>Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu</p></body></html>");
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = false,
        .max_width = 20,
    });
    const out = fbs.buffered();
    // The text must be present in full.
    try std.testing.expect(std.mem.indexOf(u8, out, "Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mu") != null);
    // Verify that no single line exceeds max_width (ignoring the trailing newline).
    var line_it = std.mem.splitScalar(u8, out, '\n');
    while (line_it.next()) |line| {
        if (line.len > 0) {
            try std.testing.expect(line.len <= 20);
        }
    }
}

test "render — table with header and body" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table>
        \\  <tr><th>Name</th><th>Value</th></tr>
        \\  <tr><td>foo</td><td>bar</td></tr>
        \\</table></body></html>
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Value") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bar") != null);
}

test "render — HN-like table layout respects max width" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table><tr><td>
        \\  <table>
        \\    <tr><td><a href="https://example.com/1">Alpha story with a long title that should wrap cleanly inside the available width budget</a></td></tr>
        \\    <tr><td>42 points by alice 2 hours ago | <a href="item?id=1">12 comments</a></td></tr>
        \\    <tr><td><a href="https://example.com/2">Beta story with another long title that should stay discrete and readable in browse mode</a></td></tr>
        \\    <tr><td>21 points by bob 1 hour ago | <a href="item?id=2">8 comments</a></td></tr>
        \\  </table>
        \\</td></tr></table></body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 40,
    });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Alpha story") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "story") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "----------------------------------------") == null);
    try std.testing.expect(model.links.len >= 4);
    try std.testing.expectEqualStrings("https://example.com/1", model.links[0].href);

    for (model.lines) |line| {
        const text = model.text[line.start..line.end];
        // Allow up to 4 chars of footnote-ref overflow: refs like "[NN]" glue
        // to the preceding word and may push slightly past max_width.
        if (text.len > 0) try std.testing.expect(text.len <= 44);
    }
}

test "cssColorToAnsi — named, hex, and rgb mapping" {
    // Genuine chromatic colors keep their (bright) ANSI slot.
    try std.testing.expectEqual(@as(?u8, 31), cssColorToAnsi("red"));
    try std.testing.expectEqual(@as(?u8, 34), cssColorToAnsi("blue"));
    // Pure red hex maps to the exact bright-red slot (91).
    try std.testing.expectEqual(@as(?u8, 91), cssColorToAnsi("#ff0000"));
    try std.testing.expectEqual(@as(?u8, 32), cssColorToAnsi("rgb(0, 200, 0)"));
    // Unrecognised input yields null (no fg applied).
    try std.testing.expectEqual(@as(?u8, null), cssColorToAnsi("not-a-color"));
    try std.testing.expectEqual(@as(?u8, null), cssColorToAnsi(""));
    // Black foregrounds drop to the terminal default (invisible on dark terminals).
    try std.testing.expectEqual(@as(?u8, null), cssColorToAnsi("black"));
    try std.testing.expectEqual(@as(?u8, null), cssColorToAnsi("#000000"));
    try std.testing.expectEqual(@as(?u8, null), cssColorToAnsi("#111"));
}

test "cssColorToAnsi — mid-gray metadata maps to default fg, not a dark color" {
    // Regression: HN/YC metadata grays like #828282 = rgb(130,130,130) land on
    // the bright-black ANSI slot (90) via nearestAnsi16. Emitting raw 90 (or
    // black 30) is unreadable on a dark terminal, so readableFg resolves such
    // grays to the terminal default foreground (null) at normal intensity.
    inline for (.{ "#828282", "rgb(130,130,130)", "gray", "grey", "#888" }) |g| {
        try std.testing.expectEqual(@as(?u8, null), cssColorToAnsi(g));
    }
}

test "isBoldWeight + containsWord helpers" {
    try std.testing.expect(isBoldWeight("bold"));
    try std.testing.expect(isBoldWeight("700"));
    try std.testing.expect(!isBoldWeight("400"));
    try std.testing.expect(!isBoldWeight("normal"));
    try std.testing.expect(containsWord("underline dotted", "underline"));
    try std.testing.expect(containsWord("none", "none"));
    try std.testing.expect(!containsWord("underline", "line-through"));
}

test "render — author CSS emits ANSI color/weight and restores nested frame" {
    // Author stylesheets reach the renderer via `opts.css_stylesheets`
    // (page.zig extracts <style>/<link> into this); render() does not parse
    // inline <style> itself.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><p class="d">red <a href="https://e.com">link</a> tail</p></body></html>
    );
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = true,
        .css_stylesheets = &.{".d{color:red;font-weight:bold} a{color:blue}"},
    });
    const out = fbs.buffered();
    // Bold (1) + red (31) frame for the paragraph.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0;1;31m") != null);
    // The link layers underline (4) + blue (34) on top of the inherited bold.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0;1;4;34m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "tail") != null);
}

test "render — exact descendant selector styles only the descendant (Slice 3)" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><div class="box"><p>x</p></div><p>y</p></body></html>
    );
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{
        .ansi_colors = true,
        .css_stylesheets = &.{".box p { color: red; }"},
    });
    const out = fbs.buffered();
    // Exactly one element is reddened — the <p> inside .box. The flat OR
    // approximation would have matched both paragraphs (count == 2).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[0;31m"));
}

test "render — UA semantic tags and text-transform under ANSI" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><p><del>x</del><mark>y</mark>
        \\<span style="text-transform:uppercase">go</span></p></body></html>
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = true });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0;9m") != null); // del → strike
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0;7m") != null); // mark → reverse
    try std.testing.expect(std.mem.indexOf(u8, out, "GO") != null); // uppercase transform
}

test "render — text-align center/right pad single-line blocks (TUI only)" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\<p style="text-align:right">RIGHTX</p>
        \\<p style="text-align:center">CENTERX</p>
        \\</body></html>
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = true, .max_width = 30 });
    const out = fbs.buffered();
    // Right: 30 - 6 = 24 leading spaces before RIGHTX.
    try std.testing.expect(std.mem.indexOf(u8, out, "                        RIGHTX") != null);
    // Center: (30 - 7)/2 = 11 leading spaces before CENTERX.
    try std.testing.expect(std.mem.indexOf(u8, out, "           CENTERX") != null);
}

test "render — text-align is suppressed on the agent surface (ansi off)" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><p style="text-align:center">X</p></body></html>
    );
    defer doc.deinit();
    var buf: [1024]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false, .max_width = 30 });
    const out = fbs.buffered();
    // No leading alignment padding when colors are off.
    try std.testing.expect(std.mem.indexOf(u8, out, "          X") == null);
}

test "render — CSS styling leaves the agent surface escape-free" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><head><style>.d{color:red;font-weight:bold}</style></head><body>
        \\<p class="d">red</p>
        \\<span style="text-transform:uppercase">stays lower</span>
        \\</body></html>
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    // No escapes and no visual text-transform on the non-TUI surface.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "stays lower") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "STAYS LOWER") == null);
}

test "render — complex document with mixed elements" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <h1>Title</h1>
        \\  <p>First paragraph with <a href="/link">a link</a>.</p>
        \\  <ul>
        \\    <li>Item one</li>
        \\    <li>Item two</li>
        \\  </ul>
        \\  <p>Second paragraph.</p>
        \\</body></html>
    );
    defer doc.deinit();
    var buf: [8192]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "First paragraph") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "a link") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Item one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Item two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Second paragraph.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "References:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/link") != null);
}

test "isBlankRender treats whitespace + omitted-region placeholders as blank" {
    try std.testing.expect(isBlankRender(""));
    try std.testing.expect(isBlankRender("   \n\n  "));
    try std.testing.expect(isBlankRender("\n[Header omitted]\n[Sidebar omitted]\n"));
    try std.testing.expect(!isBlankRender("\n[Header omitted]\nReal content here\n"));
    try std.testing.expect(!isBlankRender("Visible"));
    // Unterminated bracket is treated as blank (no closing ']'): nothing visible.
    try std.testing.expect(isBlankRender("   ["));
}

test "browse render rescues content hidden only by the [hidden] reset" {
    // A Next.js-style shell: the whole body streams into a `<div hidden>` and a
    // Tailwind/normalize reset hides `[hidden]`. Honoring it blanks the page, so
    // the rescue pass must surface the streamed content.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\<div hidden id="S:0"><main><h1>Model Catalog</h1><p>Eight models available for deployment right now.</p></main></div>
        \\</body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .css_stylesheets = &.{"[hidden]:where(:not([hidden=until-found])){display:none}"},
    });
    defer model.deinit();
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Model Catalog") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Eight models") != null);
}

test "browse render keeps [hidden] chrome hidden when the body is visible" {
    // Mirror Wikipedia: visible article body plus small `[hidden]` chrome. The
    // normal pass is non-blank, so the rescue never fires and the chrome that
    // `[hidden]` legitimately hides stays hidden.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><main>
        \\<p hidden>Skip to navigation shortcut that real users never see.</p>
        \\<h1>Octopus</h1>
        \\<p>An octopus is a soft-bodied eight-limbed mollusc of the order Octopoda.</p>
        \\</main></body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .css_stylesheets = &.{"[hidden]{display:none}"},
    });
    defer model.deinit();
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Octopus") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "soft-bodied") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Skip to navigation") == null);
}

test "browse render still honors explicit display:none inside rescued content" {
    // Even on the rescue pass, an explicit author `display:none` (not the
    // generic `[hidden]` reset) must keep hiding its target.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\<div hidden><main><p>Streamed body content that should appear.</p>
        \\<p class="ad" style="display:none">tracking pixel junk</p></main></div>
        \\</body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .css_stylesheets = &.{"[hidden]{display:none}"},
    });
    defer model.deinit();
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Streamed body content") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "tracking pixel junk") == null);
}

test "renderModel captures lines and interactive links" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><p>Hello <a href=\"/next\">next page</a></p></body></html>");
    defer doc.deinit();

    var model = try renderModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(model.lines.len > 0);
    try std.testing.expect(model.links.len == 1);
    try std.testing.expect(std.mem.indexOf(u8, model.lineText(0), "Hello") != null);
    try std.testing.expectEqualStrings("/next", model.links[0].href);
    try std.testing.expectEqualStrings("next page", model.links[0].text);
}

test "render browse profile applies starter CSSOM display and visibility" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><head><style>.hide-me { display: none; } #ghost { visibility: hidden; }</style></head><body><main><p>Visible</p><p class=\"hide-me\">Hidden by class</p><p id=\"ghost\">Hidden by id</p><p style=\"display: none\">Hidden inline</p></main></body></html>");
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .css_stylesheets = &.{".hide-me { display: none; } #ghost { visibility: hidden; }"},
    });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Visible") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Hidden by class") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Hidden by id") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Hidden inline") == null);
}

test "render preserves whitespace under CSS white-space: pre / pre-wrap / pre-line" {
    // Three lines, each with multiple spaces and newlines that the default
    // wrap-and-collapse path would flatten. CSSOM §4.6.3 keeps them intact.
    var doc = try dom.parseDocument(std.testing.allocator, "<html><head><style>.pre-class { white-space: pre-wrap; }</style></head>" ++
        "<body><main>" ++
        "<div class=\"pre-class\">stylesheet  preserves\nnewline</div>" ++
        "<div style=\"white-space: pre\">inline  preserves\nnewline</div>" ++
        "<div>collapsed   single   line</div>" ++
        "</main></body></html>");
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .css_stylesheets = &.{".pre-class { white-space: pre-wrap; }"},
    });
    defer model.deinit();

    // Author stylesheet path: double-space + newline survive.
    try std.testing.expect(std.mem.indexOf(u8, model.text, "stylesheet  preserves") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "stylesheet  preserves\nnewline") != null);
    // Inline style path: same.
    try std.testing.expect(std.mem.indexOf(u8, model.text, "inline  preserves") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "inline  preserves\nnewline") != null);
    // Default (no white-space rule): collapsed to single spaces.
    try std.testing.expect(std.mem.indexOf(u8, model.text, "collapsed single line") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "collapsed   single") == null);
}

test "render browse profile omits references but keeps interactive links" {
    var doc = try dom.parseDocument(std.testing.allocator, "<html><body><main><p>Hello <a href=\"/next\">next page</a>.</p></main></body></html>");
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false, .show_links = true });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "References:") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "[1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "next page") != null);
    try std.testing.expectEqual(@as(usize, 1), model.links.len);
    try std.testing.expectEqualStrings("/next", model.links[0].href);
}

test "render browse profile favors main and suppresses nav boilerplate" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <header><p>Site title</p></header>
        \\  <nav><a href="/a">Home</a><a href="/b">Docs</a></nav>
        \\  <main><section><h1>Article title</h1><p>Primary body content. With punctuation.</p></section></main>
        \\  <footer><p>Copyright</p></footer>
        \\</body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Article title") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Primary body content") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Home") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Copyright") == null);
}

test "render browse profile collapses boilerplate aside inside content root" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body>
        \\  <main>
        \\    <article>
        \\      <p>Story body. Enough text to keep reading.</p>
        \\      <aside class="related-links"><a href="/one">One</a><a href="/two">Two</a></aside>
        \\    </article>
        \\  </main>
        \\</body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Story body") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "[Sidebar omitted]") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "One") == null);
}

test "render browse profile suppresses boilerplate section inside content root" {
    var doc = try dom.parseDocument(
        std.testing.allocator,
        "<html><body><main><article><h1>Story</h1><p>Real article copy with enough text to win.</p><section class=\"related newsletter\"><a href=\"/one\">Read more</a><a href=\"/two\">Subscribe</a></section></article></main></body></html>",
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{ .ansi_colors = false });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "Story") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Read more") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Subscribe") == null);
}

test "render §2.4 — no-th table linearizes cells in DOM order" {
    // Layout table (no <th>): cells must appear left-to-right in DOM order
    // on each row, separated by spaces, one row per line. No column alignment
    // chars (dashes) and no positional gaps.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table>
        \\  <tr><td>1.</td><td><a href="/s/1">Story Title One</a></td><td>(example.com)</td></tr>
        \\  <tr><td>10 points by alice 1 hour ago</td><td><a href="/c/1">5 comments</a></td></tr>
        \\</table></body></html>
    );
    defer doc.deinit();
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false, .show_links = true });
    const out = fbs.buffered();
    // Rank, title, domain must all appear — in order — without separating dashes.
    try std.testing.expect(std.mem.indexOf(u8, out, "Story Title One") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "10 points") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "----") == null);
    // The first cell ("1.") must appear before the title on its line.
    const rank_pos = std.mem.indexOf(u8, out, "1.") orelse 0;
    const title_pos = std.mem.indexOf(u8, out, "Story Title One") orelse 0;
    try std.testing.expect(rank_pos < title_pos);
}

test "render §2.4 — th table keeps columnar layout" {
    // Data table (has <th>): MUST continue to render with column separators.
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table>
        \\  <tr><th>Name</th><th>Score</th></tr>
        \\  <tr><td>Alice</td><td>42</td></tr>
        \\</table></body></html>
    );
    defer doc.deinit();
    var buf: [2048]u8 = undefined;
    var fbs = std.Io.Writer.fixed(&buf);
    try render(std.testing.allocator, &fbs, &doc, .{ .ansi_colors = false });
    const out = fbs.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "---") != null); // data table keeps separators
}

test "render - link-list table omits row separators" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table>
        \\  <tr><td><table>
        \\    <tr><td><a href="https://example.com/1">Alpha story with a long title that should wrap cleanly</a></td></tr>
        \\    <tr><td>42 points by alice 2 hours ago | <a href="item?id=1">12 comments</a></td></tr>
        \\  </table></td></tr>
        \\  <tr><td><table>
        \\    <tr><td><a href="https://example.com/2">Beta story with a long title that should stay discrete and readable</a></td></tr>
        \\    <tr><td>21 points by bob 1 hour ago | <a href="item?id=2">8 comments</a></td></tr>
        \\  </table></td></tr>
        \\</table></body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 40,
    });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "----") == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Alpha story") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Beta story") != null);

    for (model.lines) |line| {
        const text = model.text[line.start..line.end];
        // Footnote refs are width-reserved during flow, so no line overflows
        // max_width — the terminal can't hard-wrap a link's "[N]" mid-word.
        if (text.len > 0) try std.testing.expect(text.len <= 40);
    }
}

test "render - regular table keeps row separators" {
    var doc = try dom.parseDocument(std.testing.allocator,
        \\<html><body><table>
        \\  <tr><th>Name</th><th>Description</th></tr>
        \\  <tr><td>Alice</td><td>Works on compilers.</td></tr>
        \\  <tr><td>Bob</td><td>Works on networks.</td></tr>
        \\</table></body></html>
    );
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 60,
    });
    defer model.deinit();

    try std.testing.expect(std.mem.indexOf(u8, model.text, "---") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Bob") != null);
}

test "T2.4: pre/code line numbers appear when block exceeds threshold" {
    const html =
        \\<html><body><pre><code>line 1
        \\line 2
        \\line 3
        \\line 4
        \\line 5
        \\line 6
        \\</code></pre></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    // 6-line block with threshold=5: line numbers should appear.
    var with_nums = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 60,
        .code_line_numbers = 5,
    });
    defer with_nums.deinit();
    try std.testing.expect(std.mem.indexOf(u8, with_nums.text, "1 \u{2502}") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_nums.text, "6 \u{2502}") != null);

    // Same block but threshold=10: no line numbers.
    var without_nums = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 60,
        .code_line_numbers = 10,
    });
    defer without_nums.deinit();
    try std.testing.expect(std.mem.indexOf(u8, without_nums.text, "\u{2502}") == null);
}

test "T2.5: detectLanguage parses language-XYZ class tokens" {
    // We test detectLanguage indirectly via the DOM: create a minimal
    // document with a <code class="language-XYZ"> element and verify
    // that the rendered output contains BOLD escape sequences for
    // language-specific keywords.
    const cases = [_]struct { lang_cls: []const u8, code: []const u8, keyword: []const u8 }{
        .{ .lang_cls = "language-zig", .code = "const x = 1;", .keyword = "const" },
        .{ .lang_cls = "language-rust", .code = "fn main() {}", .keyword = "fn" },
        .{ .lang_cls = "language-javascript", .code = "const a = 1;", .keyword = "const" },
        .{ .lang_cls = "language-python", .code = "def foo(): pass", .keyword = "def" },
    };
    for (cases) |c| {
        // Build HTML with 6+ lines so the line-number gutter fires.
        var buf: [512]u8 = undefined;
        const html = try std.fmt.bufPrint(
            &buf,
            "<html><body><pre><code class=\"{s}\">{s}\na\nb\nc\nd\ne\n</code></pre></body></html>",
            .{ c.lang_cls, c.code },
        );
        var doc = try dom.parseDocument(std.testing.allocator, html);
        defer doc.deinit();

        var model = try renderBrowseModel(std.testing.allocator, &doc, .{
            .ansi_colors = true,
            .code_line_numbers = 5,
            .code_style = .auto,
        });
        defer model.deinit();

        // The rendered output should contain BOLD + keyword + RESET.
        const bold_kw = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{s}{s}",
            .{ BOLD, c.keyword, RESET },
        );
        defer std.testing.allocator.free(bold_kw);
        try std.testing.expect(std.mem.indexOf(u8, model.text, bold_kw) != null);
    }
}

test "T2.5: writeHighlightedLine — comments dim, strings green, numbers yellow" {
    const alloc = std.testing.allocator;

    // Each sub-case gets its own list so clearing is simple.
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        var bw = BufferWriter{ .allocator = alloc, .list = &list };
        try writeHighlightedLine(&bw, "x := 1; // comment here", .zig, true);
        try std.testing.expect(std.mem.indexOf(u8, list.items, DIM) != null);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "comment here") != null);
    }
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        var bw = BufferWriter{ .allocator = alloc, .list = &list };
        try writeHighlightedLine(&bw, "s := \"hello\";", .zig, true);
        try std.testing.expect(std.mem.indexOf(u8, list.items, GREEN) != null);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "\"hello\"") != null);
    }
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        var bw = BufferWriter{ .allocator = alloc, .list = &list };
        try writeHighlightedLine(&bw, "x := 42;", .zig, true);
        try std.testing.expect(std.mem.indexOf(u8, list.items, YELLOW) != null);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "42") != null);
    }
    {
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(alloc);
        var bw = BufferWriter{ .allocator = alloc, .list = &list };
        try writeHighlightedLine(&bw, "const x = 1;", .zig, false);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "\x1b[") == null);
        try std.testing.expect(std.mem.indexOf(u8, list.items, "const") != null);
    }
}

test "T2.6: diff blocks auto-detected and colored" {
    const diff_html =
        \\<html><body><pre>--- a/foo.zig
        \\+++ b/foo.zig
        \\@@ -1,3 +1,4 @@
        \\ unchanged line
        \\-removed line
        \\+added line
        \\+another addition
        \\ context
        \\</pre></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, diff_html);
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
        .max_width = 80,
    });
    defer model.deinit();

    // File header lines are bold.
    try std.testing.expect(std.mem.indexOf(u8, model.text, BOLD) != null);
    // Additions are green.
    try std.testing.expect(std.mem.indexOf(u8, model.text, GREEN) != null);
    // Deletions are red.
    try std.testing.expect(std.mem.indexOf(u8, model.text, RED) != null);
    // Content preserved.
    try std.testing.expect(std.mem.indexOf(u8, model.text, "added line") != null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "removed line") != null);
}

test "T2.6: non-diff pre blocks are not colored as diffs" {
    const non_diff_html =
        \\<html><body><pre>Hello world
        \\This is plain text.
        \\No diff markers here.
        \\</pre></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, non_diff_html);
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
    });
    defer model.deinit();

    // No RED escape should appear — this is not a diff.
    try std.testing.expect(std.mem.indexOf(u8, model.text, RED) == null);
    try std.testing.expect(std.mem.indexOf(u8, model.text, "Hello world") != null);
}

test "T2.7: sticky_headers populated for table with th header row" {
    const html =
        \\<html><body><table>
        \\  <tr><th>Name</th><th>Value</th></tr>
        \\  <tr><td>Alice</td><td>42</td></tr>
        \\  <tr><td>Bob</td><td>99</td></tr>
        \\  <tr><td>Carol</td><td>7</td></tr>
        \\</table></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
        .max_width = 40,
    });
    defer model.deinit();

    // Table has 4 rows (1 header + 3 body) → one sticky header entry.
    try std.testing.expectEqual(@as(usize, 1), model.sticky_headers.len);
    const sh = model.sticky_headers[0];
    // header_line_start < header_line_end < table_line_end
    try std.testing.expect(sh.header_line_start < sh.header_line_end);
    try std.testing.expect(sh.header_line_end < sh.table_line_end);
    // Header row text should contain the column names.
    const header_text = model.lineText(sh.header_line_start);
    try std.testing.expect(std.mem.indexOf(u8, header_text, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, header_text, "Value") != null);
}

test "T2.7: no sticky_headers for table without th cells" {
    const html =
        \\<html><body><table>
        \\  <tr><td>A</td><td>B</td></tr>
        \\  <tr><td>C</td><td>D</td></tr>
        \\</table></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    var model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = false,
    });
    defer model.deinit();

    try std.testing.expectEqual(@as(usize, 0), model.sticky_headers.len);
}

test "T2.8: uniform focus highlight — button and select show REVERSE when focused" {
    const html =
        \\<html><body><form>
        \\  <select name="c"><option>opt1</option></select>
        \\  <button type="button">Click me</button>
        \\  <input type="submit" value="Go">
        \\</form></body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    // First get the model without focus to find element pointers.
    var unfocused = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
    });
    defer unfocused.deinit();

    // No REVERSE in unfocused output for these controls.
    // (Existing test coverage for input/textarea focus already handles those.)
    try std.testing.expect(unfocused.fields.len >= 3);

    // Focus the select control (field 0) and verify REVERSE appears.
    const select_ptr = unfocused.fields[0].element_ptr;
    var focused_model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
        .focused_element_ptr = select_ptr,
    });
    defer focused_model.deinit();
    try std.testing.expect(std.mem.indexOf(u8, focused_model.text, REVERSE) != null);
}

test "T2.8: focused link shows REVERSE when focused" {
    const html =
        \\<html><body>
        \\  <a href="https://example.com">Click me</a>
        \\</body></html>
    ;
    var doc = try dom.parseDocument(std.testing.allocator, html);
    defer doc.deinit();

    // First get the model without focus to find element pointers.
    var unfocused = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
        .show_links = true,
    });
    defer unfocused.deinit();

    try std.testing.expect(unfocused.links.len >= 1);
    const link_ptr = unfocused.links[0].element_ptr;

    // Focus the link and verify REVERSE appears.
    var focused_model = try renderBrowseModel(std.testing.allocator, &doc, .{
        .ansi_colors = true,
        .show_links = true,
        .focused_element_ptr = link_ptr,
    });
    defer focused_model.deinit();
    try std.testing.expect(std.mem.indexOf(u8, focused_model.text, REVERSE) != null);
}
