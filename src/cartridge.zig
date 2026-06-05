const std = @import("std");

const Cartridge = @This();

pub const ModelSupport = enum {
    dmg,
    cgb_compatible,
    cgb_only,
};

pub const Mapper = enum {
    rom,
    mbc1,
    mbc2,
    mbc3,
    mbc5,
};

pub const Error = error{
    InvalidRom,
    UnsupportedCartridge,
    InvalidSave,
};

allocator: std.mem.Allocator,
rom: []u8,
ram: []u8,
mapper: Mapper,
model_support: ModelSupport,
has_battery: bool,
has_rtc: bool,
has_rumble: bool,
ram_enabled: bool = false,
rom_bank: u16 = 1,
ram_bank: u8 = 0,
bank_mode: u1 = 0,
mbc1_high: u2 = 0,
mbc3_select: u8 = 0,
latch_last: u1 = 0,
rtc: [5]u8 = [_]u8{0} ** 5,
rtc_latched: [5]u8 = [_]u8{0} ** 5,
rtc_cycles: u64 = 0,
rumble_on: bool = false,
save_cache: []u8,

const save_magic = "6SOZGBS1";
const save_header_size = save_magic.len + 5 + 8;

pub fn load(allocator: std.mem.Allocator, data: []const u8) !Cartridge {
    if (data.len < 0x150) return Error.InvalidRom;
    const mapper_info = mapperFromType(data[0x147]) orelse return Error.UnsupportedCartridge;
    const declared_rom_size = romSize(data[0x148]) orelse return Error.InvalidRom;
    if (data.len < declared_rom_size) return Error.InvalidRom;
    const ram_size = ramSize(data[0x149], mapper_info.mapper);

    const rom = try allocator.dupe(u8, data[0..declared_rom_size]);
    errdefer allocator.free(rom);
    const ram = try allocator.alloc(u8, ram_size);
    errdefer allocator.free(ram);
    @memset(ram, 0xff);

    const save_cache = try allocator.alloc(u8, save_header_size + ram_size);
    errdefer allocator.free(save_cache);
    @memset(save_cache, 0);

    return .{
        .allocator = allocator,
        .rom = rom,
        .ram = ram,
        .mapper = mapper_info.mapper,
        .model_support = switch (data[0x143]) {
            0x80 => .cgb_compatible,
            0xc0 => .cgb_only,
            else => .dmg,
        },
        .has_battery = mapper_info.battery,
        .has_rtc = mapper_info.rtc,
        .has_rumble = mapper_info.rumble,
        .save_cache = save_cache,
    };
}

pub fn deinit(self: *Cartridge) void {
    self.allocator.free(self.rom);
    self.allocator.free(self.ram);
    self.allocator.free(self.save_cache);
    self.* = undefined;
}

pub fn read(self: *Cartridge, address: u16) u8 {
    return switch (address) {
        0x0000...0x3fff => self.rom[fixedRomOffset(self, address) % self.rom.len],
        0x4000...0x7fff => self.rom[switchableRomOffset(self, address) % self.rom.len],
        0xa000...0xbfff => self.readExternal(address),
        else => 0xff,
    };
}

pub fn write(self: *Cartridge, address: u16, value: u8) void {
    switch (self.mapper) {
        .rom => if (address >= 0xa000 and address <= 0xbfff) self.writeRam(address, value),
        .mbc1 => self.writeMbc1(address, value),
        .mbc2 => self.writeMbc2(address, value),
        .mbc3 => self.writeMbc3(address, value),
        .mbc5 => self.writeMbc5(address, value),
    }
}

pub fn tick(self: *Cartridge, cycles: u32) void {
    if (!self.has_rtc or (self.rtc[4] & 0x40) != 0) return;
    self.rtc_cycles += cycles;
    while (self.rtc_cycles >= 4_194_304) {
        self.rtc_cycles -= 4_194_304;
        self.incrementRtc();
    }
}

pub fn saveData(self: *Cartridge) ?[]const u8 {
    if (!self.has_battery and !self.has_rtc) return null;
    @memcpy(self.save_cache[0..save_magic.len], save_magic);
    @memcpy(self.save_cache[save_magic.len..][0..5], &self.rtc);
    std.mem.writeInt(u64, self.save_cache[save_magic.len + 5 ..][0..8], self.rtc_cycles, .little);
    @memcpy(self.save_cache[save_header_size..], self.ram);
    return self.save_cache;
}

pub fn loadSaveData(self: *Cartridge, data: []const u8) !void {
    if (data.len != self.save_cache.len or !std.mem.eql(u8, data[0..save_magic.len], save_magic))
        return Error.InvalidSave;
    @memcpy(&self.rtc, data[save_magic.len..][0..5]);
    self.rtc_cycles = std.mem.readInt(u64, data[save_magic.len + 5 ..][0..8], .little);
    @memcpy(self.ram, data[save_header_size..]);
}

fn readExternal(self: *Cartridge, address: u16) u8 {
    if (!self.ram_enabled and self.mapper != .rom) return 0xff;
    if (self.mapper == .mbc3 and self.mbc3_select >= 0x08 and self.mbc3_select <= 0x0c)
        return self.rtc_latched[self.mbc3_select - 0x08];
    return self.readRam(address);
}

fn writeMbc1(self: *Cartridge, address: u16, value: u8) void {
    switch (address) {
        0x0000...0x1fff => self.ram_enabled = (value & 0x0f) == 0x0a,
        0x2000...0x3fff => {
            var bank: u16 = value & 0x1f;
            if (bank == 0) bank = 1;
            self.rom_bank = (self.rom_bank & 0x60) | bank;
        },
        0x4000...0x5fff => {
            self.mbc1_high = @truncate(value & 3);
            if (self.bank_mode == 0) self.rom_bank = (self.rom_bank & 0x1f) | (@as(u16, self.mbc1_high) << 5);
            self.ram_bank = if (self.bank_mode == 1) self.mbc1_high else 0;
        },
        0x6000...0x7fff => {
            self.bank_mode = @truncate(value & 1);
            self.rom_bank = (self.rom_bank & 0x1f) |
                (if (self.bank_mode == 0) @as(u16, self.mbc1_high) << 5 else 0);
            self.ram_bank = if (self.bank_mode == 1) self.mbc1_high else 0;
        },
        0xa000...0xbfff => self.writeRam(address, value),
        else => {},
    }
}

fn writeMbc2(self: *Cartridge, address: u16, value: u8) void {
    switch (address) {
        0x0000...0x3fff => {
            if ((address & 0x0100) == 0) {
                self.ram_enabled = (value & 0x0f) == 0x0a;
            } else {
                self.rom_bank = value & 0x0f;
                if (self.rom_bank == 0) self.rom_bank = 1;
            }
        },
        0xa000...0xbfff => {
            if (self.ram_enabled and self.ram.len != 0)
                self.ram[(address - 0xa000) & 0x01ff] = 0xf0 | (value & 0x0f);
        },
        else => {},
    }
}

fn writeMbc3(self: *Cartridge, address: u16, value: u8) void {
    switch (address) {
        0x0000...0x1fff => self.ram_enabled = (value & 0x0f) == 0x0a,
        0x2000...0x3fff => {
            self.rom_bank = value & 0x7f;
            if (self.rom_bank == 0) self.rom_bank = 1;
        },
        0x4000...0x5fff => {
            self.mbc3_select = value;
            self.ram_bank = value & 3;
        },
        0x6000...0x7fff => {
            const next: u1 = @truncate(value & 1);
            if (self.latch_last == 0 and next == 1) self.rtc_latched = self.rtc;
            self.latch_last = next;
        },
        0xa000...0xbfff => {
            if (!self.ram_enabled) return;
            if (self.mbc3_select >= 0x08 and self.mbc3_select <= 0x0c) {
                const index = self.mbc3_select - 0x08;
                self.rtc[index] = switch (index) {
                    0, 1 => value % 60,
                    2 => value % 24,
                    3 => value,
                    4 => value & 0xc1,
                    else => unreachable,
                };
            } else {
                self.writeRam(address, value);
            }
        },
        else => {},
    }
}

fn writeMbc5(self: *Cartridge, address: u16, value: u8) void {
    switch (address) {
        0x0000...0x1fff => self.ram_enabled = (value & 0x0f) == 0x0a,
        0x2000...0x2fff => self.rom_bank = (self.rom_bank & 0x100) | value,
        0x3000...0x3fff => self.rom_bank = (self.rom_bank & 0xff) | (@as(u16, value & 1) << 8),
        0x4000...0x5fff => {
            self.ram_bank = value & 0x0f;
            self.rumble_on = self.has_rumble and (value & 0x08) != 0;
            if (self.has_rumble) self.ram_bank &= 0x07;
        },
        0xa000...0xbfff => self.writeRam(address, value),
        else => {},
    }
}

fn readRam(self: *Cartridge, address: u16) u8 {
    if (self.ram.len == 0) return 0xff;
    const offset = (@as(usize, self.ram_bank) * 0x2000 + (address - 0xa000)) % self.ram.len;
    return self.ram[offset];
}

fn writeRam(self: *Cartridge, address: u16, value: u8) void {
    if (self.ram.len == 0) return;
    const offset = (@as(usize, self.ram_bank) * 0x2000 + (address - 0xa000)) % self.ram.len;
    self.ram[offset] = value;
}

fn fixedRomOffset(self: *const Cartridge, address: u16) usize {
    if (self.mapper == .mbc1 and self.bank_mode == 1)
        return @as(usize, self.mbc1_high) * 0x8000 + address;
    return address;
}

fn switchableRomOffset(self: *const Cartridge, address: u16) usize {
    return @as(usize, self.rom_bank) * 0x4000 + (address - 0x4000);
}

fn incrementRtc(self: *Cartridge) void {
    self.rtc[0] += 1;
    if (self.rtc[0] < 60) return;
    self.rtc[0] = 0;
    self.rtc[1] += 1;
    if (self.rtc[1] < 60) return;
    self.rtc[1] = 0;
    self.rtc[2] += 1;
    if (self.rtc[2] < 24) return;
    self.rtc[2] = 0;
    const day = (@as(u16, self.rtc[4] & 1) << 8) | self.rtc[3];
    const next = day + 1;
    self.rtc[3] = @truncate(next);
    self.rtc[4] = (self.rtc[4] & 0xfe) | @as(u8, @truncate((next >> 8) & 1));
    if (next > 511) self.rtc[4] |= 0x80;
}

const MapperInfo = struct {
    mapper: Mapper,
    battery: bool = false,
    rtc: bool = false,
    rumble: bool = false,
};

fn mapperFromType(value: u8) ?MapperInfo {
    return switch (value) {
        0x00, 0x08, 0x09 => .{ .mapper = .rom, .battery = value == 0x09 },
        0x01...0x03 => .{ .mapper = .mbc1, .battery = value == 0x03 },
        0x05, 0x06 => .{ .mapper = .mbc2, .battery = value == 0x06 },
        0x0f...0x13 => .{ .mapper = .mbc3, .battery = value == 0x0f or value == 0x10 or value == 0x13, .rtc = value == 0x0f or value == 0x10 },
        0x19...0x1e => .{ .mapper = .mbc5, .battery = value == 0x1b or value == 0x1e, .rumble = value >= 0x1c },
        else => null,
    };
}

fn romSize(code: u8) ?usize {
    return switch (code) {
        0x00...0x08 => @as(usize, 32 * 1024) << @intCast(code),
        0x52 => 72 * 16 * 1024,
        0x53 => 80 * 16 * 1024,
        0x54 => 96 * 16 * 1024,
        else => null,
    };
}

fn ramSize(code: u8, mapper: Mapper) usize {
    if (mapper == .mbc2) return 512;
    return switch (code) {
        0 => 0,
        1 => 2 * 1024,
        2 => 8 * 1024,
        3 => 32 * 1024,
        4 => 128 * 1024,
        5 => 64 * 1024,
        else => 0,
    };
}

test "MBC1 switches ROM and RAM banks" {
    const allocator = std.testing.allocator;
    var data = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(data);
    @memset(data, 0);
    data[0x143] = 0;
    data[0x147] = 0x03;
    data[0x148] = 1;
    data[0x149] = 3;
    data[0x4000] = 1;
    data[0x8000] = 2;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit();
    try std.testing.expectEqual(@as(u8, 1), cartridge.read(0x4000));
    cartridge.write(0x2000, 2);
    try std.testing.expectEqual(@as(u8, 2), cartridge.read(0x4000));
    cartridge.write(0x0000, 0x0a);
    cartridge.write(0xa000, 0x55);
    try std.testing.expectEqual(@as(u8, 0x55), cartridge.read(0xa000));
}

test "MBC1 mode changes update ROM and RAM bank selection" {
    const allocator = std.testing.allocator;
    var data = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(data);
    @memset(data, 0);
    data[0x147] = 0x03;
    data[0x148] = 6;
    data[0x149] = 3;

    var cartridge = try Cartridge.load(allocator, data);
    defer cartridge.deinit();
    cartridge.write(0x4000, 2);
    try std.testing.expectEqual(@as(u16, 65), cartridge.rom_bank);

    cartridge.write(0x6000, 1);
    try std.testing.expectEqual(@as(u16, 1), cartridge.rom_bank);
    try std.testing.expectEqual(@as(u8, 2), cartridge.ram_bank);

    cartridge.write(0x6000, 0);
    try std.testing.expectEqual(@as(u16, 65), cartridge.rom_bank);
    try std.testing.expectEqual(@as(u8, 0), cartridge.ram_bank);
}

test "unsupported specialty controllers are rejected" {
    var data = [_]u8{0} ** (32 * 1024);
    data[0x147] = 0x22;
    data[0x148] = 0;

    try std.testing.expectError(
        Error.UnsupportedCartridge,
        Cartridge.load(std.testing.allocator, &data),
    );
}

test "battery save container preserves RAM and RTC" {
    const allocator = std.testing.allocator;
    var data = [_]u8{0} ** (32 * 1024);
    data[0x147] = 0x10;
    data[0x148] = 0;
    data[0x149] = 2;

    var cartridge = try Cartridge.load(allocator, &data);
    defer cartridge.deinit();
    cartridge.ram[0] = 0x42;
    cartridge.rtc[0] = 17;
    const save = cartridge.saveData().?;

    cartridge.ram[0] = 0;
    cartridge.rtc[0] = 0;
    try cartridge.loadSaveData(save);
    try std.testing.expectEqual(@as(u8, 0x42), cartridge.ram[0]);
    try std.testing.expectEqual(@as(u8, 17), cartridge.rtc[0]);
}
