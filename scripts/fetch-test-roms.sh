#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination="$root/test-data/game-boy-test-roms-7.0"
archive="$root/test-data/game-boy-test-roms-v7.0.tar.gz"
expected_sha256="315ea38d4b6b21557e445cb1d9ac6ee426394e16c80f3c33b1cfd84cb40727f3"

mkdir -p "$root/test-data"
if [ ! -d "$destination" ]; then
    if [ ! -f "$archive" ]; then
        curl -L --fail \
            "https://github.com/c-sp/game-boy-test-roms/archive/refs/tags/v7.0.tar.gz" \
            -o "$archive"
    fi
    actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        printf 'Checksum mismatch for %s\n' "$archive" >&2
        exit 1
    fi
    tar -xzf "$archive" -C "$root/test-data"
fi

printf 'Test ROMs available at %s\n' "$destination"
