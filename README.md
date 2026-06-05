# 6soz-gameboy

A decoupled Game Boy (DMG) and Game Boy Color (CGB) emulator core written in Zig.

## Features

The repository provides [LR35902](https://github.com/burakssen/6soz-lr35902) integration, DMG/CGB memory maps, boot ROM execution, timers, interrupts, serial loopback, joypad input, DMA, CGB banking, video (PPU), audio (APU), battery/RTC persistence, and cartridge controllers.

Supported controller families are ROM-only, MBC1, MBC2, MBC3, and MBC5. Other controller types are rejected rather than approximated with incompatible banking behavior.

## Usage

The core is designed to be host-agnostic and does not include rendering or audio playback logic. A typical host loop follows this pattern:

```zig
const GameBoy = @import("gameboy").GameBoy;

var gb = GameBoy.init(allocator);
defer gb.deinit();

try gb.load(rom_bytes);
try gb.loadBootRom(boot_rom_bytes);
try gb.reset();

while (true) {
    const result = try gb.stepFrame();
    // Use gb.framebuffer() to get 160x144 pixels
    // Use result.audio for the frame's audio samples
}
```

The emulator requires a legally obtained DMG or CGB boot ROM for proper initialization.

## Build

```sh
zig build
zig build test
```

Fetch the pinned external conformance-ROM collection with:

```sh
./scripts/fetch-test-roms.sh
```

Run a Mooneye-compatible ROM headlessly with:

```sh
zig build test-rom -- path/to/test.gb path/to/boot.bin
```

