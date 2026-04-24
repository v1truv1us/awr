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
    .{
        .name = "spread and rest parameters",
        .source =
            \\function sum(...nums) { return nums.reduce((a, b) => a + b, 0); }
            \\const parts = [1, 2, 3, 4];
            \\globalThis.__test_result__ = sum(...parts);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "10",
    },
    .{
        .name = "for of iteration",
        .source =
            \\let total = 0;
            \\for (const value of [1, 2, 3]) total += value;
            \\globalThis.__test_result__ = total;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "6",
    },
    .{
        .name = "symbol basics",
        .source =
            \\const a = Symbol.for('awr');
            \\const b = Symbol.for('awr');
            \\globalThis.__test_result__ = a === b;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "true",
    },
    .{
        .name = "map and set basics",
        .source =
            \\const m = new Map();
            \\m.set('a', 4);
            \\const s = new Set([1, 2, 2]);
            \\globalThis.__test_result__ = m.get('a') + s.size;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "6",
    },
    .{
        .name = "proxy and reflect",
        .source =
            \\const target = { value: 1 };
            \\const proxy = new Proxy(target, { get(obj, key) { return Reflect.get(obj, key) * 2; } });
            \\globalThis.__test_result__ = proxy.value;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "2",
    },
    .{
        .name = "generators yield values",
        .source =
            \\function* make() { yield 1; yield 2; yield 3; }
            \\let total = 0;
            \\for (const value of make()) total += value;
            \\globalThis.__test_result__ = total;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "6",
    },
    .{
        .name = "async await resolves after draining",
        .source =
            \\globalThis.__test_result__ = 'pending';
            \\(async function() {
            \\  const value = await Promise.resolve(41);
            \\  globalThis.__test_result__ = String(value + 1);
            \\})();
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "42",
        .drain_microtasks = true,
    },
    .{
        .name = "promise all resolves after draining",
        .source =
            \\globalThis.__test_result__ = 'pending';
            \\Promise.all([Promise.resolve(1), Promise.resolve(2), Promise.resolve(3)]).then(values => {
            \\  globalThis.__test_result__ = String(values.reduce((a, b) => a + b, 0));
            \\});
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "6",
        .drain_microtasks = true,
    },
    .{
        .name = "object entries and fromEntries",
        .source =
            \\const roundTrip = Object.fromEntries(Object.entries({ a: 1, b: 2 }));
            \\globalThis.__test_result__ = JSON.stringify(roundTrip);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "{\"a\":1,\"b\":2}",
    },
    .{
        .name = "array helper methods",
        .source =
            \\const value = [1, [2, 3]].flat().find(x => x === 3) + (['a', 'b'].includes('b') ? 1 : 0);
            \\globalThis.__test_result__ = value;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "4",
    },
    .{
        .name = "string helper methods",
        .source =
            \\globalThis.__test_result__ = '7'.padStart(3, '0') + ':' + ('awr'.startsWith('a') && 'awr'.endsWith('r'));
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "007:true",
    },
    .{
        .name = "default parameters",
        .source =
            \\function make(a = 3, b = 4) { return a + b; }
            \\globalThis.__test_result__ = make(undefined, 5);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "8",
    },
    .{
        .name = "error subtype inheritance",
        .source =
            \\const err = new TypeError('boom');
            \\globalThis.__test_result__ = err instanceof TypeError && err instanceof Error;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "true",
    },
    .{
        .name = "date basics",
        .source =
            \\globalThis.__test_result__ = new Date('2020-01-02T03:04:05.000Z').toISOString();
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "2020-01-02T03:04:05.000Z",
    },
    .{
        .name = "typed arrays basics",
        .source =
            \\const bytes = new Uint8Array([1, 2, 3]);
            \\globalThis.__test_result__ = bytes[0] + bytes[1] + bytes[2];
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "6",
    },
    .{
        .name = "globalThis is wired",
        .source =
            \\globalThis.__test_result__ = typeof globalThis === 'object' && globalThis.Math === Math;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "true",
    },
    .{
        .name = "well known symbols",
        .source =
            \\globalThis.__test_result__ = typeof Array.prototype[Symbol.iterator] === 'function';
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "true",
    },
    .{
        .name = "bigint arithmetic",
        .source =
            \\globalThis.__test_result__ = String((2n ** 5n) + 1n);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "33",
    },
    .{
        .name = "logical assignment operators",
        .source =
            \\let a = null;
            \\let b = 0;
            \\let c = 1;
            \\a ??= 4;
            \\b ||= 5;
            \\c &&= 6;
            \\globalThis.__test_result__ = a + b + c;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "15",
    },
    .{
        .name = "regexp named capture groups",
        .source =
            \\const match = /(?<year>\d{4})-(?<month>\d{2})/.exec('2026-04');
            \\globalThis.__test_result__ = match.groups.year + '-' + match.groups.month;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "2026-04",
    },
    .{
        .name = "json reviver",
        .source =
            \\const value = JSON.parse('{"a":1}', (key, inner) => key === 'a' ? inner + 1 : inner);
            \\globalThis.__test_result__ = value.a;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "2",
    },
    .{
        .name = "math helpers",
        .source =
            \\globalThis.__test_result__ = Math.imul(2, 3) + Math.trunc(4.8) + Math.clz32(1);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "41",
    },
    .{
        .name = "weakmap and weakset",
        .source =
            \\const obj = {};
            \\const wm = new WeakMap([[obj, 5]]);
            \\const ws = new WeakSet([obj]);
            \\globalThis.__test_result__ = wm.get(obj) + (ws.has(obj) ? 1 : 0);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "6",
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
