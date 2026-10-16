//! zig build: the harness host into bench/platform/targets/wasm32/host.wasm (the bench platform, PLAN.md 7a).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();
    options.addOption(bool, "small_buffers", false);
    // The production hostlib/alloc.zig (the port) reads these two. The harness host has all its test hooks, so bench is on.
    options.addOption(bool, "bench", true);
    options.addOption(bool, "ask_js", false);
    options.addOption(u8, "ch_shift", b.option(u8, "ch_shift", "Arena chunk size: 1 << ch_shift") orelse 14);
    options.addOption(bool, "track_live", b.option(bool, "track_live", "Count live bytes (leak checks)") orelse true);
    options.addOption(bool, "owner_tag", b.option(bool, "owner_tag", "Tag spans with the task, free them after a trap") orelse true);
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
    place.addCopyFileToSource(host.getEmittedBin(), "bench/platform/targets/wasm32/host.wasm");
    b.getInstallStep().dependOn(&place.step);
}
