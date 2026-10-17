//! PLAN.md 8g: the bench host of `../../../build.zig` with the three options of the measure: `-Dopt=` (the optimize mode,
//! small in the platform), `-Dtrack_live=`, and `-Dout=` (the file to write, in this directory).
//! The sources are the ones of the platform (`host` and `hostlib` here are symbolic links to them). Run `../build.sh`.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();
    const opt = b.option(std.builtin.OptimizeMode, "opt", "Optimize mode (small, as the platform; or fast, safe, tiny)") orelse .small;
    const out = b.option([]const u8, "out", "The output file") orelse "out/host.wasm";
    options.addOption(bool, "small_buffers", false);
    options.addOption(bool, "bench", true);
    options.addOption(bool, "track_live", b.option(bool, "track_live", "Count live bytes (leak checks)") orelse true);
    options.addOption(bool, "ask_js", true);
    const wasm = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });
    const hostlib = b.createModule(.{ .root_source_file = b.path("hostlib/root.zig"), .target = wasm, .optimize = opt, .pic = true });
    hostlib.addImport("build_options", options.createModule());
    const host_mod = b.createModule(.{ .root_source_file = b.path("host/host.zig"), .target = wasm, .optimize = opt, .pic = true });
    host_mod.addImport("hostlib", hostlib);
    const host = b.addObject(.{ .name = "host", .root_module = host_mod });
    host.link_function_sections = true;
    host.link_data_sections = true;
    const place = b.addUpdateSourceFiles();
    place.addCopyFileToSource(host.getEmittedBin(), out);
    b.getInstallStep().dependOn(&place.step);
}
