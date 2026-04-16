const std = @import("std");
const Step = std.Build.Step;

/// A note on my build.zig style: I try to create all the artifacts first,
/// unattached to any steps. At the end of the build() function, I create
/// steps or attach unattached artifacts to predefined steps such as
/// install. This means the only thing affecting the `zig build` user
/// interaction is at the end of the build() file and makes it easier
/// to reason about the structure.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("xev", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const emit_man = b.option(
        bool,
        "emit-man-pages",
        "Set to true to build man pages. Requires scdoc. Defaults to true if scdoc is found.",
    ) orelse if (b.findProgram(
        &[_][]const u8{"scdoc"},
        &[_][]const u8{},
    )) |_|
        true
    else |err| switch (err) {
        error.FileNotFound => false,
    };

    const emit_bench = b.option(
        bool,
        "emit-bench",
        "Install the benchmark binaries to zig-out",
    ) orelse false;

    const emit_examples = b.option(
        bool,
        "emit-example",
        "Install the example binaries to zig-out",
    ) orelse false;

    const c_api_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static C lib
    const static_lib: ?*Step.Compile = lib: {
        if (target.result.os.tag == .wasi) break :lib null;

        const static_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "xev",
            .root_module = c_api_module,
        });
        static_lib.root_module.link_libc = true;
        if (target.result.os.tag == .windows) {
            static_lib.root_module.linkSystemLibrary("ws2_32", .{});
            static_lib.root_module.linkSystemLibrary("mswsock", .{});
        }
        break :lib static_lib;
    };

    // Dynamic C lib
    const dynamic_lib: ?*Step.Compile = lib: {
        // We require native so we can link to libxml2
        if (!target.query.isNative()) break :lib null;

        const dynamic_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "xev",
            .root_module = c_api_module,
        });
        break :lib dynamic_lib;
    };

    // C Headers
    const c_header = b.addInstallFileWithDir(
        b.path("include/xev.h"),
        .header,
        "xev.h",
    );

    // pkg-config
    const pc: *Step.InstallFile = pc: {
        const file = b.addWriteFile("libxev.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: libxev
            \\URL: https://github.com/mitchellh/libxev
            \\Description: High-performance, cross-platform event loop
            \\Version: 0.1.0
            \\Cflags: -I${{includedir}}
            \\Libs: -L${{libdir}} -lxev
        , .{b.install_prefix}));
        break :pc b.addInstallFileWithDir(
            file.getDirectory().path(b, "libxev.pc"),
            .prefix,
            "share/pkgconfig/libxev.pc",
        );
    };

    // Man pages
    const man = try manPages(b);

    // Benchmarks and examples
    const benchmarks = try buildBenchmarks(b, target);
    const examples = try buildExamples(b, target, optimize, static_lib);

    // Test Executable
    const test_exe: *Step.Compile = test_exe: {
        const test_filter = b.option(
            []const u8,
            "test-filter",
            "Filter for test",
        );
        const test_exe = b.addTest(.{
            .name = "xev-test",
            .filters = if (test_filter) |filter| &.{filter} else &.{},
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        switch (target.result.os.tag) {
            .linux, .macos => test_exe.root_module.link_libc = true,
            else => {},
        }
        break :test_exe test_exe;
    };

    // "test" Step
    {
        const tests_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }

    if (static_lib) |v| b.installArtifact(v);
    if (dynamic_lib) |v| b.installArtifact(v);
    b.getInstallStep().dependOn(&c_header.step);
    b.getInstallStep().dependOn(&pc.step);
    b.installArtifact(test_exe);
    if (emit_man) {
        for (man) |step| b.getInstallStep().dependOn(step);
    }
    if (emit_bench) for (benchmarks) |exe| {
        b.getInstallStep().dependOn(&b.addInstallArtifact(
            exe,
            .{ .dest_dir = .{ .override = .{
                .custom = "bin/bench",
            } } },
        ).step);
    };
    if (emit_examples) for (examples) |exe| {
        b.getInstallStep().dependOn(&b.addInstallArtifact(
            exe,
            .{ .dest_dir = .{ .override = .{
                .custom = "bin/example",
            } } },
        ).step);
    };
}

fn buildBenchmarks(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ![]const *Step.Compile {
    _ = b;
    _ = target;
    return &[_]*Step.Compile{};
}

fn buildExamples(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_lib_: ?*Step.Compile,
) ![]const *Step.Compile {
    _ = b;
    _ = target;
    _ = optimize;
    _ = c_lib_;
    return &[_]*Step.Compile{};
}

fn manPages(b: *std.Build) ![]const *Step {
    _ = b;
    return &[_]*Step{};
}
