//! zig build: the bench host into platform/targets/wasm32/host.wasm (as roc-shpadoinkle build.zig).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();
    options.addOption(bool, "small_buffers", false);
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
    place.addCopyFileToSource(host.getEmittedBin(), "platform/targets/wasm32/host.wasm");
    b.getInstallStep().dependOn(&place.step);
}
