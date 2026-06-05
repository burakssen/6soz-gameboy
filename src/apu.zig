const std = @import("std");

const Apu = @This();

pub const sample_rate = 48_000;
const cpu_rate = 4_194_304;
const max_samples = 4096;

registers: [0x30]u8 = [_]u8{0} ** 0x30,
wave_ram: [16]u8 = [_]u8{0} ** 16,
enabled: bool = true,
sample_accumulator: u64 = 0,
frame_accumulator: u32 = 0,
frame_step: u3 = 0,
phase: [4]u32 = [_]u32{0} ** 4,
length: [4]u16 = [_]u16{0} ** 4,
volume: [4]u4 = [_]u4{0} ** 4,
envelope_counter: [3]u8 = [_]u8{0} ** 3,
noise_lfsr: u15 = 0x7fff,
samples: [max_samples]f32 = [_]f32{0} ** max_samples,
sample_count: usize = 0,

pub fn reset(self: *Apu) void {
    self.* = .{};
    self.enabled = true;
    self.registers[0x16] = 0xf1;
    self.registers[0x14] = 0x77;
    self.registers[0x15] = 0xf3;
}

pub fn read(self: *const Apu, address: u16) u8 {
    if (address >= 0xff30 and address <= 0xff3f) return self.wave_ram[address - 0xff30];
    if (address < 0xff10 or address > 0xff26) return 0xff;
    const index = address - 0xff10;
    if (address == 0xff26) {
        var status: u8 = if (self.enabled) 0x80 else 0;
        for (0..4) |channel| {
            if (self.channelActive(channel)) status |= @as(u8, 1) << @intCast(channel);
        }
        return status | 0x70;
    }
    const masks = [_]u8{
        0x80, 0x3f, 0x00, 0xff, 0xbf,
        0xff, 0x3f, 0x00, 0xff, 0xbf,
        0x7f, 0xff, 0x9f, 0xff, 0xbf,
        0xff, 0xff, 0x00, 0x00, 0xbf,
        0x00, 0x00,
    };
    return self.registers[index] | masks[index];
}

pub fn write(self: *Apu, address: u16, value: u8) void {
    if (address >= 0xff30 and address <= 0xff3f) {
        self.wave_ram[address - 0xff30] = value;
        return;
    }
    if (address < 0xff10 or address > 0xff26) return;
    if (address == 0xff26) {
        self.enabled = (value & 0x80) != 0;
        if (!self.enabled) {
            @memset(self.registers[0..0x16], 0);
            self.length = .{ 0, 0, 0, 0 };
        }
        self.registers[0x16] = value & 0x80;
        return;
    }
    if (!self.enabled and address < 0xff24) return;
    const index = address - 0xff10;
    self.registers[index] = value;
    switch (address) {
        0xff11 => self.length[0] = 64 - (value & 0x3f),
        0xff16 => self.length[1] = 64 - (value & 0x3f),
        0xff1b => self.length[2] = 256 - @as(u16, value),
        0xff20 => self.length[3] = 64 - (value & 0x3f),
        0xff14 => if ((value & 0x80) != 0) self.trigger(0),
        0xff19 => if ((value & 0x80) != 0) self.trigger(1),
        0xff1e => if ((value & 0x80) != 0) self.trigger(2),
        0xff23 => if ((value & 0x80) != 0) self.trigger(3),
        else => {},
    }
}

pub fn tick(self: *Apu, cycles: u32) []const f32 {
    self.sample_count = 0;
    if (!self.enabled) return self.samples[0..0];

    self.clockFrameSequencer(cycles);
    self.sample_accumulator += @as(u64, cycles) * sample_rate;
    while (self.sample_accumulator >= cpu_rate and self.sample_count < self.samples.len) {
        self.sample_accumulator -= cpu_rate;
        self.samples[self.sample_count] = self.mixSample();
        self.sample_count += 1;
    }
    return self.samples[0..self.sample_count];
}

fn clockFrameSequencer(self: *Apu, cycles: u32) void {
    self.frame_accumulator += cycles;
    while (self.frame_accumulator >= 8192) {
        self.frame_accumulator -= 8192;
        if ((self.frame_step & 1) == 0) self.clockLengths();
        if (self.frame_step == 7) self.clockEnvelopes();
        self.frame_step +%= 1;
    }
}

fn clockLengths(self: *Apu) void {
    const controls = [_]u8{ self.registers[4], self.registers[9], self.registers[14], self.registers[19] };
    for (0..4) |channel| {
        if ((controls[channel] & 0x40) != 0 and self.length[channel] > 0) self.length[channel] -= 1;
    }
}

fn clockEnvelopes(self: *Apu) void {
    const envelope_regs = [_]u8{ self.registers[2], self.registers[7], self.registers[18] };
    const channels = [_]usize{ 0, 1, 3 };
    for (channels, 0..) |channel, envelope_index| {
        const period = envelope_regs[envelope_index] & 7;
        if (period == 0) continue;
        self.envelope_counter[envelope_index] += 1;
        if (self.envelope_counter[envelope_index] < period) continue;
        self.envelope_counter[envelope_index] = 0;
        const increase = (envelope_regs[envelope_index] & 0x08) != 0;
        if (increase and self.volume[channel] < 15) self.volume[channel] += 1;
        if (!increase and self.volume[channel] > 0) self.volume[channel] -= 1;
    }
}

fn trigger(self: *Apu, channel: usize) void {
    if (self.length[channel] == 0) self.length[channel] = if (channel == 2) 256 else 64;
    if (channel == 0) self.volume[0] = @truncate(self.registers[2] >> 4);
    if (channel == 1) self.volume[1] = @truncate(self.registers[7] >> 4);
    if (channel == 3) {
        self.volume[3] = @truncate(self.registers[18] >> 4);
        self.noise_lfsr = 0x7fff;
    }
    self.phase[channel] = 0;
}

fn channelActive(self: *const Apu, channel: usize) bool {
    if (self.length[channel] == 0) return false;
    return switch (channel) {
        0 => (self.registers[2] & 0xf8) != 0,
        1 => (self.registers[7] & 0xf8) != 0,
        2 => (self.registers[10] & 0x80) != 0,
        3 => (self.registers[18] & 0xf8) != 0,
        else => false,
    };
}

fn mixSample(self: *Apu) f32 {
    var channels = [_]f32{ 0, 0, 0, 0 };
    channels[0] = self.squareSample(0, self.registers[1], self.registers[3], self.registers[4]);
    channels[1] = self.squareSample(1, self.registers[6], self.registers[8], self.registers[9]);
    channels[2] = self.waveSample();
    channels[3] = self.noiseSample();

    const routing = self.registers[0x15];
    const volume_control = self.registers[0x14];
    var left: f32 = 0;
    var right: f32 = 0;
    for (channels, 0..) |sample, channel| {
        if ((routing & (@as(u8, 1) << @intCast(channel))) != 0) right += sample;
        if ((routing & (@as(u8, 0x10) << @intCast(channel))) != 0) left += sample;
    }
    left *= @as(f32, @floatFromInt(((volume_control >> 4) & 7) + 1)) / 8.0;
    right *= @as(f32, @floatFromInt((volume_control & 7) + 1)) / 8.0;
    return std.math.clamp((left + right) / 8.0, -1.0, 1.0);
}

fn squareSample(self: *Apu, channel: usize, duty_reg: u8, low: u8, high: u8) f32 {
    if (!self.channelActive(channel)) return 0;
    const frequency = @as(u16, low) | (@as(u16, high & 7) << 8);
    const period = @max(1, 2048 - frequency);
    _ = self.advancePhase(channel, phaseIncrement(131_072, period));
    const step: u3 = @truncate(self.phase[channel] >> 29);
    const patterns = [_]u8{ 0x01, 0x81, 0x87, 0x7e };
    const high_sample = ((patterns[(duty_reg >> 6) & 3] >> step) & 1) != 0;
    const amplitude = @as(f32, @floatFromInt(self.volume[channel])) / 15.0;
    return if (high_sample) amplitude else -amplitude;
}

fn waveSample(self: *Apu) f32 {
    if (!self.channelActive(2)) return 0;
    const frequency = @as(u16, self.registers[13]) | (@as(u16, self.registers[14] & 7) << 8);
    const period = @max(1, 2048 - frequency);
    _ = self.advancePhase(2, phaseIncrement(65_536, period));
    const position: u5 = @truncate(self.phase[2] >> 27);
    const wave_byte = self.wave_ram[position / 2];
    var sample: u4 = if ((position & 1) == 0) @truncate(wave_byte >> 4) else @truncate(wave_byte);
    const volume_code = (self.registers[12] >> 5) & 3;
    if (volume_code == 0) return 0;
    sample >>= switch (volume_code) {
        1 => 0,
        2 => 1,
        3 => 2,
        else => unreachable,
    };
    return @as(f32, @floatFromInt(sample)) / 7.5 - 1.0;
}

fn noiseSample(self: *Apu) f32 {
    if (!self.channelActive(3)) return 0;
    const polynomial = self.registers[19 - 2];
    const divisor_codes = [_]u16{ 8, 16, 32, 48, 64, 80, 96, 112 };
    const divisor = divisor_codes[polynomial & 7] << @intCast(polynomial >> 4);
    const wraps = self.advancePhase(3, phaseIncrement(cpu_rate, @max(1, divisor)));
    var clocks: u64 = 0;
    while (clocks < wraps) : (clocks += 1) {
        const bit = (self.noise_lfsr ^ (self.noise_lfsr >> 1)) & 1;
        self.noise_lfsr = (self.noise_lfsr >> 1) | (@as(u15, bit) << 14);
        if ((polynomial & 0x08) != 0) self.noise_lfsr = (self.noise_lfsr & ~@as(u15, 0x40)) | (@as(u15, bit) << 6);
    }
    const amplitude = @as(f32, @floatFromInt(self.volume[3])) / 15.0;
    return if ((self.noise_lfsr & 1) == 0) amplitude else -amplitude;
}

fn phaseIncrement(clock: u32, period: u16) u64 {
    return (@as(u64, clock) << 32) / (@as(u64, period) * sample_rate);
}

fn advancePhase(self: *Apu, channel: usize, increment: u64) u64 {
    const total = @as(u64, self.phase[channel]) + increment;
    self.phase[channel] = @truncate(total);
    return total >> 32;
}

test "APU produces samples after channel trigger" {
    var apu = Apu{};
    apu.reset();
    apu.write(0xff12, 0xf3);
    apu.write(0xff11, 0x80);
    apu.write(0xff13, 0x00);
    apu.write(0xff14, 0x87);
    const samples = apu.tick(100_000);
    try std.testing.expect(samples.len > 0);
}

test "maximum channel frequencies do not overflow phase conversion" {
    var apu = Apu{};
    apu.reset();

    apu.write(0xff12, 0xf3);
    apu.write(0xff11, 0x80);
    apu.write(0xff13, 0xff);
    apu.write(0xff14, 0x87);

    apu.write(0xff1a, 0x80);
    apu.write(0xff1c, 0x20);
    apu.write(0xff1d, 0xff);
    apu.write(0xff1e, 0x87);

    apu.write(0xff21, 0xf3);
    apu.write(0xff22, 0x00);
    apu.write(0xff23, 0x80);

    const samples = apu.tick(100_000);
    try std.testing.expect(samples.len > 0);
}
