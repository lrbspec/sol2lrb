const std = @import("std");
const sol = @import("sol.zig");
const lrb = @import("lrb.zig");

pub fn main() !void {
    const file = try std.fs.cwd().openFile("savedLines.sol", .{});
    defer file.close();
    var sol_f = try sol.readSol(std.heap.smp_allocator, file.reader());
    defer sol_f.deinit();
    const tracks = try sol.getTracks(sol_f);

    var state = lrb.state.init(std.heap.smp_allocator);
    defer state.deinit();

    const track_0 = tracks.items[0];

    if (lrb.modtable_entry.labelEntry(track_0, std.heap.smp_allocator)) |entry| {
        state.addMod(entry);
    }
    if (lrb.modtable_entry.gridVersionEntry(track_0, std.heap.smp_allocator)) |entry| {
        state.addMod(entry);
    }
    if (lrb.modtable_entry.startEntry(track_0, std.heap.smp_allocator) catch null) |entry| {
        state.addMod(entry);
    }

    const line_entries = try lrb.modtable_entry.lineEntries(track_0, std.heap.smp_allocator);
    if (line_entries[0]) |entry| {
        state.addMod(entry);
    }
    if (line_entries[1]) |entry| {
        state.addMod(entry);
    }

    try state.writeLrb(std.io.getStdOut());
    //for (tracks.items) |track| {
    //    std.debug.print("converting sol track {s} to lrb\n", .{try track.getPropertyExpectType("label", .String)});
    //    std.debug.print("grid version {s}\n", .{try track.getPropertyExpectType("version", .String)});
    //    std.debug.print("type of data: {any}\n", .{(try track.getProperty("data")).amf_type});
    //    std.debug.print("type of data item 1: {any}\n", .{(try (try track.getProperty("data")).getItem(0)).amf_type});
    //}
}
