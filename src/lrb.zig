const std = @import("std");
const sol = @import("sol.zig");
const amf = @import("amf0.zig");

pub const modflags = packed struct(u8) {
    required: bool = false,
    physics: bool = false,
    camera: bool = false,
    scenery: bool = false,
    extra_data: bool = false,
    padding: u3 = 0,
};

pub const MAGIC_NUM: [3]u8 = [_]u8{ 0x4c, 0x52, 0x42 };

pub const LRB_VERSION: u8 = 0;

const BytesUnmanaged = std.ArrayListUnmanaged(u8);
const Bytes = std.ArrayList(u8);

pub const modtable_entry = struct {
    name: []const u8,
    version: u16,
    data: ?[]const u8 = null,
    flags: modflags = modflags{},
    data_segment_position: ?u64 = null,
    alloc: std.mem.Allocator,

    pub fn labelEntry(track: sol.Track, alloc: std.mem.Allocator) ?modtable_entry {
        const label_full = track.getPropertyExpectType("label", .String) catch return null;
        const label = label_full[0..@min(label_full.len, std.math.maxInt(u16))];
        const data: []u8 = alloc.alloc(u8, label.len + 2) catch return null;
        var list: BytesUnmanaged = BytesUnmanaged.initBuffer(data);
        const writer = list.fixedWriter();
        writer.writeInt(u16, std.math.cast(u16, label.len) orelse return null, .little) catch return null;
        writer.writeAll(label) catch return null;

        return modtable_entry{
            .name = "base.label",
            .version = 0,
            .data = data,
            .flags = modflags{ .extra_data = true },
            .alloc = alloc,
        };
    }

    // can be omitted to specify 6.2, but for the sake of accurately representing the .sol lets just write it anyways
    pub fn gridVersionEntry(track: sol.Track, alloc: std.mem.Allocator) ?modtable_entry {
        const version_string = track.getPropertyExpectType("version", .String) catch return null;
        var version: u8 = 0;
        if (std.mem.eql(u8, version_string, "6.1")) {
            version = 1;
        }
        if (std.mem.eql(u8, version_string, "6.0")) {
            version = 2;
        }
        const data: []u8 = alloc.alloc(u8, 1) catch return null;
        data[0] = version;
        return modtable_entry{
            .name = "base.gridver",
            .version = 0,
            .data = data,
            .flags = modflags{ .extra_data = true, .physics = true },
            .alloc = alloc,
        };
    }

    // returns either a startline or startoffset
    pub fn startEntry(track: sol.Track, alloc: std.mem.Allocator) !modtable_entry {
        const prop = try track.getProperty("startLine");
        if (prop.amf_type == .Number) {
            const ID: u32 = std.math.cast(u32, @as(u32, @intFromFloat(@as(*f64, @ptrCast(@alignCast(prop.data))).*))) orelse return error.CastError;

            var maybe_line: ?amf.AmfValue = null;
            const lines: amf.Array = try track.getPropertyExpectType("data", .Array);

            for (lines.items) |iter_line| {
                const iter_ID: u32 = std.math.cast(u32, @as(u32, @intFromFloat(try iter_line.getItemExpectType(8, .Number)))) orelse return error.CastError;
                if (iter_ID == ID) {
                    maybe_line = iter_line;
                    break;
                }
            }

            if (maybe_line) |line| {
                const data: []u8 = try alloc.alloc(u8, 4);
                @memcpy(data, &@as([4]u8, @bitCast(@as(u32, @intFromFloat(try line.getItemExpectType(8, .Number))))));
                return modtable_entry{
                    .name = "base.startline",
                    .version = 0,
                    .data = data,
                    .flags = modflags{ .extra_data = true, .physics = true },
                    .alloc = alloc,
                };
            } else { // TODO check what 6.2 would do in this case
                const data: []u8 = try alloc.alloc(u8, 16);
                @memcpy(data[0..8], &@as([8]u8, @bitCast(@as(f64, 100.0))));
                @memcpy(data[8..16], &@as([8]u8, @bitCast(@as(f64, 100.0))));
                return modtable_entry{
                    .name = "base.startoffset",
                    .version = 0,
                    .data = data,
                    .flags = modflags{ .extra_data = true, .physics = true },
                    .alloc = alloc,
                };
            }
        }

        if (prop.amf_type == .Array) {
            const data: []u8 = try alloc.alloc(u8, 16);
            @memcpy(data[0..8], &@as([8]u8, @bitCast(@as(f64, try prop.getItemExpectType(0, .Number)))));
            @memcpy(data[8..16], &@as([8]u8, @bitCast(@as(f64, try prop.getItemExpectType(1, .Number)))));
            return modtable_entry{
                .name = "base.startoffset",
                .version = 0,
                .data = data,
                .flags = modflags{ .extra_data = true, .physics = true },
                .alloc = alloc,
            };
        }

        return error.TypeMismatch;
    }

    // seperate the .sol's lines into simline and scnline mods
    pub fn lineEntries(track: sol.Track, alloc: std.mem.Allocator) ![2]?modtable_entry {
        var simlinebuffer: Bytes = Bytes.init(alloc);
        var scnlinebuffer: Bytes = Bytes.init(alloc);
        const simlinewriter = simlinebuffer.writer();
        const scnlinewriter = scnlinebuffer.writer();
        // pad count
        try simlinewriter.writeInt(u32, 0, .little);
        try scnlinewriter.writeInt(u32, 0, .little);

        var simlinecount: u32 = 0;
        var scnlinecount: u32 = 0;

        const lines: amf.Array = try track.getPropertyExpectType("data", .Array);

        for (lines.items) |line| {
            const linedata = try sol.Line.fromAmf(line);
            switch (linedata.linetype) {
                .Standard, .Acceleration => {
                    const lrb_line_flags = packed struct(u8) {
                        red: bool,
                        inverted: bool,
                        left_ext: bool,
                        right_ext: bool,
                        padding: u4 = 0,
                    };
                    try simlinewriter.writeInt(u32, linedata.ID, .little);

                    const flags = lrb_line_flags{
                        .red = linedata.linetype == .Acceleration,
                        .inverted = linedata.invert,
                        .left_ext = linedata.left_extended,
                        .right_ext = linedata.right_extended,
                    };

                    try simlinewriter.writeAll(&@as([1]u8, @bitCast(flags)));

                    try simlinewriter.writeAll(&@as([8]u8, @bitCast(linedata.x1)));
                    try simlinewriter.writeAll(&@as([8]u8, @bitCast(linedata.y1)));
                    try simlinewriter.writeAll(&@as([8]u8, @bitCast(linedata.x2)));
                    try simlinewriter.writeAll(&@as([8]u8, @bitCast(linedata.y2)));

                    simlinecount += 1;
                },
                .Scenery => {
                    try scnlinewriter.writeInt(u32, linedata.ID, .little);
                    try scnlinewriter.writeAll(&@as([8]u8, @bitCast(linedata.x1)));
                    try scnlinewriter.writeAll(&@as([8]u8, @bitCast(linedata.y1)));
                    try scnlinewriter.writeAll(&@as([8]u8, @bitCast(linedata.x2)));
                    try scnlinewriter.writeAll(&@as([8]u8, @bitCast(linedata.y2)));

                    scnlinecount += 1;
                },
            }
        }

        var out = [2]?modtable_entry{ null, null };

        if (simlinecount > 0) {
            @memcpy(simlinebuffer.items[0..4], &@as([4]u8, @bitCast(simlinecount)));
            out[0] = modtable_entry{
                .name = "base.simline",
                .version = 0,
                .data = @ptrCast(try simlinebuffer.toOwnedSlice()),
                .flags = modflags{ .extra_data = true, .physics = true, .scenery = true },
                .alloc = alloc,
            };
        }
        if (scnlinecount > 0) {
            @memcpy(scnlinebuffer.items[0..4], &@as([4]u8, @bitCast(scnlinecount)));
            out[1] = modtable_entry{
                .name = "base.scnline",
                .version = 0,
                .data = @ptrCast(try scnlinebuffer.toOwnedSlice()),
                .flags = modflags{ .extra_data = true, .scenery = true },
                .alloc = alloc,
            };
        }

        return out;
    }

    pub fn deinit(self: modtable_entry) void {
        if (self.data) |data| {
            self.alloc.free(data);
        }
    }
};

pub const state = lrb_state;

pub const lrb_state = struct {
    entries: [5]modtable_entry, // for a track only containing base.* features, it will write a max of 5 mods.
    //                             (base.startoffset and base.startline are mutually exclusive)
    mod_count: u16,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) lrb_state {
        return lrb_state{
            .entries = [1]modtable_entry{undefined} ** 5,
            .mod_count = 0,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *lrb_state) void {
        for (0..self.mod_count) |i| {
            self.entries[i].deinit();
        }
    }

    pub fn addMod(self: *lrb_state, mod: modtable_entry) void {
        self.entries[self.mod_count] = mod;
        self.mod_count += 1;
    }

    pub fn writeLrb(self: *lrb_state, file: std.fs.File) !void {
        const writer = file.writer();
        try writer.writeAll(&MAGIC_NUM);
        try writer.writeInt(u8, LRB_VERSION, .little);
        try writer.writeInt(u16, self.mod_count, .little);
        // write the modtable entries
        for (0..self.mod_count) |i| {
            try writer.writeInt(u8, std.math.cast(u8, self.entries[i].name.len) orelse return error.CastError, .little);
            try writer.writeAll(self.entries[i].name);
            try writer.writeInt(u16, self.entries[i].version, .little);

            try writer.writeByte(@bitCast(self.entries[i].flags));

            if (self.entries[i].flags.extra_data and self.entries[i].data != null) {
                self.entries[i].data_segment_position = try file.getPos();
                // padding
                try writer.writeInt(u64, 0, .little); // pointer
                try writer.writeInt(u64, 0, .little); // length
            }
        }
        // go back and write the data sections
        for (0..self.mod_count) |i| {
            if (self.entries[i].data_segment_position) |pos| {
                const return_pos = try file.getPos();
                try file.seekTo(pos);
                try writer.writeInt(u64, return_pos, .little);
                try writer.writeInt(u64, self.entries[i].data.?.len, .little);
                try file.seekTo(return_pos);
                try writer.writeAll(self.entries[i].data.?);
            }
        }
    }
};
