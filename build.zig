const std = @import("std");
const fs = std.fs;
const builtin = @import("builtin");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const tracy = b.option(
        []const u8,
        "tracy",
        "Enable Tracy integration. Supply path to Tracy source",
    );
    const tracy_callstack = b.option(
        bool,
        "tracy-callstack",
        "Include callstack information with Tracy data. Does nothing if -Dtracy is not provided",
    ) orelse false;
    const tracy_allocation = b.option(
        bool,
        "tracy-allocation",
        "Include allocation information with Tracy data. Does nothing if -Dtracy is not provided",
    ) orelse false;

    const build_mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    var exe = b.addExecutable("buzz", "src/main.zig");
    exe.use_stage1 = true;
    exe.setTarget(target);
    exe.install();
    exe.addIncludePath("/usr/local/include");
    exe.addIncludePath("/usr/include");
    exe.linkSystemLibrary("pcre");
    if (builtin.os.tag == .linux) {
        exe.linkLibC();
    }
    exe.setBuildMode(build_mode);
    exe.setMainPkgPath(".");

    const exe_options = b.addOptions();
    exe.addOptions("build_options", exe_options);
    exe_options.addOption(bool, "enable_tracy", tracy != null);
    exe_options.addOption(bool, "enable_tracy_callstack", tracy_callstack);
    exe_options.addOption(bool, "enable_tracy_allocation", tracy_allocation);
    if (tracy) |tracy_path| {
        const client_cpp = fs.path.join(
            b.allocator,
            &[_][]const u8{ tracy_path, "TracyClient.cpp" },
        ) catch unreachable;

        // On mingw, we need to opt into windows 7+ to get some features required by tracy.
        const tracy_c_flags: []const []const u8 = if (target.isWindows() and target.getAbi() == .gnu)
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
        else
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addIncludePath(tracy_path);
        exe.addCSourceFile(client_cpp, tracy_c_flags);
        exe.linkSystemLibraryName("c++");
    }

    var lib = b.addSharedLibrary("buzz", "src/buzz_api.zig", .{ .unversioned = {} });
    lib.use_stage1 = true;
    lib.setTarget(target);
    lib.install();
    lib.addIncludePath("/usr/local/include");
    lib.addIncludePath("/usr/include");
    lib.linkSystemLibrary("pcre");
    if (builtin.os.tag == .linux) {
        lib.linkLibC();
    }
    lib.setMainPkgPath(".");
    lib.setBuildMode(build_mode);

    b.default_step.dependOn(&exe.step);
    b.default_step.dependOn(&lib.step);

    const lib_paths = [_][]const u8{
        "lib/buzz_std.zig",
        "lib/buzz_io.zig",
        "lib/buzz_gc.zig",
        "lib/buzz_os.zig",
        "lib/buzz_fs.zig",
        "lib/buzz_math.zig",
        "lib/buzz_debug.zig",
        "lib/buzz_buffer.zig",
    };
    const lib_names = [_][]const u8{
        "std",
        "io",
        "gc",
        "os",
        "fs",
        "math",
        "debug",
        "buffer",
    };

    for (lib_paths) |lib_path, index| {
        var std_lib = b.addSharedLibrary(lib_names[index], lib_path, .{ .unversioned = {} });
        std_lib.use_stage1 = true;
        std_lib.setTarget(target);
        std_lib.install();
        std_lib.addIncludePath("/usr/local/include");
        std_lib.addIncludePath("/usr/include");
        std_lib.linkSystemLibrary("pcre");
        if (builtin.os.tag == .linux) {
            std_lib.linkLibC();
        }
        std_lib.setMainPkgPath(".");
        std_lib.setBuildMode(build_mode);
        std_lib.linkLibrary(lib);
        b.default_step.dependOn(&std_lib.step);
    }

    const test_step = b.step("test", "Run all the tests");
    test_step.dependOn(b.getInstallStep());

    var unit_tests = b.addTest("src/main.zig");
    unit_tests.addIncludePath("/usr/local/include");
    unit_tests.addIncludePath("/usr/include");
    unit_tests.linkSystemLibrary("pcre");
    if (builtin.os.tag == .linux) {
        unit_tests.linkLibC();
    }
    unit_tests.use_stage1 = true;
    unit_tests.setBuildMode(.Debug);
    unit_tests.setTarget(target);
    test_step.dependOn(&unit_tests.step);
}
