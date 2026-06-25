const std = @import("std");
const GameBoy = @import("gameboy");

const max_cycles = 200_000_000;

const Mode = enum {
    auto,
    dmg,
    cgb,

    fn from(value: []const u8) ?Mode {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "dmg")) return .dmg;
        if (std.mem.eql(u8, value, "cgb")) return .cgb;
        return null;
    }

    fn toGameBoy(self: Mode) GameBoy.Model {
        return switch (self) {
            .auto => .auto,
            .dmg => .dmg,
            .cgb => .cgb,
        };
    }
};

const Outcome = enum {
    pass,
    fail,
    timeout,
    setup_error,
    missing_rom,
    skipped,
};

const Args = struct {
    rom_path: ?[]const u8 = null,
    boot_path: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    model: Mode = .auto,
};

const ManifestEntry = struct {
    line: usize,
    action: []const u8,
    model: Mode,
    rom_path: []const u8,
    note: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const arena = init.arena;
    var args_iter = try init.minimal.args.iterateAllocator(arena.allocator());
    _ = args_iter.next();

    const args = parseArgs(&args_iter) catch |err| {
        printUsage();
        return err;
    };

    const boot_path = args.boot_path orelse {
        printUsage();
        return error.MissingBootRomPath;
    };

    if (args.manifest_path) |manifest_path| {
        try runManifest(io, allocator, manifest_path, boot_path, args.model);
        return;
    }

    const rom_path = args.rom_path orelse {
        printUsage();
        return error.MissingRomPath;
    };
    const outcome = runOne(io, allocator, rom_path, boot_path, args.model) catch |err| {
        printError(rom_path, err, "");
        return error.ConformanceFailure;
    };
    printOutcome(outcome, rom_path, "", args.model);
    if (outcome != .pass) return error.ConformanceFailure;
}

fn parseArgs(args: anytype) !Args {
    var parsed: Args = .{};

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--boot-rom")) {
            parsed.boot_path = args.next() orelse return error.MissingBootRomPath;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            parsed.manifest_path = args.next() orelse return error.MissingManifestPath;
        } else if (std.mem.eql(u8, arg, "--model")) {
            const value = args.next() orelse return error.MissingModel;
            parsed.model = Mode.from(value) orelse return error.InvalidModel;
        } else if (parsed.rom_path == null) {
            parsed.rom_path = arg;
        } else if (parsed.boot_path == null) {
            parsed.boot_path = arg;
        } else {
            return error.UnexpectedArgument;
        }
    }

    return parsed;
}

fn runManifest(io: std.Io, allocator: std.mem.Allocator, manifest_path: []const u8, boot_path: []const u8, default_model: Mode) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024));
    defer allocator.free(data);

    var total: usize = 0;
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    var lines = std.mem.splitScalar(u8, data, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const entry = parseManifestEntry(line_no, line) catch |err| {
            std.debug.print("INVALID manifest line {d}: {s}\n", .{ line_no, @errorName(err) });
            failed += 1;
            continue;
        };

        total += 1;
        if (std.mem.eql(u8, entry.action, "skip")) {
            skipped += 1;
            printOutcome(.skipped, entry.rom_path, entry.note, entry.model);
            continue;
        }
        if (!std.mem.eql(u8, entry.action, "run")) {
            failed += 1;
            std.debug.print("INVALID manifest line {d}: unknown action '{s}'\n", .{ entry.line, entry.action });
            continue;
        }

        const model = if (entry.model == .auto) default_model else entry.model;
        const outcome = runOne(io, allocator, entry.rom_path, boot_path, model) catch |err| switch (err) {
            error.FileNotFound => .missing_rom,
            else => blk: {
                printError(entry.rom_path, err, entry.note);
                break :blk Outcome.setup_error;
            },
        };

        if (outcome != .setup_error) printOutcome(outcome, entry.rom_path, entry.note, model);
        switch (outcome) {
            .pass => passed += 1,
            .skipped, .missing_rom => skipped += 1,
            else => failed += 1,
        }
    }

    std.debug.print("SUMMARY total={d} pass={d} skip={d} fail={d}\n", .{ total, passed, skipped, failed });
    if (failed != 0) return error.ConformanceFailure;
}

fn parseManifestEntry(line_no: usize, line: []const u8) !ManifestEntry {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const action = fields.next() orelse return error.InvalidManifestLine;
    const model_name = fields.next() orelse return error.InvalidManifestLine;
    const rom_path = fields.next() orelse return error.InvalidManifestLine;
    const note = fields.next() orelse "";
    if (fields.next() != null) return error.InvalidManifestLine;

    return .{
        .line = line_no,
        .action = action,
        .model = Mode.from(model_name) orelse return error.InvalidModel,
        .rom_path = rom_path,
        .note = note,
    };
}

fn runOne(io: std.Io, allocator: std.mem.Allocator, rom_path: []const u8, boot_path: []const u8, model: Mode) !Outcome {
    const rom = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, allocator, .limited(GameBoy.max_rom_size));
    defer allocator.free(rom);
    const boot = try std.Io.Dir.cwd().readFileAlloc(io, boot_path, allocator, .limited(0x900));
    defer allocator.free(boot);

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.setModel(model.toGameBoy());
    try gameboy.load(rom);
    try gameboy.loadBootRom(boot);
    try gameboy.reset();

    var cycles: u64 = 0;
    while (cycles < max_cycles) {
        if (gameboy.read(gameboy.cpu.pc) == 0x40) {
            if (registersPass(&gameboy.cpu)) return .pass;
            if (registersFail(&gameboy.cpu)) {
                std.debug.print(
                    "FAIL_REGS b={x:0>2} c={x:0>2} d={x:0>2} e={x:0>2} h={x:0>2} l={x:0>2} pc={x:0>4}\n",
                    .{ gameboy.cpu.b, gameboy.cpu.c, gameboy.cpu.d, gameboy.cpu.e, gameboy.cpu.h, gameboy.cpu.l, gameboy.cpu.pc },
                );
                return .fail;
            }
        }
        const result = try gameboy.step();
        gameboy.frame_audio_count = 0;
        cycles += result.cycles;
    }
    return .timeout;
}

fn printOutcome(outcome: Outcome, rom_path: []const u8, note: []const u8, model: Mode) void {
    const label = switch (outcome) {
        .pass => "PASS",
        .fail => "FAIL",
        .timeout => "TIMEOUT",
        .setup_error => "ERROR",
        .missing_rom => "SKIP missing",
        .skipped => "SKIP",
    };
    if (note.len == 0) {
        std.debug.print("{s} {s} {s}\n", .{ label, @tagName(model), rom_path });
    } else {
        std.debug.print("{s} {s} {s} # {s}\n", .{ label, @tagName(model), rom_path, note });
    }
}

fn printError(rom_path: []const u8, err: anyerror, note: []const u8) void {
    if (note.len == 0) {
        std.debug.print("ERROR {s}: {s}\n", .{ rom_path, @errorName(err) });
    } else {
        std.debug.print("ERROR {s}: {s} # {s}\n", .{ rom_path, @errorName(err), note });
    }
}

fn printUsage() void {
    std.debug.print("Usage:\n", .{});
    std.debug.print("  zig build test-rom -- <rom> <boot_rom> [--model auto|dmg|cgb]\n", .{});
    std.debug.print("  zig build test-rom -- --manifest <path> --boot-rom <boot_rom> [--model auto|dmg|cgb]\n", .{});
    std.debug.print("Manifest format: action<TAB>model<TAB>rom_path<TAB>note\n", .{});
}

fn registersPass(cpu: *const @import("lr35902").Cpu) bool {
    return cpu.b == 3 and cpu.c == 5 and cpu.d == 8 and
        cpu.e == 13 and cpu.h == 21 and cpu.l == 34;
}

fn registersFail(cpu: *const @import("lr35902").Cpu) bool {
    return cpu.b == 0x42 and cpu.c == 0x42 and cpu.d == 0x42 and
        cpu.e == 0x42 and cpu.h == 0x42 and cpu.l == 0x42;
}
