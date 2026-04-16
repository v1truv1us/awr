const std = @import("std");
const engine_mod = @import("engine");

const Case = struct {
    name: []const u8,
    source: []const u8,
    probe: []const u8,
    expected: []const u8,
    drain_microtasks: bool = false,
};

const curated_cases = [_]Case{
    .{
        .name = "let and const block scoping",
        .source =
            \\let x = 1;
            \\{
            \\  const x = 2;
            \\  globalThis.__test_result__ = x;
            \\}
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "2",
    },
    .{
        .name = "arrow functions capture lexical values",
        .source =
            \\const add = (a, b) => a + b;
            \\globalThis.__test_result__ = add(20, 22);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "42",
    },
    .{
        .name = "destructuring assignment",
        .source =
            \\const { a, b } = { a: 3, b: 4 };
            \\globalThis.__test_result__ = a * b;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "12",
    },
    .{
        .name = "template literals",
        .source =
            \\const name = 'AWR';
            \\globalThis.__test_result__ = `${name} runtime`;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "AWR runtime",
    },
    .{
        .name = "classes and methods",
        .source =
            \\class Counter {
            \\  constructor(v) { this.v = v; }
            \\  inc() { this.v += 1; return this.v; }
            \\}
            \\globalThis.__test_result__ = new Counter(4).inc();
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "5",
    },
    .{
        .name = "optional chaining and nullish coalescing",
        .source =
            \\const cfg = { nested: { value: 7 } };
            \\globalThis.__test_result__ = (cfg?.nested?.value ?? 0) + (cfg?.missing?.value ?? 1);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "8",
    },
    .{
        .name = "promise jobs resolve after draining",
        .source =
            \\globalThis.__test_result__ = 'pending';
            \\Promise.resolve(40).then(v => { globalThis.__test_result__ = String(v + 2); });
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "42",
        .drain_microtasks = true,
    },
};

fn runCase(allocator: std.mem.Allocator, case: Case) !void {
    var engine = try engine_mod.JsEngine.init(allocator, null);
    defer engine.deinit();

    try engine.eval(case.source, "<test262-subset>");
    if (case.drain_microtasks) engine.drainMicrotasks();

    const actual = try engine.evalString(case.probe);
    defer allocator.free(actual);

    try std.testing.expectEqualStrings(case.expected, actual);
}

test "curated Test262 subset passes" {
    for (curated_cases) |case| {
        try runCase(std.testing.allocator, case);
    }
}
