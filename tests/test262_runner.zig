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
    .{
        .name = "promise.allSettled resolves with status entries",
        .source =
            \\globalThis.__test_result__ = 'pending';
            \\Promise.allSettled([Promise.resolve(1), Promise.reject('e'), Promise.resolve(3)]).then(results => {
            \\  globalThis.__test_result__ = results.map(r => r.status + ':' + (r.value ?? r.reason)).join(',');
            \\});
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "fulfilled:1,rejected:e,fulfilled:3",
        .drain_microtasks = true,
    },
    .{
        .name = "promise.race resolves with the first settled value",
        .source =
            \\globalThis.__test_result__ = 'pending';
            \\Promise.race([Promise.resolve(7), Promise.resolve(8)]).then(v => {
            \\  globalThis.__test_result__ = String(v);
            \\});
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "7",
        .drain_microtasks = true,
    },
    .{
        .name = "queueMicrotask runs after current task and before timers",
        .source =
            \\const order = [];
            \\queueMicrotask(() => { order.push('mt'); globalThis.__test_result__ = order.join(','); });
            \\order.push('sync');
            \\globalThis.__test_result__ = order.join(',');
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "sync,mt",
        .drain_microtasks = true,
    },
    .{
        .name = "Array.from converts iterables and applies the map fn",
        .source =
            \\const set = new Set([1, 2, 3]);
            \\globalThis.__test_result__ = Array.from(set, x => x * 2).join(',');
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "2,4,6",
    },
    .{
        .name = "Array.of and Array.prototype.flatMap",
        .source =
            \\const a = Array.of(1, 2, 3);
            \\globalThis.__test_result__ = a.flatMap(x => [x, x * 10]).join(',');
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "1,10,2,20,3,30",
    },
    .{
        .name = "String.prototype.replaceAll",
        .source =
            \\globalThis.__test_result__ = 'a-b-c-d'.replaceAll('-', '/');
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "a/b/c/d",
    },
    .{
        .name = "structuredClone deep-copies plain objects",
        .source =
            \\const original = { a: 1, nested: { b: [2, 3] } };
            \\const copy = structuredClone(original);
            \\copy.nested.b.push(4);
            \\globalThis.__test_result__ = original.nested.b.length + ':' + copy.nested.b.length;
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "2:3",
    },
    .{
        .name = "JSON.stringify normalizes NaN and Infinity to null",
        .source =
            \\globalThis.__test_result__ = JSON.stringify({a: NaN, b: Infinity, c: -Infinity, d: 1});
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "{\"a\":null,\"b\":null,\"c\":null,\"d\":1}",
    },
    .{
        .name = "JSON.stringify replacer function filters keys",
        .source =
            \\const replacer = (key, value) => key === 'secret' ? undefined : value;
            \\globalThis.__test_result__ = JSON.stringify({ name: 'awr', secret: 'hidden', n: 42 }, replacer);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "{\"name\":\"awr\",\"n\":42}",
    },
    .{
        .name = "JSON.stringify with indent emits pretty-printed output",
        .source =
            \\globalThis.__test_result__ = JSON.stringify({a:1, b:[2]}, null, 2);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "{\n  \"a\": 1,\n  \"b\": [\n    2\n  ]\n}",
    },
    .{
        .name = "Map iteration preserves insertion order",
        .source =
            \\const m = new Map([['a',1],['b',2],['c',3]]);
            \\const out = [];
            \\for (const [k,v] of m) out.push(k+':'+v);
            \\globalThis.__test_result__ = out.join(',');
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "a:1,b:2,c:3",
    },
    .{
        .name = "Array.from collects values from a generator",
        .source =
            \\function* gen() { yield 'x'; yield 'y'; yield 'z'; }
            \\globalThis.__test_result__ = Array.from(gen()).join(',');
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "x,y,z",
    },
    .{
        .name = "spread expands a Set into an array",
        .source =
            \\globalThis.__test_result__ = [...new Set([3,1,4,1,5,9,2,6,5,3,5])].sort((a,b)=>a-b).join(',');
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "1,2,3,4,5,6,9",
    },
    .{
        .name = "String.prototype.at supports negative indexing",
        .source =
            \\globalThis.__test_result__ = 'hello'.at(-1) + 'world'.at(0) + 'awr'.at(-2);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "oww",
    },
    .{
        .name = "Number.isInteger and Number.isFinite predicates",
        .source =
            \\globalThis.__test_result__ = [Number.isInteger(1), Number.isInteger(1.5), Number.isFinite(Infinity), Number.isFinite(0)].join(',');
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "true,false,false,true",
    },
    .{
        .name = "Math.hypot for 3-4-5 right triangle",
        .source =
            \\globalThis.__test_result__ = Math.hypot(3, 4);
        ,
        .probe = "String(globalThis.__test_result__)",
        .expected = "5",
    },
    .{
        .name = "Object.hasOwn (ES2022)",
        .source =
            \\globalThis.__test_result__ = [
            \\  Object.hasOwn({a:1}, 'a'),
            \\  Object.hasOwn({a:1}, 'b'),
            \\  Object.hasOwn(Object.create({inherited: 1}), 'inherited'),
            \\].join(',');
        ,
        .probe = "globalThis.__test_result__",
        .expected = "true,false,false",
    },
    .{
        .name = "Array.prototype.at handles negative indexes (ES2022)",
        .source =
            \\globalThis.__test_result__ = [10,20,30,40,50].at(-1) + ',' +
            \\  [10,20,30,40,50].at(-2) + ',' +
            \\  [10,20,30,40,50].at(0) + ',' +
            \\  [10,20,30,40,50].at(99);
        ,
        .probe = "globalThis.__test_result__",
        .expected = "50,40,10,undefined",
    },
    .{
        .name = "Array.prototype.findLast and findLastIndex (ES2023)",
        .source =
            \\const arr = [1, 2, 3, 4, 5];
            \\globalThis.__test_result__ =
            \\  arr.findLast(n => n < 4) + ',' +
            \\  arr.findLastIndex(n => n < 4) + ',' +
            \\  arr.findLast(n => n > 99) + ',' +
            \\  arr.findLastIndex(n => n > 99);
        ,
        .probe = "globalThis.__test_result__",
        .expected = "3,2,undefined,-1",
    },
    .{
        .name = "Promise.allSettled returns all outcomes",
        .source =
            \\Promise.allSettled([
            \\  Promise.resolve(1),
            \\  Promise.reject('boom'),
            \\  Promise.resolve(3),
            \\]).then(rs => {
            \\  globalThis.__test_result__ =
            \\    rs[0].status + ':' + rs[0].value + '|' +
            \\    rs[1].status + ':' + rs[1].reason + '|' +
            \\    rs[2].status + ':' + rs[2].value;
            \\});
        ,
        .drain_microtasks = true,
        .probe = "globalThis.__test_result__",
        .expected = "fulfilled:1|rejected:boom|fulfilled:3",
    },
    .{
        .name = "Promise.any resolves with first fulfilled",
        .source =
            \\Promise.any([
            \\  Promise.reject('a'),
            \\  Promise.resolve('b'),
            \\  Promise.reject('c'),
            \\]).then(v => { globalThis.__test_result__ = String(v); });
        ,
        .drain_microtasks = true,
        .probe = "globalThis.__test_result__",
        .expected = "b",
    },
    .{
        .name = "optional chaining (?.) short-circuits on null",
        .source =
            \\const obj = { a: { b: 42 } };
            \\globalThis.__test_result__ =
            \\  String(obj?.a?.b) + ',' +
            \\  String(obj?.x?.y) + ',' +
            \\  String(obj?.a?.b?.toString()) + ',' +
            \\  String(null?.anything);
        ,
        .probe = "globalThis.__test_result__",
        .expected = "42,undefined,42,undefined",
    },
    .{
        .name = "nullish coalescing (??) treats null/undefined only",
        .source =
            \\globalThis.__test_result__ = [
            \\  (null ?? 'A'),
            \\  (undefined ?? 'B'),
            \\  ('' ?? 'C'),
            \\  (0 ?? 'D'),
            \\  (false ?? 'E'),
            \\].join(',');
        ,
        .probe = "globalThis.__test_result__",
        .expected = "A,B,,0,false",
    },
    .{
        .name = "logical assignment operators (||= ??= &&=)",
        .source =
            \\let a = null; a ??= 'a';
            \\let b = 0;    b ||= 'b';
            \\let c = 1;    c &&= 'c';
            \\globalThis.__test_result__ = a + ',' + b + ',' + c;
        ,
        .probe = "globalThis.__test_result__",
        .expected = "a,b,c",
    },
    .{
        .name = "String.prototype.matchAll yields named groups",
        .source =
            \\const matches = [...'abc abd abe'.matchAll(/ab(?<x>\w)/g)];
            \\globalThis.__test_result__ =
            \\  matches.map(m => m.groups.x).join(',') + '|len=' + matches.length;
        ,
        .probe = "globalThis.__test_result__",
        .expected = "c,d,e|len=3",
    },
    .{
        .name = "Object.fromEntries inverts Object.entries",
        .source =
            \\const original = { x: 1, y: 2, z: 3 };
            \\const round = Object.fromEntries(Object.entries(original));
            \\globalThis.__test_result__ =
            \\  round.x + ',' + round.y + ',' + round.z + '|keys=' + Object.keys(round).length;
        ,
        .probe = "globalThis.__test_result__",
        .expected = "1,2,3|keys=3",
    },
    .{
        .name = "BigInt arithmetic and comparison",
        .source =
            \\const big = 9007199254740993n;
            \\globalThis.__test_result__ =
            \\  String(big) + ',' +
            \\  String(big + 1n) + ',' +
            \\  String(big > 9007199254740992n);
        ,
        .probe = "globalThis.__test_result__",
        .expected = "9007199254740993,9007199254740994,true",
    },
    .{
        .name = "for-of iterates a Map's [key,value] entries",
        .source =
            \\const m = new Map([['a', 1], ['b', 2], ['c', 3]]);
            \\const out = [];
            \\for (const [k, v] of m) out.push(k + ':' + v);
            \\globalThis.__test_result__ = out.join(',');
        ,
        .probe = "globalThis.__test_result__",
        .expected = "a:1,b:2,c:3",
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
