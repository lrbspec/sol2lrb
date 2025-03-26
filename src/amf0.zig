const std = @import("std");

pub const Type = AmfType;
pub const AmfType = enum(u8) {
    Number = 0,
    Bool = 1,
    String = 2,
    Object = 3,
    // MovieClip = 4,
    Null = 5,
    Undefined = 6,
    // Reference = 7,
    Array = 8,
    ObjectEnd = 9,
    // StrictArray = 10,
    // Date = 11,
    // LongString = 12,
    // Unsupported = 13,
    // RecordSet = 14,
    // Xml = 15,
    // TypedObject = 16,

    pub fn zigTypeOfValue(t: AmfType) type {
        return switch (t) {
            .Number => f64,
            .Bool => bool,
            .String => []u8,
            .Object => std.StringHashMap(AmfValue),
            .Null, .Undefined, .ObjectEnd => void,
            .Array => std.ArrayList(AmfValue),
        };
    }
};

pub const Number = AmfType.zigTypeOfValue(.Number);
pub const Bool = AmfType.zigTypeOfValue(.Bool);
pub const String = AmfType.zigTypeOfValue(.String);
pub const Object = AmfType.zigTypeOfValue(.Object);
pub const Array = AmfType.zigTypeOfValue(.Array);

pub const Value = AmfValue;
pub const AmfValue = struct {
    amf_type: AmfType,
    data: *anyopaque,
    name: []u8,
    alloc: std.mem.Allocator,

    pub fn expectAs(self: AmfValue, comptime t: AmfType) !AmfType.zigTypeOfValue(t) {
        if (self.amf_type != t) return error.TypeMismatch;
        return @as(*AmfType.zigTypeOfValue(t), @ptrCast(@alignCast(self.data))).*;
    }

    pub fn deinit(self: *@This()) void {
        switch (self.amf_type) {
            .Object => {
                var obj: *Object = @ptrCast(@alignCast(self.data));
                var iter = obj.valueIterator();
                while (iter.next()) |field_amf| {
                    deinit(field_amf);
                }
            },
            .Array => {
                const arr: *Array = @ptrCast(@alignCast(self.data));
                for (arr.items) |*item_amf| {
                    deinit(item_amf);
                }
            },
            .String => {
                const contents: *[]u8 = @as(*[]u8, @ptrCast(@alignCast(self.data)));
                self.alloc.free(contents.*);
            },
            .Bool => {
                self.alloc.destroy(@as(*bool, @ptrCast(self.data)));
            },
            .Number => {
                self.alloc.destroy(@as(*f64, @ptrCast(@alignCast(self.data))));
            },
            else => {},
        }
        self.alloc.free(self.name);
    }

    //pub fn readObjectFields(alloc: std.mem.Allocator, reader: anytype, object: *AmfValue) !void {
    //    if (object.amf_type != .Object) return error.PassedNonObject;
    //    const fields: *Object = @ptrCast(@alignCast(object.data));
    //    while (true) {
    //        const val = try read(alloc, reader, false);
    //        if (val.amf_type == .ObjectEnd) break;
    //        try fields.put(val.name, val);
    //    }
    //}

    //pub fn readArrayItems(alloc: std.mem.Allocator, reader: anytype, array: *AmfValue) !void {
    //    if (array.amf_type != .Array) return error.PassedNonArray;
    //    const items: *Array = @ptrCast(array.data);
    //    while (true) {
    //        const val = try read(alloc, reader, false);
    //        if (val.amf_type == .ObjectEnd) break;
    //        try items.append(alloc, val);
    //    }
    //}

    pub fn read(alloc: std.mem.Allocator, reader: anytype) !AmfValue {
        const name: []u8 = try alloc.alloc(u8, std.math.cast(usize, try reader.readInt(i16, .big)) orelse return error.CastError);
        _ = try reader.readAll(name);
        const amf_t = std.meta.intToEnum(AmfType, reader.readInt(u8, .big) catch return error.DoneReading) catch return error.UnimplementedAmfType;

        var result = AmfValue{ .name = name, .amf_type = amf_t, .alloc = alloc, .data = undefined };
        switch (amf_t) {
            .Number => {
                const ptr = try alloc.create(Number);
                ptr.* = @bitCast(try reader.readInt(u64, .big));
                result.data = @ptrCast(ptr);
            },
            .Bool => {
                const ptr = try alloc.create(Bool);
                ptr.* = try reader.readByte() != 0;
                result.data = @ptrCast(ptr);
            },
            .String => {
                const len = try reader.readInt(i16, .big);
                const ptr = try alloc.create(String);
                ptr.* = try alloc.alloc(u8, std.math.cast(usize, len) orelse return error.CastError);
                _ = try reader.readAll(ptr.*);
                result.data = @ptrCast(ptr);
            },
            .Object => {
                const ptr = try alloc.create(Object);
                ptr.* = Object.init(alloc);
                result.data = @ptrCast(ptr);
                //try readObjectFields(alloc, reader, &result);
                const fields: *Object = ptr;
                while (true) {
                    const val = try read(alloc, reader);
                    if (val.amf_type == .ObjectEnd) break;
                    try fields.put(val.name, val);
                }
            },
            .Null, .Undefined, .ObjectEnd => {},
            .Array => {
                const ptr = try alloc.create(Array);
                const len = try reader.readInt(i32, .big);
                ptr.* = try Array.initCapacity(alloc, std.math.cast(usize, len) orelse return error.CastError);
                result.data = @ptrCast(ptr);
                //try readArrayItems(alloc, reader, result);
                const items: *Array = ptr;
                while (true) {
                    const val = try read(alloc, reader);
                    if (val.amf_type == .ObjectEnd) break;
                    try items.append(val);
                }
            },
        }
        return result;
    }

    pub fn getProperty(self: AmfValue, name: []const u8) !AmfValue {
        if (self.amf_type != .Object) return error.PassedNonObject;
        const fields: *Object = @ptrCast(@alignCast(self.data));
        const prop: AmfValue = fields.get(name) orelse return error.NonexistantProperty;
        return prop;
    }

    pub fn getPropertyExpectType(self: AmfValue, name: []const u8, comptime expected_type: AmfType) !AmfType.zigTypeOfValue(expected_type) {
        const prop = try self.getProperty(name);
        if (prop.amf_type != expected_type) return error.TypeMismatch;
        const ptr: *AmfType.zigTypeOfValue(expected_type) = @ptrCast(@alignCast(prop.data));
        return ptr.*;
    }

    pub fn getItem(self: AmfValue, index: usize) !AmfValue {
        if (self.amf_type != .Array) return error.PassedNonArray;
        const arr: *Array = @ptrCast(@alignCast(self.data));
        if (index >= arr.items.len) return error.OutOfBounds;
        return arr.items[index];
    }

    pub fn getItemExpectType(self: AmfValue, index: usize, comptime expected_type: AmfType) !AmfType.zigTypeOfValue(expected_type) {
        const item = try self.getItem(index);
        if (item.amf_type != expected_type) return error.TypeMismatch;
        const ptr: *AmfType.zigTypeOfValue(expected_type) = @ptrCast(@alignCast(item.data));
        return ptr.*;
    }
};
