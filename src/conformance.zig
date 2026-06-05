const std = @import("std");
const GameBoy = @import("gameboy");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    const arena = init.arena;
    var args = try init.minimal.args.iterateAllocator(arena.allocator());
    _ = args.next();
    const rom_path = args.next() orelse return error.MissingRomPath;
    const boot_path = args.next() orelse return error.MissingBootRomPath;

    const rom = try std.Io.Dir.cwd().readFileAlloc(io, rom_path, allocator, .limited(GameBoy.max_rom_size));
    defer allocator.free(rom);
    const boot = try std.Io.Dir.cwd().readFileAlloc(io, boot_path, allocator, .limited(0x900));
    defer allocator.free(boot);

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.load(rom);
    try gameboy.loadBootRom(boot);
    try gameboy.reset();

    var cycles: u64 = 0;
    while (cycles < 200_000_000) {
        if (gameboy.read(gameboy.cpu.pc) == 0x40) {
            if (registersPass(&gameboy.cpu)) {
                std.debug.print("PASS {s}\n", .{rom_path});
                return;
            }
            if (registersFail(&gameboy.cpu)) {
                std.debug.print("FAIL {s}\n", .{rom_path});
                return error.ConformanceFailure;
            }
        }
        cycles += (try gameboy.step()).cycles;
    }
    return error.ConformanceTimeout;
}

fn registersPass(cpu: *const @import("lr35902").Cpu) bool {
    return cpu.b == 3 and cpu.c == 5 and cpu.d == 8 and
        cpu.e == 13 and cpu.h == 21 and cpu.l == 34;
}

fn registersFail(cpu: *const @import("lr35902").Cpu) bool {
    return cpu.b == 0x42 and cpu.c == 0x42 and cpu.d == 0x42 and
        cpu.e == 0x42 and cpu.h == 0x42 and cpu.l == 0x42;
}
