const std = @import("std");
const lr35902 = @import("lr35902");
const Cartridge = @import("cartridge.zig");
const Ppu = @import("ppu.zig");
const Apu = @import("apu.zig");
const State = @import("state_io.zig");

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
const state_magic = "6SOZGB01";
const state_version: u8 = 1;

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
cpu_bus_active: bool = false,
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
    self.cpu_bus_active = true;
    const instruction = self.cpu.step(self, self.interrupt_enable, &self.interrupt_flags) catch |err| {
        self.cpu_bus_active = false;
        return err;
    };
    self.cpu_bus_active = false;

    if (self.cpu.stopped and self.active_model == .cgb and (self.key1 & 1) != 0) {
        self.double_speed = !self.double_speed;
        self.key1 = (if (self.double_speed) @as(u8, 0x80) else 0) | 0x7e;
        self.cpu.stopped = false;
        self.dma_stall_cycles += 2050;
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

pub fn saveState(self: *const GameBoy, allocator: std.mem.Allocator) ![]u8 {
    var state = std.Io.Writer.Allocating.init(allocator);
    defer state.deinit();
    const writer = &state.writer;

    try writer.writeAll(state_magic);
    try State.writeValue(writer, state_version);
    try State.writeValue(writer, @as(u32, @intCast(self.boot_rom.len)));
    try State.writeValue(writer, State.hashBytes(0x6762426f6f74486a, self.boot_rom));
    try State.writeValue(writer, self.cpu);
    try State.writeValue(writer, self.ppu);
    try State.writeValue(writer, self.apu);
    try State.writeValue(writer, self.boot_enabled);
    try State.writeValue(writer, self.requested_model);
    try State.writeValue(writer, self.active_model);
    try State.writeValue(writer, self.wram);
    try State.writeValue(writer, self.hram);
    try State.writeValue(writer, self.interrupt_enable);
    try State.writeValue(writer, self.interrupt_flags);
    try State.writeValue(writer, self.joyp);
    try State.writeValue(writer, self.input);
    try State.writeValue(writer, self.divider);
    try State.writeValue(writer, self.tima);
    try State.writeValue(writer, self.tma);
    try State.writeValue(writer, self.tac);
    try State.writeValue(writer, self.tima_reload_delay);
    try State.writeValue(writer, self.serial_data);
    try State.writeValue(writer, self.serial_control);
    try State.writeValue(writer, self.serial_bits);
    try State.writeValue(writer, self.serial_cycles);
    try State.writeValue(writer, self.serial_loopback);
    try State.writeValue(writer, self.key1);
    try State.writeValue(writer, self.double_speed);
    try State.writeValue(writer, self.svbk);
    try State.writeValue(writer, self.hdma_source);
    try State.writeValue(writer, self.hdma_destination);
    try State.writeValue(writer, self.hdma_blocks);
    try State.writeValue(writer, self.hdma_active);
    try State.writeValue(writer, self.dma_stall_cycles);

    if (self.cartridge) |*cartridge| {
        try State.writeValue(writer, true);
        try cartridge.saveState(writer);
    } else {
        try State.writeValue(writer, false);
    }

    return state.toOwnedSlice();
}

pub fn loadState(self: *GameBoy, data: []const u8) !void {
    var state = std.Io.Reader.fixed(data);
    const reader = &state;
    try State.expectBytes(reader, state_magic);
    if ((try State.readValue(reader, u8)) != state_version) return State.Error.UnsupportedStateVersion;

    const boot_len = try State.readValue(reader, u32);
    const boot_hash = try State.readValue(reader, u64);
    if (boot_len != self.boot_rom.len) return State.Error.StateKindMismatch;
    if (boot_hash != State.hashBytes(0x6762426f6f74486a, self.boot_rom)) return State.Error.StateKindMismatch;

    const cpu = try State.readValue(reader, lr35902.Cpu);
    const ppu = try State.readValue(reader, Ppu);
    const apu = try State.readValue(reader, Apu);
    const boot_enabled = try State.readValue(reader, bool);
    const requested_model = try State.readValue(reader, Model);
    const active_model = try State.readValue(reader, Model);
    const wram = try State.readValue(reader, [8][0x1000]u8);
    const hram = try State.readValue(reader, [0x7f]u8);
    const interrupt_enable = try State.readValue(reader, u8);
    const interrupt_flags = try State.readValue(reader, u8);
    const joyp = try State.readValue(reader, u8);
    const input = try State.readValue(reader, InputState);
    const divider = try State.readValue(reader, u16);
    const tima = try State.readValue(reader, u8);
    const tma = try State.readValue(reader, u8);
    const tac = try State.readValue(reader, u8);
    const tima_reload_delay = try State.readValue(reader, u8);
    const serial_data = try State.readValue(reader, u8);
    const serial_control = try State.readValue(reader, u8);
    const serial_bits = try State.readValue(reader, u4);
    const serial_cycles = try State.readValue(reader, u16);
    const serial_loopback = try State.readValue(reader, bool);
    const key1 = try State.readValue(reader, u8);
    const double_speed = try State.readValue(reader, bool);
    const svbk = try State.readValue(reader, u8);
    const hdma_source = try State.readValue(reader, u16);
    const hdma_destination = try State.readValue(reader, u16);
    const hdma_blocks = try State.readValue(reader, u8);
    const hdma_active = try State.readValue(reader, bool);
    const dma_stall_cycles = try State.readValue(reader, u32);
    const has_cartridge = try State.readValue(reader, bool);

    if (has_cartridge) {
        if (self.cartridge) |*cartridge| {
            try cartridge.loadState(reader);
        } else {
            return Error.NoCartridge;
        }
    } else if (self.cartridge != null) {
        return State.Error.StateKindMismatch;
    }
    try State.done(reader);

    self.cpu = cpu;
    self.ppu = ppu;
    self.apu = apu;
    self.boot_enabled = boot_enabled;
    self.requested_model = requested_model;
    self.active_model = active_model;
    self.wram = wram;
    self.hram = hram;
    self.interrupt_enable = interrupt_enable;
    self.interrupt_flags = interrupt_flags;
    self.joyp = joyp;
    self.input = input;
    self.divider = divider;
    self.tima = tima;
    self.tma = tma;
    self.tac = tac;
    self.tima_reload_delay = tima_reload_delay;
    self.serial_data = serial_data;
    self.serial_control = serial_control;
    self.serial_bits = serial_bits;
    self.serial_cycles = serial_cycles;
    self.serial_loopback = serial_loopback;
    self.key1 = key1;
    self.double_speed = double_speed;
    self.svbk = svbk;
    self.hdma_source = hdma_source;
    self.hdma_destination = hdma_destination;
    self.hdma_blocks = hdma_blocks;
    self.hdma_active = hdma_active;
    self.dma_stall_cycles = dma_stall_cycles;
    self.frame_audio_count = 0;
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
        0xff05 => self.writeTima(value),
        0xff06 => self.writeTma(value),
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
        const overflowed = old_signal and !new_signal and self.incrementTima();
        if (!overflowed and self.tima_reload_delay > 0) {
            self.tima_reload_delay -= 1;
            if (self.tima_reload_delay == 0) {
                self.tima = self.tma;
                self.interrupt_flags |= 0x04;
            }
        }
    }
}

fn incrementTima(self: *GameBoy) bool {
    if (self.tima == 0xff) {
        self.tima = 0;
        self.tima_reload_delay = 4;
        return true;
    } else {
        self.tima += 1;
        return false;
    }
}

fn writeDivider(self: *GameBoy) void {
    const old_signal = self.timerSignal();
    self.divider = 0;
    if (old_signal and !self.timerSignal()) _ = self.incrementTima();
}

fn writeTac(self: *GameBoy, value: u8) void {
    const old_signal = self.timerSignal();
    self.tac = value & 7;
    if (old_signal and !self.timerSignal()) _ = self.incrementTima();
}

fn writeTima(self: *GameBoy, value: u8) void {
    if (self.timerReloadCycleAlias()) return;
    self.tima = value;
    self.tima_reload_delay = 0;
}

fn writeTma(self: *GameBoy, value: u8) void {
    const reload_cycle = self.timerReloadCycleAlias();
    self.tma = value;
    if (reload_cycle) self.tima = value;
}

fn timerReloadCycleAlias(self: *const GameBoy) bool {
    if (!self.cpu_bus_active) return self.tima_reload_delay == 1;
    if (self.tima_reload_delay != 0) return self.tima_reload_delay == 1;
    if ((self.interrupt_flags & 0x04) == 0 or self.tima != self.tma) return false;
    const bit: u4 = switch (self.tac & 3) {
        0 => 9,
        1 => 3,
        2 => 5,
        3 => 7,
        else => unreachable,
    };
    const period_mask = (@as(u16, 1) << (bit + 1)) - 1;
    return (self.divider & period_mask) == 4;
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

test "timer overflow delay starts after overflow cycle" {
    var gameboy = GameBoy.init(std.testing.allocator);
    gameboy.tima = 0xff;
    gameboy.tma = 0x42;
    gameboy.tac = 0x05;
    gameboy.divider = 0x0f;

    gameboy.tickTimer(1);
    try std.testing.expectEqual(@as(u8, 0), gameboy.tima);
    try std.testing.expectEqual(@as(u8, 4), gameboy.tima_reload_delay);
    try std.testing.expectEqual(@as(u8, 0), gameboy.interrupt_flags & 0x04);

    gameboy.tickTimer(3);
    try std.testing.expectEqual(@as(u8, 0), gameboy.tima);
    try std.testing.expectEqual(@as(u8, 1), gameboy.tima_reload_delay);
    try std.testing.expectEqual(@as(u8, 0), gameboy.interrupt_flags & 0x04);

    gameboy.tickTimer(1);
    try std.testing.expectEqual(@as(u8, 0x42), gameboy.tima);
    try std.testing.expectEqual(@as(u8, 0), gameboy.tima_reload_delay);
    try std.testing.expect((gameboy.interrupt_flags & 0x04) != 0);
}

test "TIMA write before reload cancels pending reload" {
    var gameboy = GameBoy.init(std.testing.allocator);
    gameboy.tima = 0xff;
    gameboy.tma = 0x42;
    gameboy.tac = 0x05;
    gameboy.divider = 0x0f;

    gameboy.tickTimer(1);
    gameboy.write(0xff05, 0x99);
    gameboy.tickTimer(4);

    try std.testing.expectEqual(@as(u8, 0x99), gameboy.tima);
    try std.testing.expectEqual(@as(u8, 0), gameboy.tima_reload_delay);
    try std.testing.expectEqual(@as(u8, 0), gameboy.interrupt_flags & 0x04);
}

test "TIMA write on reload cycle is ignored" {
    var gameboy = GameBoy.init(std.testing.allocator);
    gameboy.tima = 0xff;
    gameboy.tma = 0x42;
    gameboy.tac = 0x05;
    gameboy.divider = 0x0f;

    gameboy.tickTimer(4);
    gameboy.write(0xff05, 0x99);
    gameboy.tickTimer(1);

    try std.testing.expectEqual(@as(u8, 0x42), gameboy.tima);
    try std.testing.expectEqual(@as(u8, 0), gameboy.tima_reload_delay);
    try std.testing.expect((gameboy.interrupt_flags & 0x04) != 0);
}

test "TMA write on reload cycle updates reloaded TIMA" {
    var gameboy = GameBoy.init(std.testing.allocator);
    gameboy.tima = 0xff;
    gameboy.tma = 0x42;
    gameboy.tac = 0x05;
    gameboy.divider = 0x0f;

    gameboy.tickTimer(4);
    gameboy.write(0xff06, 0x77);
    gameboy.tickTimer(1);

    try std.testing.expectEqual(@as(u8, 0x77), gameboy.tma);
    try std.testing.expectEqual(@as(u8, 0x77), gameboy.tima);
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

test "Game Boy state round trips after frame with device state" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0xc0);
    defer allocator.free(rom);
    var boot = [_]u8{0} ** 0x900;

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.load(rom);
    try gameboy.loadBootRom(&boot);
    try gameboy.reset();
    _ = try gameboy.stepFrame();

    gameboy.cpu.a = 0x12;
    gameboy.wram[3][0x100] = 0x34;
    gameboy.hram[0x10] = 0x56;
    gameboy.ppu.vram[1][0x20] = 0x78;
    gameboy.apu.enabled = false;
    gameboy.boot_enabled = false;
    gameboy.input = .{ .a = true, .right = true };
    gameboy.tima = 0x9a;
    gameboy.tma = 0xbc;
    gameboy.interrupt_enable = 0x1f;
    gameboy.svbk = 3;

    const state = try gameboy.saveState(allocator);
    defer allocator.free(state);

    gameboy.cpu.a = 0;
    gameboy.wram[3][0x100] = 0;
    gameboy.hram[0x10] = 0;
    gameboy.ppu.vram[1][0x20] = 0;
    gameboy.apu.enabled = true;
    gameboy.boot_enabled = true;
    gameboy.input = .{};
    gameboy.tima = 0;
    gameboy.tma = 0;
    gameboy.interrupt_enable = 0;
    gameboy.svbk = 1;

    try gameboy.loadState(state);

    try std.testing.expectEqual(@as(u8, 0x12), gameboy.cpu.a);
    try std.testing.expectEqual(@as(u8, 0x34), gameboy.wram[3][0x100]);
    try std.testing.expectEqual(@as(u8, 0x56), gameboy.hram[0x10]);
    try std.testing.expectEqual(@as(u8, 0x78), gameboy.ppu.vram[1][0x20]);
    try std.testing.expect(!gameboy.apu.enabled);
    try std.testing.expect(!gameboy.boot_enabled);
    try std.testing.expect(gameboy.input.a);
    try std.testing.expect(gameboy.input.right);
    try std.testing.expectEqual(@as(u8, 0x9a), gameboy.tima);
    try std.testing.expectEqual(@as(u8, 0xbc), gameboy.tma);
    try std.testing.expectEqual(@as(u8, 0x1f), gameboy.interrupt_enable);
    try std.testing.expectEqual(@as(u8, 3), gameboy.svbk);
    try std.testing.expectEqual(@as(usize, 0), gameboy.frame_audio_count);
}

test "Game Boy state loading rejects malformed payloads and wrong boot ROM" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0);
    defer allocator.free(rom);
    var boot = [_]u8{0} ** 0x100;

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.load(rom);
    try gameboy.loadBootRom(&boot);
    try gameboy.reset();

    const state = try gameboy.saveState(allocator);
    defer allocator.free(state);

    try std.testing.expectError(State.Error.InvalidState, gameboy.loadState(state[0 .. state.len - 1]));

    const wrong_version = try allocator.dupe(u8, state);
    defer allocator.free(wrong_version);
    wrong_version[state_magic.len] = state_version + 1;
    try std.testing.expectError(State.Error.UnsupportedStateVersion, gameboy.loadState(wrong_version));

    boot[0] = 1;
    try gameboy.loadBootRom(&boot);
    try std.testing.expectError(State.Error.StateKindMismatch, gameboy.loadState(state));
}

test "CGB speed switch toggles speed and stalls CPU" {
    const allocator = std.testing.allocator;
    const rom = try makeTestRom(allocator, 0);
    defer allocator.free(rom);
    var boot = [_]u8{0} ** 0x900;

    var gameboy = GameBoy.init(allocator);
    defer gameboy.deinit();
    try gameboy.load(rom);
    try gameboy.setModel(.cgb);
    try gameboy.loadBootRom(&boot);
    try gameboy.reset();

    try std.testing.expectEqual(Model.cgb, gameboy.active_model);
    try std.testing.expectEqual(@as(u8, 0x7e), gameboy.read(0xff4d));
    try std.testing.expect(!gameboy.double_speed);

    // Prepare speed switch
    gameboy.write(0xff4d, 1);
    try std.testing.expectEqual(@as(u8, 0x7f), gameboy.read(0xff4d));

    // Mock CPU execution of STOP opcode
    gameboy.cpu.stopped = true;

    // Step should execute transition
    const result = try gameboy.step();

    try std.testing.expect(gameboy.double_speed);
    try std.testing.expect(!gameboy.cpu.stopped);
    try std.testing.expectEqual(@as(u8, 0xfe), gameboy.read(0xff4d));
    try std.testing.expect(result.cycles >= 2050);
}
