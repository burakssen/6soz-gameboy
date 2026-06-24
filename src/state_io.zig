const std = @import("std");

pub const Error = error{
    InvalidState,
    StateKindMismatch,
    UnsupportedStateVersion,
} || std.mem.Allocator.Error || std.Io.Writer.Error || std.Io.Reader.Error;

pub fn hashBytes(seed: u64, bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

pub fn writeValue(writer: *std.Io.Writer, value: anytype) Error!void {
    try writeTypedValue(writer, @TypeOf(value), value);
}

pub fn readValue(reader: *std.Io.Reader, comptime T: type) Error!T {
    return readTypedValue(reader, T);
}

pub fn readBytes(reader: *std.Io.Reader, len: usize) Error![]const u8 {
    return reader.take(len) catch |err| switch (err) {
        error.EndOfStream => Error.InvalidState,
        error.ReadFailed => Error.InvalidState,
    };
}

pub fn expectBytes(reader: *std.Io.Reader, expected: []const u8) Error!void {
    const actual = try readBytes(reader, expected.len);
    if (!std.mem.eql(u8, actual, expected)) return Error.InvalidState;
}

pub fn done(reader: *const std.Io.Reader) Error!void {
    if (reader.bufferedLen() != 0) return Error.InvalidState;
}

fn writeTypedValue(writer: *std.Io.Writer, comptime T: type, value: T) Error!void {
    switch (@typeInfo(T)) {
        .bool => try writer.writeByte(if (value) 1 else 0),
        .int => |info| try writeInt(writer, T, info, value),
        .float => |info| switch (info.bits) {
            32 => try writeIntAs(writer, u32, @bitCast(value)),
            64 => try writeIntAs(writer, u64, @bitCast(value)),
            else => @compileError("unsupported float size"),
        },
        .@"enum" => |info| try writeTypedValue(writer, info.tag_type, @intFromEnum(value)),
        .array => |info| {
            for (value) |item| try writeTypedValue(writer, info.child, item);
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                try writeTypedValue(writer, field.type, @field(value, field.name));
            }
        },
        .optional => |info| {
            if (@typeInfo(info.child) == .pointer) {
                if (value != null) return Error.InvalidState;
                try writeTypedValue(writer, bool, false);
            } else {
                if (value) |child| {
                    try writeTypedValue(writer, bool, true);
                    try writeTypedValue(writer, info.child, child);
                } else {
                    try writeTypedValue(writer, bool, false);
                }
            }
        },
        .pointer => @compileError("pointers are not valid state fields"),
        else => @compileError("unsupported state field: " ++ @typeName(T)),
    }
}

fn readTypedValue(reader: *std.Io.Reader, comptime T: type) Error!T {
    return switch (@typeInfo(T)) {
        .bool => blk: {
            const b = reader.takeByte() catch |err| switch (err) {
                error.EndOfStream => return Error.InvalidState,
                error.ReadFailed => return Error.InvalidState,
            };
            if (b > 1) return Error.InvalidState;
            break :blk b != 0;
        },
        .int => |info| try readInt(reader, T, info),
        .float => |info| switch (info.bits) {
            32 => @bitCast(try readIntAs(reader, u32)),
            64 => @bitCast(try readIntAs(reader, u64)),
            else => @compileError("unsupported float size"),
        },
        .@"enum" => |info| blk: {
            const tag = try readTypedValue(reader, info.tag_type);
            inline for (info.fields) |field| {
                if (tag == field.value) break :blk @as(T, @enumFromInt(tag));
            }
            return Error.InvalidState;
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*item| item.* = try readTypedValue(reader, info.child);
            break :blk result;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.fields) |field| {
                @field(result, field.name) = try readTypedValue(reader, field.type);
            }
            break :blk result;
        },
        .optional => |info| blk: {
            const present = try readTypedValue(reader, bool);
            if (@typeInfo(info.child) == .pointer) {
                if (present) return Error.InvalidState;
                break :blk null;
            }
            if (!present) break :blk null;
            break :blk try readTypedValue(reader, info.child);
        },
        .pointer => @compileError("pointers are not valid state fields"),
        else => @compileError("unsupported state field: " ++ @typeName(T)),
    };
}

fn writeInt(writer: *std.Io.Writer, comptime T: type, comptime info: std.builtin.Type.Int, value: T) Error!void {
    if (info.signedness == .unsigned) {
        if (info.bits <= 8) return writeIntAs(writer, u8, @intCast(value));
        if (info.bits <= 16) return writeIntAs(writer, u16, @intCast(value));
        if (info.bits <= 32) return writeIntAs(writer, u32, @intCast(value));
        if (info.bits <= 64) return writeIntAs(writer, u64, @intCast(value));
    } else {
        if (info.bits <= 8) return writeIntAs(writer, i8, @intCast(value));
        if (info.bits <= 16) return writeIntAs(writer, i16, @intCast(value));
        if (info.bits <= 32) return writeIntAs(writer, i32, @intCast(value));
        if (info.bits <= 64) return writeIntAs(writer, i64, @intCast(value));
    }
    @compileError("unsupported integer size: " ++ @typeName(T));
}

fn readInt(reader: *std.Io.Reader, comptime T: type, comptime info: std.builtin.Type.Int) Error!T {
    const raw = if (info.signedness == .unsigned and info.bits <= 8)
        try readIntAs(reader, u8)
    else if (info.signedness == .unsigned and info.bits <= 16)
        try readIntAs(reader, u16)
    else if (info.signedness == .unsigned and info.bits <= 32)
        try readIntAs(reader, u32)
    else if (info.signedness == .unsigned and info.bits <= 64)
        try readIntAs(reader, u64)
    else if (info.signedness == .signed and info.bits <= 8)
        try readIntAs(reader, i8)
    else if (info.signedness == .signed and info.bits <= 16)
        try readIntAs(reader, i16)
    else if (info.signedness == .signed and info.bits <= 32)
        try readIntAs(reader, i32)
    else if (info.signedness == .signed and info.bits <= 64)
        try readIntAs(reader, i64)
    else
        @compileError("unsupported integer size: " ++ @typeName(T));
    return std.math.cast(T, raw) orelse Error.InvalidState;
}

fn writeIntAs(writer: *std.Io.Writer, comptime T: type, value: T) Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try writer.writeAll(&buf);
}

fn readIntAs(reader: *std.Io.Reader, comptime T: type) Error!T {
    const bytes = try readBytes(reader, @sizeOf(T));
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}
