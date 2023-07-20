const std = @import("std");
const linux = std.os.linux;
const EntryList = @import("entry_list.zig");

stdin: std.fs.File,
dir_list: EntryList,
file_list: EntryList,
cursor: usize,
/// Scroll window for smooth scrolling and rendering
s_win: struct {
    height: u32,
    start: u32,
    end: u32,
},
running: bool,
cwd_name: []const u8,
original_termios: std.os.termios,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, stdin: std.fs.File) !Self {
    var original_termios = try std.os.tcgetattr(stdin.handle);

    var new = original_termios;
    new.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    new.oflag &= ~(linux.OPOST);
    new.cflag |= (linux.CS8);
    new.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    try std.os.tcsetattr(stdin.handle, .FLUSH, new);

    return .{
        .stdin = stdin,
        .cursor = 0,
        .running = true,
        .cwd_name = undefined,
        .original_termios = original_termios,
        .s_win = .{
            .height = try getTerminalSize(stdin.handle) - 6,
            .start = 0,
            .end = 0,
        },
        .dir_list = try EntryList.initCapacity(allocator, 1024),
        .file_list = try EntryList.initCapacity(allocator, 1024),
    };
}

pub fn deinit(self: *Self) void {
    std.os.tcsetattr(self.stdin.handle, .FLUSH, self.original_termios) catch |err| {
        std.log.err("unexpected error at shutdown: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    self.dir_list.deinit();
    self.file_list.deinit();
}

fn getTerminalSize(stdin_handle: std.os.fd_t) !u32 {
    var size: linux.winsize = undefined;
    // TODO: Handle error with errno
    if (linux.ioctl(stdin_handle, linux.T.IOCGWINSZ, @intFromPtr(&size)) != 0)
        return error.IoctlError;

    return @as(u32, size.ws_row);
}

pub fn printEntries(self: Self, writer: anytype) !void {
    for (self.dir_list.getEndIndices(), 0..) |_, entry_idx| {
        if (entry_idx == self.cursor)
            try writer.writeAll("\x1B[30;44m")
        else
            try writer.writeAll("\x1B[1;34;49m");

        try writer.print("{s}\x1B[1E", .{self.dir_list.getNameAtEntryIndex(entry_idx)});
    }

    try writer.writeAll("\x1B[0m");
    for (self.file_list.getEndIndices(), 0..) |_, entry_idx| {
        if (entry_idx + self.dir_list.getTotalEntries() == self.cursor)
            try writer.writeAll("\x1B[30;47m")
        else
            try writer.writeAll("\x1B[0m");

        try writer.print("{s}\x1B[1E", .{self.file_list.getNameAtEntryIndex(entry_idx)});
    }
}

pub fn clearEntries(self: *Self) void {
    self.dir_list.names.clearRetainingCapacity();
    self.dir_list.end_indices.clearRetainingCapacity();
    self.file_list.names.clearRetainingCapacity();
    self.file_list.end_indices.clearRetainingCapacity();
}

pub fn handleInput(self: *Self, input: u8, buffer: []u8) !void {
    const total_items = self.dir_list.getTotalEntries() + self.file_list.getTotalEntries();
    const total_items_index = if (total_items != 0) total_items - 1 else 0;

    switch (input) {
        'q' => self.running = false,
        'h' => {
            self.clearEntries();
            self.cursor = try self.appendAboveEntries();
            try std.process.changeCurDir("..");

            const path = try std.process.getCwd(buffer);
            self.cwd_name = std.fs.path.basename(path);
        },
        'j' => {
            self.cursor = if (self.cursor != total_items_index)
                self.cursor + 1
            else
                0;

            if (self.cursor > self.s_win.end) {
                self.s_win.end = @intCast(self.cursor);
                self.s_win.start = self.s_win.end - self.s_win.height;
            }
        },
        'k' => {
            self.cursor = if (self.cursor != 0)
                self.cursor - 1
            else
                total_items_index;

            if (self.cursor > self.s_win.end) {
                self.s_win.end = @intCast(self.cursor);
                self.s_win.start = self.s_win.end - self.s_win.height;
            }
        },
        'l' => {
            if (self.cursor < self.dir_list.getTotalEntries()) {
                const name = self.dir_list.getNameAtEntryIndex(self.cursor);
                self.cursor = 0;

                try std.process.changeCurDir(name);
                const path = try std.process.getCwd(buffer);
                self.cwd_name = std.fs.path.basename(path);

                self.clearEntries();
                try self.appendCwdEntries();
            }
        },
        'g' => self.cursor = 0,
        'G' => self.cursor = total_items_index,
        else => {},
    }
}

pub fn appendCwdEntries(self: *Self) !void {
    var iterable_dir = try std.fs.cwd().openIterableDir(".", .{});
    defer iterable_dir.close();

    // Store in ArrayLists
    // Iter current dir
    var it = iterable_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory and !std.mem.startsWith(u8, entry.name, ".")) {
            try self.dir_list.append(entry.name);
        } else {
            if (!std.mem.startsWith(u8, entry.name, "."))
                try self.file_list.append(entry.name);
        }
    }

    self.s_win.end = blk: {
        const len = self.dir_list.getTotalEntries() + self.file_list.getTotalEntries();
        if (len < self.s_win.height)
            break :blk @intCast(len)
        else
            break :blk self.s_win.height;
    };
}

/// Appends all entries of the above directory, returning which entry matches the
/// current working directory
pub fn appendAboveEntries(self: *Self) !usize {
    var iterable_dir = try std.fs.cwd().openIterableDir("..", .{});
    defer iterable_dir.close();

    var match: ?usize = null;

    var it = iterable_dir.iterate();
    var count: usize = 0;

    while (try it.next()) |entry| {
        if (entry.kind == .directory and !std.mem.startsWith(u8, entry.name, ".")) {
            try self.dir_list.append(entry.name);
            if (std.mem.eql(u8, self.cwd_name, entry.name)) match = count;
            count += 1;
        } else {
            if (!std.mem.startsWith(u8, entry.name, "."))
                try self.file_list.append(entry.name);
        }
    }

    self.s_win.end = blk: {
        const len = self.dir_list.getTotalEntries() + self.file_list.getTotalEntries();
        if (len < self.s_win.height)
            break :blk @intCast(len)
        else
            break :blk self.s_win.height;
    };

    if (match) |index|
        return index
    else
        return error.NoMatchingDirFound;
}
