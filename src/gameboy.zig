const std = @import("std");
const lr35902 = @import("lr35902");
const Cartridge = @import("cartridge.zig");
const Ppu = @import("ppu.zig");
const Apu = @import("apu.zig");

const GameBoy = @This();

pub const width = Ppu.width;
pub const height = Ppu.height;
pub const sample_rate = Apu.sample_rate;
pub const max_rom_size = 8 * 1024 * 1024;

pub const Model = enum {
    auto,
    dmg,
    cgb,
};

pub const InputState = struct {
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,
    right: bool = false,
    left: bool = false,
    up: bool = false,
    down: bool = false,
};

pub const StepResult = struct {
    cycles: u32,
    audio: []const f32,
    frame_complete: bool,
};

pub const Error = error{
    NoCartridge,
    NoBootRom,
    InvalidBootRom,
    IncompatibleModel,
    AudioBufferOverflow,
} || Cartridge.Error || lr35902.Cpu.Error || std.mem.Allocator.Error;

const max_frame_samples = 4096;

allocator: std.mem.Allocator,
cpu: lr35902.Cpu = .{},
cartridge: ?Cartridge = null,
ppu: Ppu = .{},
apu: Apu = .{},
boot_rom: []u8 = &.{},
boot_enabled: bool = true,
requested_model: Model = .auto,
active_model: Model = .dmg,
wram: [8][0x1000]u8 = [_][0x1000]u8{[_]u8{0} ** 0x1000} ** 8,
hram: [0x7f]u8 = [_]u8{0} ** 0x7f,
interrupt_enable: u8 = 0,
interrupt_flags: u8 = 0xe1,
joyp: u8 = 0xcf,
input: InputState = .{},
divider: u16 = 0,
tima: u8 = 0,
tma: u8 = 0,
tac: u8 = 0xf8,
tima_reload_delay: u8 = 0,
serial_data: u8 = 0,
serial_control: u8 = 0x7e,
serial_bits: u4 = 0,
serial_cycles: u16 = 0,
serial_loopback: bool = true,
key1: u8 = 0x7e,
double_speed: bool = false,
svbk: u8 = 1,
hdma_source: u16 = 0,
hdma_destination: u16 = 0x8000,
hdma_blocks: u8 = 0,
hdma_active: bool = false,
dma_stall_cycles: u32 = 0,
frame_audio: [max_frame_samples]f32 = [_]f32{0} ** max_frame_samples,
frame_audio_count: usize = 0,

pub fn init(allocator: std.mem.Allocator) GameBoy {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *GameBoy) void {
    if (self.cartridge) |*cartridge| cartridge.deinit();
    if (self.boot_rom.len != 0) self.allocator.free(self.boot_rom);
    self.cartridge = null;
    self.boot_rom = &.{};
}

pub fn load(self: *GameBoy, data: []const u8) Error!void {
    var replacement = try Cartridge.load(self.allocator, data);
    errdefer replacement.deinit();

    const previous = self.cartridge;
    self.cartridge = replacement;
    self.selectModel() catch |err| {
        self.cartridge = previous;
        return err;
    };
    if (previous) |old| {
        var owned = old;
        owned.deinit();
    }
}

pub fn loadBootRom(self: *GameBoy, data: []const u8) Error!void {
    if (data.len != 0x100 and data.len != 0x900) return Error.InvalidBootRom;
    const replacement = try self.allocator.dupe(u8, data);
    errdefer self.allocator.free(replacement);

    const previous = self.boot_rom;
    self.boot_rom = replacement;
    self.selectModel() catch |err| {
        self.boot_rom = previous;
        return err;
    };
    if (previous.len != 0) self.allocator.free(previous);
}

pub fn setModel(self: *GameBoy, model: Model) Error!void {
    const previous = self.requested_model;
    self.requested_model = model;
    self.selectModel() catch |err| {
        self.requested_model = previous;
        return err;
    };
}

pub fn reset(self: *GameBoy) Error!void {
    if (self.cartridge == null) return Error.NoCartridge;
    if (self.boot_rom.len == 0) return Error.NoBootRom;
    try self.selectModel();
    self.cpu.reset();
    self.ppu.reset(if (self.active_model == .cgb) .cgb else .dmg);
    self.apu.reset();
    @memset(&self.wram, [_]u8{0} ** 0x1000);
    @memset(&self.hram, 0);
    self.boot_enabled = true;
    self.interrupt_enable = 0;
    self.interrupt_flags = 0xe1;
    self.joyp = 0xcf;
    self.divider = 0;
    self.tima = 0;
    self.tma = 0;
    self.tac = 0xf8;
    self.tima_reload_delay = 0;
    self.serial_data = 0;
    self.serial_control = 0x7e;
    self.serial_bits = 0;
    self.serial_cycles = 0;
    self.key1 = if (self.active_model == .cgb) 0x7e else 0xff;
    self.double_speed = false;
    self.svbk = 1;
    self.hdma_active = false;
    self.dma_stall_cycles = 0;
    self.frame_audio_count = 0;
}

pub fn setInput(self: *GameBoy, input: InputState) void {
    const old = self.readJoypad();
    self.input = input;
    const new = self.readJoypad();
    if ((old & ~new & 0x0f) != 0) self.interrupt_flags |= 0x10;
}

pub fn setSerialLoopback(self: *GameBoy, enabled: bool) void {
    self.serial_loopback = enabled;
}

pub fn step(self: *GameBoy) Error!StepResult {
    var bus = lr35902.Bus.init(self);
    const instruction = try self.cpu.step(&bus, self.interrupt_enable, &self.interrupt_flags);

    if (self.cpu.stopped and self.active_model == .cgb and (self.key1 & 1) != 0) {
        self.double_speed = !self.double_speed;
        self.key1 = (if (self.double_speed) @as(u8, 0x80) else 0) | 0x7e;
        self.cpu.stopped = false;
    }

    const cpu_cycles = @as(u32, instruction.cycles) + self.dma_stall_cycles;
    self.dma_stall_cycles = 0;
    self.tickTimer(cpu_cycles);
    self.tickSerial(cpu_cycles);
    if (self.cartridge) |*cartridge| cartridge.tick(cpu_cycles);

    const device_cycles: u32 = if (self.double_speed) @max(1, cpu_cycles / 2) else cpu_cycles;
    self.ppu.tick(device_cycles, &self.interrupt_flags);
    if (self.hdma_active and self.ppu.mode() == 0) self.transferHdmaBlock();
    const audio = self.apu.tick(device_cycles);
    try self.appendAudio(audio);
    const frame_complete = self.ppu.takeFrameComplete();

    return .{
        .cycles = cpu_cycles,
        .audio = audio,
        .frame_complete = frame_complete,
    };
}

pub fn stepFrame(self: *GameBoy) Error!StepResult {
    self.frame_audio_count = 0;
    var cycles: u32 = 0;
    while (true) {
        const result = try self.step();
        cycles +%= result.cycles;
        if (result.frame_complete) {
            return .{
                .cycles = cycles,
                .audio = self.frame_audio[0..self.frame_audio_count],
                .frame_complete = true,
            };
        }
    }
}

pub fn framebuffer(self: *const GameBoy) []const u32 {
    return &self.ppu.framebuffer;
}

pub fn saveRam(self: *GameBoy) ?[]const u8 {
    if (self.cartridge) |*cartridge| return cartridge.saveData();
    return null;
}

pub fn loadSaveRam(self: *GameBoy, data: []const u8) !void {
    if (self.cartridge) |*cartridge| return cartridge.loadSaveData(data);
    return Error.NoCartridge;
}

pub fn read(self: *GameBoy, address: u16) u8 {
    if (self.boot_enabled and self.bootMapped(address)) return self.boot_rom[address];
    return switch (address) {
        0x0000...0x7fff, 0xa000...0xbfff => if (self.cartridge) |*cartridge| cartridge.read(address) else 0xff,
        0x8000...0x9fff => if (self.ppu.cpuCanAccessVram()) self.ppu.vram[self.ppu.vbk][address - 0x8000] else 0xff,
        0xc000...0xcfff => self.wram[0][address - 0xc000],
        0xd000...0xdfff => self.wram[self.activeWramBank()][address - 0xd000],
        0xe000...0xefff => self.wram[0][address - 0xe000],
        0xf000...0xfdff => self.wram[self.activeWramBank()][address - 0xf000],
        0xfe00...0xfe9f => if (self.ppu.cpuCanAccessOam()) self.ppu.oam[address - 0xfe00] else 0xff,
        0xfea0...0xfeff => 0xff,
        0xff00 => self.readJoypad(),
        0xff01 => self.serial_data,
        0xff02 => self.serial_control | 0x7c,
        0xff04 => @truncate(self.divider >> 8),
        0xff05 => self.tima,
        0xff06 => self.tma,
        0xff07 => self.tac | 0xf8,
        0xff0f => self.interrupt_flags | 0xe0,
        0xff10...0xff3f => self.apu.read(address),
        0xff40...0xff4b, 0xff4f, 0xff68...0xff6b => self.ppu.readRegister(address),
        0xff4d => if (self.active_model == .cgb) self.key1 else 0xff,
        0xff51 => @truncate(self.hdma_source >> 8),
        0xff52 => @as(u8, @truncate(self.hdma_source)) | 0x0f,
        0xff53 => @as(u8, @truncate(self.hdma_destination >> 8)) | 0xe0,
        0xff54 => @as(u8, @truncate(self.hdma_destination)) | 0x0f,
        0xff55 => if (self.hdma_active) self.hdma_blocks - 1 else 0xff,
        0xff70 => if (self.active_model == .cgb) 0xf8 | self.svbk else 0xff,
        0xff80...0xfffe => self.hram[address - 0xff80],
        0xffff => self.interrupt_enable,
        else => 0xff,
    };
}

pub fn write(self: *GameBoy, address: u16, value: u8) void {
    switch (address) {
        0x0000...0x7fff, 0xa000...0xbfff => if (self.cartridge) |*cartridge| cartridge.write(address, value),
        0x8000...0x9fff => {
            if (self.ppu.cpuCanAccessVram()) self.ppu.vram[self.ppu.vbk][address - 0x8000] = value;
        },
        0xc000...0xcfff => self.wram[0][address - 0xc000] = value,
        0xd000...0xdfff => self.wram[self.activeWramBank()][address - 0xd000] = value,
        0xe000...0xefff => self.wram[0][address - 0xe000] = value,
        0xf000...0xfdff => self.wram[self.activeWramBank()][address - 0xf000] = value,
        0xfe00...0xfe9f => {
            if (self.ppu.cpuCanAccessOam()) self.ppu.oam[address - 0xfe00] = value;
        },
        0xfea0...0xfeff => {},
        0xff00 => self.joyp = (self.joyp & 0xcf) | (value & 0x30),
        0xff01 => self.serial_data = value,
        0xff02 => {
            self.serial_control = value & 0x83;
            if ((value & 0x80) != 0) {
                self.serial_bits = 0;
                self.serial_cycles = 0;
            }
        },
        0xff04 => self.writeDivider(),
        0xff05 => {
            self.tima = value;
            self.tima_reload_delay = 0;
        },
        0xff06 => self.tma = value,
        0xff07 => self.writeTac(value),
        0xff0f => self.interrupt_flags = value & 0x1f,
        0xff10...0xff3f => self.apu.write(address, value),
        0xff40...0xff4b, 0xff4f, 0xff68...0xff6b => {
            self.ppu.writeRegister(address, value, &self.interrupt_flags);
            if (address == 0xff46) self.oamDma(value);
        },
        0xff4d => {
            if (self.active_model == .cgb) self.key1 = (self.key1 & 0x80) | 0x7e | (value & 1);
        },
        0xff50 => {
            if (value != 0) self.boot_enabled = false;
        },
        0xff51 => self.hdma_source = (@as(u16, value) << 8) | (self.hdma_source & 0x00ff),
        0xff52 => self.hdma_source = (self.hdma_source & 0xff00) | (value & 0xf0),
        0xff53 => self.hdma_destination = 0x8000 | (@as(u16, value & 0x1f) << 8) | (self.hdma_destination & 0x00ff),
        0xff54 => self.hdma_destination = (self.hdma_destination & 0xff00) | (value & 0xf0),
        0xff55 => self.startHdma(value),
        0xff70 => {
            if (self.active_model == .cgb) {
                self.svbk = value & 7;
                if (self.svbk == 0) self.svbk = 1;
            }
        },
        0xff80...0xfffe => self.hram[address - 0xff80] = value,
        0xffff => self.interrupt_enable = value & 0x1f,
        else => {},
    }
}

fn selectModel(self: *GameBoy) Error!void {
    const support = if (self.cartridge) |cartridge| cartridge.model_support else null;
    const boot_model: ?Model = switch (self.boot_rom.len) {
        0 => null,
        0x100 => .dmg,
        0x900 => .cgb,
        else => return Error.InvalidBootRom,
    };
    self.active_model = switch (self.requested_model) {
        .dmg => .dmg,
        .cgb => .cgb,
        .auto => if (support) |value| switch (value) {
            .cgb_only, .cgb_compatible => .cgb,
            .dmg => .dmg,
        } else boot_model orelse .dmg,
    };
    if (support) |value| {
        if (value == .cgb_only and self.active_model != .cgb) return Error.IncompatibleModel;
    }
    if (boot_model) |value| if (value != self.active_model) return Error.IncompatibleModel;
}

fn bootMapped(self: *const GameBoy, address: u16) bool {
    if (self.boot_rom.len == 0x100) return address < 0x100;
    if (self.boot_rom.len == 0x900) return address < 0x100 or (address >= 0x200 and address < 0x900);
    return false;
}

fn activeWramBank(self: *const GameBoy) usize {
    return if (self.active_model == .cgb) @max(1, self.svbk & 7) else 1;
}

fn readJoypad(self: *const GameBoy) u8 {
    var result = (self.joyp & 0xf0) | 0x0f;
    if ((self.joyp & 0x10) == 0) {
        if (self.input.right) result &= ~@as(u8, 0x01);
        if (self.input.left) result &= ~@as(u8, 0x02);
        if (self.input.up) result &= ~@as(u8, 0x04);
        if (self.input.down) result &= ~@as(u8, 0x08);
    }
    if ((self.joyp & 0x20) == 0) {
        if (self.input.a) result &= ~@as(u8, 0x01);
        if (self.input.b) result &= ~@as(u8, 0x02);
        if (self.input.select) result &= ~@as(u8, 0x04);
        if (self.input.start) result &= ~@as(u8, 0x08);
    }
    return result | 0xc0;
}

fn timerSignal(self: *const GameBoy) bool {
    if ((self.tac & 0x04) == 0) return false;
    const bit: u4 = switch (self.tac & 3) {
        0 => 9,
        1 => 3,
        2 => 5,
        3 => 7,
        else => unreachable,
    };
    return ((self.divider >> bit) & 1) != 0;
}

fn tickTimer(self: *GameBoy, cycles: u32) void {
    var remaining = cycles;
    while (remaining > 0) : (remaining -= 1) {
        const old_signal = self.timerSignal();
        self.divider +%= 1;
        const new_signal = self.timerSignal();
        if (old_signal and !new_signal) self.incrementTima();
        if (self.tima_reload_delay > 0) {
            self.tima_reload_delay -= 1;
            if (self.tima_reload_delay == 0) {
                self.tima = self.tma;
                self.interrupt_flags |= 0x04;
            }
        }
    }
}

fn incrementTima(self: *GameBoy) void {
    if (self.tima == 0xff) {
        self.tima = 0;
        self.tima_reload_delay = 4;
    } else {
        self.tima += 1;
    }
}

fn writeDivider(self: *GameBoy) void {
    const old_signal = self.timerSignal();
    self.divider = 0;
    if (old_signal and !self.timerSignal()) self.incrementTima();
}

fn writeTac(self: *GameBoy, value: u8) void {
    const old_signal = self.timerSignal();
    self.tac = value & 7;
    if (old_signal and !self.timerSignal()) self.incrementTima();
}

fn tickSerial(self: *GameBoy, cycles: u32) void {
    if ((self.serial_control & 0x81) != 0x81) return;
    self.serial_cycles += @intCast(cycles);
    const period: u16 = if (self.active_model == .cgb and (self.serial_control & 0x02) != 0) 16 else 512;
    while (self.serial_cycles >= period and self.serial_bits < 8) {
        self.serial_cycles -= period;
        self.serial_data = (self.serial_data << 1) | (if (self.serial_loopback) (self.serial_data >> 7) else 1);
        self.serial_bits += 1;
    }
    if (self.serial_bits == 8) {
        self.serial_control &= ~@as(u8, 0x80);
        self.interrupt_flags |= 0x08;
        self.serial_bits = 0;
    }
}

fn oamDma(self: *GameBoy, page: u8) void {
    const source = @as(u16, page) << 8;
    var offset: u16 = 0;
    while (offset < 160) : (offset += 1) self.ppu.oam[offset] = self.read(source + offset);
    self.dma_stall_cycles += 640;
}

fn startHdma(self: *GameBoy, value: u8) void {
    if (self.active_model != .cgb) return;
    if (self.hdma_active and (value & 0x80) == 0) {
        self.hdma_active = false;
        return;
    }
    self.hdma_blocks = (value & 0x7f) + 1;
    if ((value & 0x80) != 0) {
        self.hdma_active = true;
    } else {
        while (self.hdma_blocks > 0) {
            self.transferHdmaBlock();
            self.dma_stall_cycles += 32;
        }
    }
}

fn transferHdmaBlock(self: *GameBoy) void {
    if (self.hdma_blocks == 0) {
        self.hdma_active = false;
        return;
    }
    var offset: u16 = 0;
    while (offset < 0x10) : (offset += 1) {
        self.ppu.vram[self.ppu.vbk][(self.hdma_destination - 0x8000 + offset) & 0x1fff] = self.read(self.hdma_source + offset);
    }
    self.hdma_source +%= 0x10;
    self.hdma_destination = 0x8000 | ((self.hdma_destination +% 0x10) & 0x1ff0);
    self.hdma_blocks -= 1;
    if (self.hdma_blocks == 0) self.hdma_active = false;
}

fn appendAudio(self: *GameBoy, audio: []const f32) Error!void {
    if (audio.len > self.frame_audio.len - self.frame_audio_count) return Error.AudioBufferOverflow;
    @memcpy(self.frame_audio[self.frame_audio_count..][0..audio.len], audio);
    self.frame_audio_count += audio.len;
}

fn makeTestRom(allocator: std.mem.Allocator, cgb_flag: u8) ![]u8 {
    const data = try allocator.alloc(u8, 32 * 1024);
    @memset(data, 0);
    data[0x143] = cgb_flag;
    data[0x147] = 0;
    data[0x148] = 0;
    data[0x149] = 0;
    return data;
}

test "loads boot ROM, maps cartridge, and disables boot overlay" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0);
    defer allocator.free(rom);
    var boot = [_]u8{0} ** 0x100;
    boot[0] = 0x31;

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.load(rom);
    try gameboy.loadBootRom(&boot);
    try gameboy.reset();
    try std.testing.expectEqual(@as(u8, 0x31), gameboy.read(0));
    gameboy.write(0xff50, 1);
    try std.testing.expectEqual(@as(u8, 0), gameboy.read(0));
}

test "timer overflow reloads modulo and requests interrupt" {
    var gameboy = GameBoy.init(std.testing.allocator);
    gameboy.tima = 0xff;
    gameboy.tma = 0x42;
    gameboy.tac = 0x05;
    gameboy.divider = 0x0f;
    gameboy.tickTimer(5);
    try std.testing.expectEqual(@as(u8, 0x42), gameboy.tima);
    try std.testing.expect((gameboy.interrupt_flags & 0x04) != 0);
}

test "CGB HDMA copies one block into selected VRAM bank" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0xc0);
    defer allocator.free(rom);
    var boot = [_]u8{0} ** 0x900;

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.load(rom);
    try gameboy.loadBootRom(&boot);
    try gameboy.reset();
    gameboy.wram[0][0] = 0x5a;
    gameboy.hdma_source = 0xc000;
    gameboy.hdma_destination = 0x8000;
    gameboy.startHdma(0);
    try std.testing.expectEqual(@as(u8, 0x5a), gameboy.ppu.vram[0][0]);
}

test "failed cartridge replacement preserves the loaded cartridge" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0);
    defer allocator.free(rom);

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.load(rom);

    var invalid = [_]u8{0} ** (32 * 1024);
    invalid[0x147] = 0x22;
    invalid[0x148] = 0;
    try std.testing.expectError(Error.UnsupportedCartridge, gameboy.load(&invalid));
    try std.testing.expect(gameboy.cartridge != null);
    try std.testing.expectEqual(@as(u8, 0), gameboy.read(0));
}

test "OAM DMA records its CPU stall" {
    var gameboy = GameBoy.init(std.testing.allocator);
    gameboy.wram[0][0] = 0x5a;

    gameboy.oamDma(0xc0);

    try std.testing.expectEqual(@as(u8, 0x5a), gameboy.ppu.oam[0]);
    try std.testing.expectEqual(@as(u32, 640), gameboy.dma_stall_cycles);
}

test "frame audio overflow is reported" {
    var gameboy = GameBoy.init(std.testing.allocator);
    gameboy.frame_audio_count = gameboy.frame_audio.len;

    try std.testing.expectError(
        Error.AudioBufferOverflow,
        gameboy.appendAudio(&[_]f32{0}),
    );
}

test "steps a complete DMG frame with required boot ROM" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0);
    defer allocator.free(rom);
    var boot = [_]u8{0} ** 0x100;

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.load(rom);
    try gameboy.loadBootRom(&boot);
    try gameboy.reset();

    const result = try gameboy.stepFrame();
    try std.testing.expect(result.frame_complete);
    try std.testing.expect(result.audio.len > 0);
    try std.testing.expectEqual(@as(usize, width * height), gameboy.framebuffer().len);
}
