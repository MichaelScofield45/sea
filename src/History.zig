const std = @import("std");
const KV = std.StringHashMap(DirContext).KV;
const Entry = std.StringHashMap(DirContext).Entry;
const DynamicBitSetUnmanaged = std.bit_set.DynamicBitSetUnmanaged;

map: std.StringHashMap(DirContext),

const DirContext = struct {
    files: []const u8,
    selection: DynamicBitSetUnmanaged,
};

const History = @This();

pub fn init(allocator: std.mem.Allocator) History {
    return .{
        .map = std.StringHashMap(DirContext).init(allocator),
    };
}

pub fn freeOwnedData(self: *History) void {
    const allocator = self.map.allocator;

    var key_iter = self.map.keyIterator();
    var val_iter = self.map.valueIterator();

    while (key_iter.next()) |key| {
        // This HAS to work since both keys and values have the same number of
        // items
        const val = val_iter.next().?;
        allocator.free(key.*);
        val.selection.deinit(allocator);
        allocator.free(val.files);
    }
}

pub fn reset(self: *History) void {
    return self.map.clearRetainingCapacity();
}

pub fn deinit(self: *History) void {
    self.freeOwnedData();
    return self.map.deinit();
}

pub fn store(self: *History, path: []const u8, files: []const u8, selection: DynamicBitSetUnmanaged) !void {
    return try self.map.put(path, DirContext{
        .files = files,
        .selection = selection,
    });
}

// pub fn get(self: *History, path: []const u8) ?Entry {
//     const entry = self.map.getEntry(path);
//     if (entry) |_| self.map.removeByPtr(entry.?.key_ptr);
//
//     return entry;
// }

test "deinit History" {
    const alloc = std.testing.allocator;

    var hist = History.init(alloc);
    defer hist.deinit();

    const hi = try alloc.dupe(u8, "/hi");
    const hello = try alloc.dupe(u8, "hello world");
    const bools = try alloc.dupe(bool, &[_]bool{ true, false, true, true });

    try hist.store(hi, hello, bools);
}
