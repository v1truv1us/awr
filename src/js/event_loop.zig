/// event_loop.zig — libxev-backed timer queue for the JsEngine.
///
/// Owns an `xev.Loop` and tracks pending `setTimeout`/`setInterval`
/// callbacks. The loop is driven by `Page.drainAll()` which alternates
/// microtask drains with `loop.run(.no_wait)` ticks until the queue
/// is empty.
///
/// Each `PendingTimer` holds a duped `qjs.Value` of the JS callback so
/// the callback cannot be garbage-collected before firing. The timer
/// entry is freed when the callback runs (one-shot) or when the caller
/// invokes `cancel` (clearTimeout/clearInterval). setInterval reuses
/// the entry by scheduling a fresh completion after each firing.
const std = @import("std");
const builtin = @import("builtin");
const xev_pkg = @import("xev");
const qjs = @import("quickjs");

// gVisor sandboxes (kernel 4.4.0) do not expose io_uring, which libxev would
// pick as its default Linux backend. Force epoll on Linux so the runtime works
// under gVisor; other platforms use the default backend.
pub const xev = if (builtin.os.tag == .linux) xev_pkg.Epoll else xev_pkg;

pub const PendingTimer = struct {
    id: u32,
    completion: xev.Completion = .{},
    cancel_completion: xev.Completion = .{},
    callback: qjs.Value,
    delay_ms: u64,
    repeating: bool,
    cancelled: bool = false,
    /// Set by `EventLoop.reset` when the owning JS context is torn down.
    /// `releaseEntry` skips `callback.deinit` for orphaned entries because
    /// the context that owns the Value is already gone.
    orphaned: bool = false,
    owner: *EventLoop,
};

pub const EventLoop = struct {
    allocator: std.mem.Allocator,
    loop: xev.Loop,
    ctx: *qjs.Context,
    timers: std.AutoHashMap(u32, *PendingTimer),
    /// Entries whose JS context has been torn down (via `reset`).  They stay
    /// alive until libxev fires their completion callback (marking them freed),
    /// or until `deinit` disposes of them directly.
    orphaned: std.ArrayListUnmanaged(*PendingTimer) = .empty,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, ctx: *qjs.Context) !EventLoop {
        const loop = try xev.Loop.init(.{});
        return EventLoop{
            .allocator = allocator,
            .loop = loop,
            .ctx = ctx,
            .timers = std.AutoHashMap(u32, *PendingTimer).init(allocator),
        };
    }

    pub fn deinit(self: *EventLoop) void {
        // Drop references to any pending callbacks so the context can GC them.
        var it = self.timers.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            entry.callback.deinit(self.ctx);
            self.allocator.destroy(entry);
        }
        self.timers.deinit();
        // Free any orphaned entries that did not fire before deinit was called.
        // Their JS context is already gone so we must not call callback.deinit.
        for (self.orphaned.items) |entry| {
            self.allocator.destroy(entry);
        }
        self.orphaned.deinit(self.allocator);
        self.loop.deinit();
    }

    /// Update the JS context pointer (call after JsEngine is re-initialised).
    /// Old timers are marked orphaned and moved to `self.orphaned` so they
    /// remain alive until libxev fires their completion callback (at which
    /// point `timerCallback` frees them without touching the old context).
    /// If `deinit` runs before a timer fires, `deinit` frees the entry directly.
    pub fn reset(self: *EventLoop, ctx: *qjs.Context) void {
        // Old timer entries must not be freed immediately — libxev still holds
        // a reference to their embedded `completion` struct and will invoke
        // `timerCallback` when the timer expires (or is processed).
        // Mark each entry cancelled + orphaned so timerCallback is a no-op
        // for the JS side, then track it in `orphaned` for safe cleanup.
        var it = self.timers.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            entry.cancelled = true;
            entry.orphaned = true;
            self.orphaned.append(self.allocator, entry) catch {
                // OOM: the entry will still be freed when timerCallback fires
                // naturally. If deinit runs before that happens, the entry will
                // be leaked. This is an extremely unlikely edge case.
            };
        }
        self.timers.clearRetainingCapacity();
        self.ctx = ctx;
        self.next_id = 1;
    }

    /// Schedule a new timer. Returns the timer id visible to JS.
    /// Takes ownership of the `callback` Value (the caller must have called
    /// `.dup(ctx)` before passing it in).
    pub fn schedule(
        self: *EventLoop,
        callback: qjs.Value,
        delay_ms: u64,
        repeating: bool,
    ) !u32 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;

        const entry = try self.allocator.create(PendingTimer);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .id = id,
            .callback = callback,
            .delay_ms = delay_ms,
            .repeating = repeating,
            .owner = self,
        };

        try self.timers.put(id, entry);

        const timer = try xev.Timer.init();
        timer.run(&self.loop, &entry.completion, delay_ms, PendingTimer, entry, timerCallback);
        return id;
    }

    /// Mark a timer cancelled. The entry stays in the map until its completion
    /// fires, at which point the callback is freed and the entry destroyed.
    pub fn cancel(self: *EventLoop, id: u32) void {
        const entry_ptr = self.timers.get(id) orelse return;
        entry_ptr.cancelled = true;
    }

    /// Returns true if there is at least one non-cancelled timer still
    /// pending in the queue.
    pub fn hasPending(self: *EventLoop) bool {
        var it = self.timers.valueIterator();
        while (it.next()) |entry_ptr| {
            if (!entry_ptr.*.cancelled) return true;
        }
        return false;
    }

    /// Tick the libxev loop without blocking. Fires any timers that have
    /// reached their expiry, which in turn calls their JS callbacks.
    pub fn tickNoWait(self: *EventLoop) !void {
        try self.loop.run(.no_wait);
    }

    /// Block until at least one timer fires (or the loop is otherwise
    /// active). Returns immediately if there is nothing to wait on.
    pub fn tickOnce(self: *EventLoop) !void {
        if (!self.hasPending()) return;
        try self.loop.run(.once);
    }
};

fn timerCallback(
    ud: ?*PendingTimer,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    const entry = ud orelse return .disarm;
    const self = entry.owner;

    _ = r catch {
        // Timer was cancelled via libxev (e.g. fired with error.Canceled);
        // free the entry regardless of orphaned state.
        releaseEntry(self, entry);
        return .disarm;
    };

    if (entry.cancelled) {
        releaseEntry(self, entry);
        return .disarm;
    }

    // Invoke the JS callback.
    const result = entry.callback.call(self.ctx, qjs.Value.undefined, &.{});
    result.deinit(self.ctx);

    if (entry.repeating and !entry.cancelled) {
        // Reschedule: reuse the completion with a fresh libxev timer request.
        const timer = xev.Timer.init() catch {
            releaseEntry(self, entry);
            return .disarm;
        };
        timer.run(&self.loop, &entry.completion, entry.delay_ms, PendingTimer, entry, timerCallback);
        return .disarm; // new request, not an in-place rearm
    }

    releaseEntry(self, entry);
    return .disarm;
}

fn releaseEntry(self: *EventLoop, entry: *PendingTimer) void {
    if (entry.orphaned) {
        // The JS context that owns the callback Value is gone; do NOT call
        // callback.deinit.  Remove from the orphaned tracking list (O(n),
        // but the list is typically very short).
        for (self.orphaned.items, 0..) |e, i| {
            if (e == entry) {
                _ = self.orphaned.swapRemove(i);
                break;
            }
        }
    } else {
        entry.callback.deinit(self.ctx);
        _ = self.timers.remove(entry.id);
    }
    self.allocator.destroy(entry);
}

test "EventLoop — setTimeout fires after tick" {
    const qjs_local = @import("quickjs");
    const rt = try qjs_local.Runtime.init();
    defer rt.deinit();
    const ctx = try qjs_local.Context.init(rt);
    defer ctx.deinit();

    var el = try EventLoop.init(std.testing.allocator, ctx);
    defer el.deinit();

    // Register a JS global we can check, and a function that flips it.
    try std.testing.expect(!ctx.eval("var __fired = false;", "<t>", .{}).isException());
    const fn_val = ctx.eval("(function(){ __fired = true; })", "<t>", .{});
    defer fn_val.deinit(ctx);

    _ = try el.schedule(fn_val.dup(ctx), 1, false);

    // Before tick, still false.
    const before = ctx.eval("__fired", "<t>", .{});
    defer before.deinit(ctx);
    try std.testing.expect(!(before.toBool(ctx) catch false));

    try el.tickOnce();

    const after = ctx.eval("__fired", "<t>", .{});
    defer after.deinit(ctx);
    try std.testing.expect(after.toBool(ctx) catch false);
}

test "EventLoop — cancel prevents callback" {
    const qjs_local = @import("quickjs");
    const rt = try qjs_local.Runtime.init();
    defer rt.deinit();
    const ctx = try qjs_local.Context.init(rt);
    defer ctx.deinit();

    var el = try EventLoop.init(std.testing.allocator, ctx);
    defer el.deinit();

    _ = ctx.eval("var __n = 0;", "<t>", .{}).isException();
    const fn_val = ctx.eval("(function(){ __n++; })", "<t>", .{});
    defer fn_val.deinit(ctx);

    const id = try el.schedule(fn_val.dup(ctx), 1, false);
    el.cancel(id);

    try el.tickOnce();

    const n = ctx.eval("__n", "<t>", .{});
    defer n.deinit(ctx);
    try std.testing.expectEqual(@as(i32, 0), n.toInt32(ctx) catch -1);
}
