const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lr35902_dep = b.dependency("lr35902", .{
        .target = target,
        .optimize = optimize,
    });

    const gameboy_mod = b.addModule("gameboy", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/gameboy.zig"),
        .imports = &.{
            .{ .name = "lr35902", .module = lr35902_dep.module("lr35902") },
        },
    });

    const cartridge_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/cartridge.zig"),
    });

    const ppu_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/ppu.zig"),
    });

    const apu_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/apu.zig"),
    });

    const tests = b.addTest(.{ .root_module = gameboy_mod });
    const test_step = b.step("test", "Run Game Boy tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    inline for (&.{ cartridge_mod, ppu_mod, apu_mod }) |module| {
        const module_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(module_tests).step);
    }

    const gameboy = b.addLibrary(.{
        .name = "gameboy",
        .root_module = gameboy_mod,
    });
    b.installArtifact(gameboy);

    const conformance_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/conformance.zig"),
        .imports = &.{
            .{ .name = "gameboy", .module = gameboy_mod },
            .{ .name = "lr35902", .module = lr35902_dep.module("lr35902") },
        },
    });
    const conformance = b.addExecutable(.{
        .name = "gameboy-conformance",
        .root_module = conformance_mod,
    });
    const run_conformance = b.addRunArtifact(conformance);
    if (b.args) |args| run_conformance.addArgs(args);
    const conformance_step = b.step("test-rom", "Run one conformance ROM: zig build test-rom -- rom boot_rom");
    conformance_step.dependOn(&run_conformance.step);

    const fetch_tests = b.addSystemCommand(&.{ "sh", "scripts/fetch-test-roms.sh" });
    const fetch_step = b.step("fetch-tests", "Download the pinned Game Boy test-ROM collection");
    fetch_step.dependOn(&fetch_tests.step);
}
