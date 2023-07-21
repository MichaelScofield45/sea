const std = @import("std");

const Self = @This();

names: std.ArrayList(u8),
end_indices: std.ArrayList(usize),

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .names = std.ArrayList(u8).init(allocator),
        .end_indices = std.ArrayList(usize).init(allocator),
    };
}

pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
    return .{
        .names = try std.ArrayList(u8).initCapacity(allocator, capacity),
        .end_indices = try std.ArrayList(usize).initCapacity(allocator, capacity / @sizeOf(usize)),
    };
}

pub fn len(self: Self) usize {
    return self.end_indices.items.len;
}

pub fn getEndIndices(self: Self) []const usize {
    return self.end_indices.items;
}

pub fn getNameAtEntryIndex(self: Self, index: usize) []const u8 {
    if (index == 0)
        return self.names.items[0..self.end_indices.items[index]];

    return self.names.items[self.end_indices.items[index - 1]..self.end_indices.items[index]];
}

pub fn append(self: *Self, name: []const u8) !void {
    try self.names.appendSlice(name);
    try self.end_indices.append(self.names.items.len);
}

pub fn deinit(self: *Self) void {
    self.names.allocator.free(self.names.allocatedSlice());
    self.end_indices.allocator.free(self.end_indices.allocatedSlice());
}
