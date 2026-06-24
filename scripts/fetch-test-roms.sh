#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$root/test-data/game-boy-test-roms-7.0"
archive="$root/test-data/game-boy-test-roms-v7.0.zip"
expected_sha256="b9a9d7a1075aa35a3d07c07c34974048672d8520dca9e07a50178f5860c3832c"
sentinel="$destination/mooneye-test-suite/acceptance/bits/mem_oam.gb"

mkdir -p "$root/test-data"
if [ ! -f "$sentinel" ]; then
    rm -rf "$destination"
    if [ ! -f "$archive" ]; then
        curl -L --fail \
            "https://github.com/c-sp/game-boy-test-roms/releases/download/v7.0/game-boy-test-roms-v7.0.zip" \
            -o "$archive"
    fi
    actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        printf 'Checksum mismatch for %s\n' "$archive" >&2
        exit 1
    fi
    mkdir -p "$destination"
    unzip -q "$archive" -d "$destination"
fi

printf 'Test ROMs available at %s\n' "$destination"
