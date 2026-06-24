const std = @import("std");

const Ppu = @This();

pub const width = 160;
pub const height = 144;
pub const Framebuffer = [width * height]u32;

pub const Model = enum { dmg, cgb };

model: Model = .dmg,
vram: [2][0x2000]u8 = [_][0x2000]u8{[_]u8{0} ** 0x2000} ** 2,
oam: [160]u8 = [_]u8{0} ** 160,
framebuffer: Framebuffer = [_]u32{0xffffffff} ** (width * height),
lcdc: u8 = 0x91,
stat: u8 = 0x85,
scy: u8 = 0,
scx: u8 = 0,
ly: u8 = 0,
lyc: u8 = 0,
dma: u8 = 0,
bgp: u8 = 0xfc,
obp0: u8 = 0xff,
obp1: u8 = 0xff,
wy: u8 = 0,
wx: u8 = 0,
vbk: u8 = 0,
bgpi: u8 = 0,
obpi: u8 = 0,
bg_palette: [64]u8 = [_]u8{0} ** 64,
obj_palette: [64]u8 = [_]u8{0} ** 64,
dot: u16 = 0,
window_line: u8 = 0,
frame_complete: bool = false,
lcd_off_cycles: u32 = 0,

pub fn reset(self: *Ppu, model: Model) void {
    const vram = self.vram;
    const oam = self.oam;
    self.* = .{ .model = model, .vram = vram, .oam = oam };
    if (model == .cgb) {
        var i: usize = 0;
        while (i < 64) : (i += 2) {
            self.bg_palette[i] = 0xff;
            self.bg_palette[i + 1] = 0x7f;
            self.obj_palette[i] = 0xff;
            self.obj_palette[i + 1] = 0x7f;
        }
    }
}

pub fn tick(self: *Ppu, cycles: u32, interrupt_flags: *u8) void {
    if ((self.lcdc & 0x80) == 0) {
        self.ly = 0;
        self.dot = 0;
        self.stat = (self.stat & 0xfc) | 0;
        self.lcd_off_cycles += cycles;
        if (self.lcd_off_cycles >= 70224) {
            self.lcd_off_cycles -= 70224;
            self.frame_complete = true;
        }
        return;
    }
    self.lcd_off_cycles = 0;

    var remaining = cycles;
    while (remaining > 0) : (remaining -= 1) {
        const old_mode = self.mode();
        self.dot += 1;
        if (self.dot >= 456) {
            self.dot = 0;
            self.ly +%= 1;
            if (self.ly == 144) {
                interrupt_flags.* |= 0x01;
                self.frame_complete = true;
                if ((self.stat & 0x10) != 0) interrupt_flags.* |= 0x02;
            } else if (self.ly > 153) {
                self.ly = 0;
                self.window_line = 0;
            }
            self.updateCoincidence(interrupt_flags);
        }

        const new_mode = self.mode();
        self.stat = (self.stat & 0xfc) | new_mode;
        if (old_mode != new_mode) {
            if (old_mode == 3 and new_mode == 0 and self.ly < 144) self.renderScanline();
            const mask: u8 = switch (new_mode) {
                0 => 0x08,
                1 => 0x10,
                2 => 0x20,
                else => 0,
            };
            if (mask != 0 and (self.stat & mask) != 0) interrupt_flags.* |= 0x02;
        }
    }
}

pub fn takeFrameComplete(self: *Ppu) bool {
    const value = self.frame_complete;
    self.frame_complete = false;
    return value;
}

pub fn mode(self: *const Ppu) u2 {
    if (self.ly >= 144) return 1;
    if (self.dot < 80) return 2;
    if (self.dot < 252) return 3;
    return 0;
}

pub fn cpuCanAccessVram(self: *const Ppu) bool {
    return (self.lcdc & 0x80) == 0 or self.mode() != 3;
}

pub fn cpuCanAccessOam(self: *const Ppu) bool {
    const current = self.mode();
    return (self.lcdc & 0x80) == 0 or (current != 2 and current != 3);
}

pub fn readRegister(self: *const Ppu, address: u16) u8 {
    return switch (address) {
        0xff40 => self.lcdc,
        0xff41 => self.stat | 0x80,
        0xff42 => self.scy,
        0xff43 => self.scx,
        0xff44 => self.ly,
        0xff45 => self.lyc,
        0xff46 => self.dma,
        0xff47 => self.bgp,
        0xff48 => self.obp0,
        0xff49 => self.obp1,
        0xff4a => self.wy,
        0xff4b => self.wx,
        0xff4f => if (self.model == .cgb) 0xfe | self.vbk else 0xff,
        0xff68 => if (self.model == .cgb) 0x40 | self.bgpi else 0xff,
        0xff69 => if (self.model == .cgb) (if (self.cpuCanAccessVram()) self.bg_palette[self.bgpi & 0x3f] else 0xff) else 0xff,
        0xff6a => if (self.model == .cgb) 0x40 | self.obpi else 0xff,
        0xff6b => if (self.model == .cgb) (if (self.cpuCanAccessVram()) self.obj_palette[self.obpi & 0x3f] else 0xff) else 0xff,
        else => 0xff,
    };
}

pub fn writeRegister(self: *Ppu, address: u16, value: u8, interrupt_flags: *u8) void {
    switch (address) {
        0xff40 => {
            const was_enabled = (self.lcdc & 0x80) != 0;
            self.lcdc = value;
            if (was_enabled and (value & 0x80) == 0) {
                self.ly = 0;
                self.dot = 0;
                self.window_line = 0;
                self.stat = (self.stat & 0xfc) | 0;
            }
        },
        0xff41 => self.stat = (self.stat & 0x07) | (value & 0x78) | 0x80,
        0xff42 => self.scy = value,
        0xff43 => self.scx = value,
        0xff44 => {},
        0xff45 => {
            self.lyc = value;
            self.updateCoincidence(interrupt_flags);
        },
        0xff46 => self.dma = value,
        0xff47 => self.bgp = value,
        0xff48 => self.obp0 = value,
        0xff49 => self.obp1 = value,
        0xff4a => self.wy = value,
        0xff4b => self.wx = value,
        0xff4f => {
            if (self.model == .cgb) self.vbk = value & 1;
        },
        0xff68 => {
            if (self.model == .cgb) self.bgpi = value & 0xbf;
        },
        0xff69 => {
            if (self.model == .cgb and self.cpuCanAccessVram()) {
                self.bg_palette[self.bgpi & 0x3f] = value;
                if ((self.bgpi & 0x80) != 0) self.bgpi = 0x80 | ((self.bgpi + 1) & 0x3f);
            }
        },
        0xff6a => {
            if (self.model == .cgb) self.obpi = value & 0xbf;
        },
        0xff6b => {
            if (self.model == .cgb and self.cpuCanAccessVram()) {
                self.obj_palette[self.obpi & 0x3f] = value;
                if ((self.obpi & 0x80) != 0) self.obpi = 0x80 | ((self.obpi + 1) & 0x3f);
            }
        },
        else => {},
    }
}

fn updateCoincidence(self: *Ppu, interrupt_flags: *u8) void {
    const was_equal = (self.stat & 0x04) != 0;
    const equal = self.ly == self.lyc;
    if (equal) self.stat |= 0x04 else self.stat &= ~@as(u8, 0x04);
    if (!was_equal and equal and (self.stat & 0x40) != 0) interrupt_flags.* |= 0x02;
}

fn renderScanline(self: *Ppu) void {
    if (self.ly >= height) return;
    var bg_color_ids: [width]u2 = [_]u2{0} ** width;
    var bg_priorities: [width]bool = [_]bool{false} ** width;
    const bg_enabled = (self.lcdc & 0x01) != 0 or self.model == .cgb;
    const window_enabled = bg_enabled and (self.lcdc & 0x20) != 0 and self.ly >= self.wy and self.wx <= 166;
    var used_window = false;

    var screen_x: usize = 0;
    while (screen_x < width) : (screen_x += 1) {
        const window_x = @as(i16, @intCast(screen_x)) - (@as(i16, self.wx) - 7);
        const use_window = window_enabled and window_x >= 0;
        used_window = used_window or use_window;
        const pixel_x: u8 = if (use_window) @truncate(@as(u16, @intCast(window_x))) else self.scx +% @as(u8, @truncate(screen_x));
        const pixel_y: u8 = if (use_window) self.window_line else self.scy +% self.ly;
        const map_base: usize = if (use_window)
            (if ((self.lcdc & 0x40) != 0) 0x1c00 else 0x1800)
        else
            (if ((self.lcdc & 0x08) != 0) 0x1c00 else 0x1800);
        const map_index = map_base + @as(usize, pixel_y / 8) * 32 + pixel_x / 8;
        const tile_number = self.vram[0][map_index];
        const attributes = if (self.model == .cgb) self.vram[1][map_index] else 0;
        const tile_bank: usize = if ((attributes & 0x08) != 0) 1 else 0;
        const tile_address: usize = if ((self.lcdc & 0x10) != 0)
            @as(usize, tile_number) * 16
        else
            @as(usize, @intCast(@as(i16, 0x1000) + @as(i16, @as(i8, @bitCast(tile_number))) * 16));
        var tile_x: u3 = @truncate(pixel_x & 7);
        var tile_y: u3 = @truncate(pixel_y & 7);
        if ((attributes & 0x20) != 0) tile_x = 7 - tile_x;
        if ((attributes & 0x40) != 0) tile_y = 7 - tile_y;
        const low = self.vram[tile_bank][tile_address + @as(usize, tile_y) * 2];
        const high = self.vram[tile_bank][tile_address + @as(usize, tile_y) * 2 + 1];
        const bit: u3 = 7 - tile_x;
        const color_id: u2 = @truncate(((high >> bit) & 1) << 1 | ((low >> bit) & 1));
        bg_color_ids[screen_x] = if (bg_enabled) color_id else 0;
        bg_priorities[screen_x] = (attributes & 0x80) != 0;
        self.framebuffer[@as(usize, self.ly) * width + screen_x] = self.backgroundColor(color_id, attributes & 7);
    }
    if (used_window) self.window_line +%= 1;
    if ((self.lcdc & 0x02) != 0) self.renderSprites(&bg_color_ids, &bg_priorities);
}

fn renderSprites(self: *Ppu, bg_ids: *const [width]u2, bg_priorities: *const [width]bool) void {
    const sprite_height: i16 = if ((self.lcdc & 0x04) != 0) 16 else 8;
    var visible: [10]u8 = undefined;
    var count: usize = 0;
    var index: usize = 0;
    while (index < 40 and count < visible.len) : (index += 1) {
        const y = @as(i16, self.oam[index * 4]) - 16;
        if (@as(i16, self.ly) >= y and @as(i16, self.ly) < y + sprite_height) {
            visible[count] = @intCast(index);
            count += 1;
        }
    }
    if (self.model == .dmg) {
        std.mem.sort(u8, visible[0..count], self, struct {
            fn lessThan(ppu: *Ppu, left: u8, right: u8) bool {
                const lx = ppu.oam[@as(usize, left) * 4 + 1];
                const rx = ppu.oam[@as(usize, right) * 4 + 1];
                return lx > rx or (lx == rx and left > right);
            }
        }.lessThan);
    }

    for (visible[0..count]) |sprite_index| {
        const base = @as(usize, sprite_index) * 4;
        const sprite_y = @as(i16, self.oam[base]) - 16;
        const sprite_x = @as(i16, self.oam[base + 1]) - 8;
        var tile = self.oam[base + 2];
        const flags = self.oam[base + 3];
        var row: u8 = @intCast(@as(i16, self.ly) - sprite_y);
        if ((flags & 0x40) != 0) row = @intCast(sprite_height - 1 - row);
        if (sprite_height == 16) tile &= 0xfe;
        const bank: usize = if (self.model == .cgb and (flags & 0x08) != 0) 1 else 0;
        const tile_address = @as(usize, tile) * 16 + @as(usize, row) * 2;
        const low = self.vram[bank][tile_address];
        const high = self.vram[bank][tile_address + 1];

        var pixel: u8 = 0;
        while (pixel < 8) : (pixel += 1) {
            const x = sprite_x + pixel;
            if (x < 0 or x >= width) continue;
            const source_x: u3 = if ((flags & 0x20) != 0) @truncate(pixel) else @truncate(7 - pixel);
            const color_id: u2 = @truncate(((high >> source_x) & 1) << 1 | ((low >> source_x) & 1));
            if (color_id == 0) continue;
            const screen_x: usize = @intCast(x);
            const behind_bg = (flags & 0x80) != 0;
            if ((self.model == .cgb and bg_priorities[screen_x] and bg_ids[screen_x] != 0) or
                (behind_bg and bg_ids[screen_x] != 0)) continue;
            self.framebuffer[@as(usize, self.ly) * width + screen_x] = self.spriteColor(color_id, flags);
        }
    }
}

fn backgroundColor(self: *const Ppu, color_id: u2, palette: u8) u32 {
    if (self.model == .cgb) return cgbColor(&self.bg_palette, palette, color_id);
    return dmgColor((self.bgp >> (@as(u3, color_id) * 2)) & 3);
}

fn spriteColor(self: *const Ppu, color_id: u2, flags: u8) u32 {
    if (self.model == .cgb) return cgbColor(&self.obj_palette, flags & 7, color_id);
    const palette = if ((flags & 0x10) != 0) self.obp1 else self.obp0;
    return dmgColor((palette >> (@as(u3, color_id) * 2)) & 3);
}

fn dmgColor(shade: u8) u32 {
    return switch (shade & 3) {
        0 => 0xe0f8d0,
        1 => 0x88c070,
        2 => 0x346856,
        3 => 0x081820,
        else => unreachable,
    };
}

fn cgbColor(data: *const [64]u8, palette: u8, color_id: u2) u32 {
    const offset = @as(usize, palette & 7) * 8 + @as(usize, color_id) * 2;
    const raw = @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
    const r = @as(u32, raw & 0x1f) * 255 / 31;
    const g = @as(u32, (raw >> 5) & 0x1f) * 255 / 31;
    const b = @as(u32, (raw >> 10) & 0x1f) * 255 / 31;
    return (r << 16) | (g << 8) | b;
}

test "PPU enters vblank and renders a frame" {
    var ppu = Ppu{};
    var interrupts: u8 = 0;
    ppu.tick(456 * 144, &interrupts);

    try std.testing.expectEqual(@as(u8, 144), ppu.ly);
    try std.testing.expect((interrupts & 1) != 0);
    try std.testing.expect(ppu.takeFrameComplete());
}

test "CGB palette data converts to RGB" {
    var ppu = Ppu{ .model = .cgb };
    ppu.bg_palette[0] = 0x1f;
    ppu.bg_palette[1] = 0;
    try std.testing.expectEqual(@as(u32, 0xff0000), ppu.backgroundColor(0, 0));
}

test "CGB palette register access rules and auto-increment quirks" {
    var ppu = Ppu{ .model = .cgb };
    var interrupts: u8 = 0;

    // Default: LCD is off (lcdc bit 7 is 0), so CPU can access VRAM / palettes
    ppu.lcdc = 0;
    try std.testing.expect(ppu.cpuCanAccessVram());

    // 1. Check index reads have bit 6 masked as 1
    // Initial value is 0, so read should return 0x40.
    try std.testing.expectEqual(@as(u8, 0x40), ppu.readRegister(0xff68));
    try std.testing.expectEqual(@as(u8, 0x40), ppu.readRegister(0xff6a));

    // Write to bgpi setting auto-increment (0x80) and index 5 (and try setting bit 6, which should be ignored)
    ppu.writeRegister(0xff68, 0xc5, &interrupts); // 0xc5 = 0x80 (auto-increment) | 0x40 (ignored) | 0x05
    // Reading back should return 0x80 | 0x40 | 0x05 = 0xc5
    try std.testing.expectEqual(@as(u8, 0xc5), ppu.readRegister(0xff68));

    // Write palette data (should write to index 5 and auto-increment index to 6)
    ppu.writeRegister(0xff69, 0x5a, &interrupts);
    try std.testing.expectEqual(@as(u8, 0x5a), ppu.bg_palette[5]);
    try std.testing.expectEqual(@as(u8, 0xc6), ppu.readRegister(0xff68)); // auto-incremented to 6

    // 2. Mock LCD turned on, Mode 3 (dot >= 80 and dot < 252)
    ppu.lcdc = 0x80;
    ppu.ly = 10;
    ppu.dot = 100; // mode 3
    try std.testing.expect(!ppu.cpuCanAccessVram());

    // Reads during mode 3 should return 0xff
    try std.testing.expectEqual(@as(u8, 0xff), ppu.readRegister(0xff69));

    // Writes during mode 3 should be ignored (no write and no auto-increment)
    ppu.writeRegister(0xff69, 0xa5, &interrupts);
    try std.testing.expectEqual(@as(u8, 0x5a), ppu.bg_palette[5]); // unmodified
    try std.testing.expectEqual(@as(u8, 0xc6), ppu.readRegister(0xff68)); // no auto-increment

    // 3. Mock LCD turned on, Mode 1 VBlank (ly >= 144)
    ppu.ly = 145;
    try std.testing.expect(ppu.cpuCanAccessVram());

    // Reads and writes during VBlank should work normally
    try std.testing.expectEqual(@as(u8, 0), ppu.readRegister(0xff69)); // index 6 is unwritten (0)
    ppu.writeRegister(0xff69, 0x3c, &interrupts);
    try std.testing.expectEqual(@as(u8, 0x3c), ppu.bg_palette[6]);
    try std.testing.expectEqual(@as(u8, 0xc7), ppu.readRegister(0xff68)); // auto-incremented to 7
}
