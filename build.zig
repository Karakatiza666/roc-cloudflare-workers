//! zig build: the production host into platform/targets/wasm32/host.wasm.
//! zig build -Dbench=true: the bench host (it also has the test exports of PLAN.md 7a) into
//! bench/platform/targets/wasm32/host.wasm.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();
    const bench = b.option(bool, "bench", "Bench host: add the test exports (PLAN.md 7a)") orelse false;
    options.addOption(bool, "small_buffers", false);
    options.addOption(bool, "bench", bench);
    options.addOption(bool, "track_live", b.option(bool, "track_live", "Count live bytes (leak checks)") orelse true);
    // The allocator asks JS (`js_grow`) before each grow (PLAN.md 4b).
    options.addOption(bool, "ask_js", true);
    const wasm = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });
    const hostlib = b.createModule(.{ .root_source_file = b.path("hostlib/root.zig"), .target = wasm, .optimize = .ReleaseSmall, .pic = true });
    hostlib.addImport("build_options", options.createModule());
    const host_mod = b.createModule(.{ .root_source_file = b.path("host/host.zig"), .target = wasm, .optimize = .ReleaseSmall, .pic = true });
    host_mod.addImport("hostlib", hostlib);
    const host = b.addObject(.{ .name = "host", .root_module = host_mod });
    host.link_function_sections = true;
    host.link_data_sections = true;
    const place = b.addUpdateSourceFiles();
    place.addCopyFileToSource(host.getEmittedBin(), if (bench) "bench/platform/targets/wasm32/host.wasm" else "platform/targets/wasm32/host.wasm");
    b.getInstallStep().dependOn(&place.step);
}
