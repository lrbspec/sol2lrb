const std = @import("std");
const amf = @import("amf0.zig");

pub const Track = amf.Value;

pub fn readSol(alloc: std.mem.Allocator, reader: anytype) !amf.AmfValue {
    const sol_version = try reader.readInt(i16, .big);
    const length = try reader.readInt(i32, .big);
    _ = sol_version;
    _ = length;
    if (try reader.readInt(i32, .big) != 0x5443534F) return error.InvalidMagicNumber;
    try reader.skipBytes(6, .{});
    const name: []u8 = try alloc.alloc(u8, std.math.cast(usize, try reader.readInt(i16, .big)) orelse return error.CastError);
    _ = try reader.readAll(name);
    if (!std.mem.eql(u8, name, "savedLines")) return error.InvalidSolName;
    if (try reader.readInt(i32, .big) != 0) return error.InvalidAmfVersion;
    const ptr = try alloc.create(amf.Object);
    ptr.* = amf.Object.init(alloc);
    const amf_obj = amf.AmfValue{ .name = name, .alloc = alloc, .amf_type = .Object, .data = @ptrCast(ptr) };
    const fields: *amf.Object = ptr;
    while (true) {
        const val = amf.AmfValue.read(alloc, reader) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (val.amf_type == .ObjectEnd) break;
        try fields.put(val.name, val);
    }
    return amf_obj;
}

pub fn getTracks(root: amf.AmfValue) !amf.Array {
    return root.getPropertyExpectType("trackList", .Array);
}

pub const LineType = enum(u2) {
    Standard = 0,
    Acceleration = 1,
    Scenery = 2,
};

pub const Line = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    invert: bool,
    ID: u32,
    linetype: LineType,
    left_extended: bool,
    right_extended: bool,

    pub const Extension = packed struct(u2) {
        left: bool,
        right: bool,
    };

    pub fn fromAmf(line: amf.Value) !Line {
        //std.debug.print("line: {any} 5: {any} 0: {any}", .{ line.amf_type, (try line.getItem(4)).amf_type, (try line.getItem(0)).amf_type });
        const extensions: Extension = @bitCast(@as(u2, @intFromFloat(line.getItemExpectType(4, .Number) catch 0)));
        return Line{
            .x1 = try line.getItemExpectType(0, .Number),
            .y1 = try line.getItemExpectType(1, .Number),
            .x2 = try line.getItemExpectType(2, .Number),
            .y2 = try line.getItemExpectType(3, .Number),
            .invert = (line.getItemExpectType(5, .Number) catch 0) != 0,
            .left_extended = extensions.left,
            .right_extended = extensions.right,
            .ID = @as(u32, @intFromFloat(try line.getItemExpectType(8, .Number))),
            .linetype = @enumFromInt(@as(u2, @intFromFloat(try line.getItemExpectType(9, .Number)))),
        };
    }
};
