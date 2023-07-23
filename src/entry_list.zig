const std = @import("std");

const Self = @This();

names: std.ArrayList(u8),
/// Indices of where each name ends
indices: std.ArrayList(usize),

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .names = std.ArrayList(u8).init(allocator),
        .indices = std.ArrayList(usize).init(allocator),
    };
}

pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Self {
    return .{
        .names = try std.ArrayList(u8).initCapacity(allocator, capacity),
        .indices = try std.ArrayList(usize).initCapacity(allocator, capacity / @sizeOf(usize)),
    };
}

pub fn len(self: Self) usize {
    return self.indices.items.len;
}

pub fn getIndices(self: Self) []const usize {
    return self.indices.items;
}

pub fn getNameAtEntryIndex(self: Self, index: usize) []const u8 {
    if (index == 0)
        return self.names.items[0..self.indices.items[index]];

    return self.names.items[self.indices.items[index - 1]..self.indices.items[index]];
}

pub fn append(self: *Self, name: []const u8) !void {
    try self.names.appendSlice(name);
    try self.indices.append(self.names.items.len);
}

pub fn ensureTotalCapacity(self: *Self, new_capacity: usize) !void {
    try self.names.ensureTotalCapacity(new_capacity);
    try self.indices.ensureTotalCapacity(new_capacity / @sizeOf(usize));
}

pub fn deinit(self: *Self) void {
    self.names.allocator.free(self.names.allocatedSlice());
    self.indices.allocator.free(self.indices.allocatedSlice());
}
