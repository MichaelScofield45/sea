const std = @import("std");
const Allocator = std.mem.Allocator;
const Entry = std.fs.Dir.Entry;
const linux = std.os.linux;
const page_allocator = std.heap.page_allocator;
const builtin = @import("builtin");

// stdout: std.io.BufferedWriter,
// stdin: std.io.Reader,

pub const PastDir = struct {
    sels: []const bool,
    names: []const u8,
};

const Self = @This();

pub const Action = enum {
    quit,
    left,
    down,
    up,
    right,
    top,
    bottom,
    select_toggle,
    select_all,
    select_invert,
    delete,
    move,
    paste,
    hidden_toggle,

    pub fn fromInput(input: [3]u8) ?Action {
        // 0x1b is the escape character in terminals
        if (input[0] == 0x1b)
            return switch (std.mem.readInt(u16, input[1..], .big)) {
                0x5b41 => .up,
                0x5b42 => .down,
                0x5b44 => .left,
                0x5b43 => .right,
                else => null,
            };

        return switch (input[0]) {
            'q' => .quit,
            'h' => .left,
            'j' => .down,
            'k' => .up,
            'l' => .right,
            'g' => .top,
            'G' => .bottom,

            ' ' => .select_toggle,
            'a' => .select_all,
            'A' => .select_invert,

            'd' => .delete,
            'v' => .move,
            'p' => .paste,

            '.' => .hidden_toggle,

            else => null,
        };
    }
};

const DirChange = enum {
    backwards,
    forwards,
};

pub const EntryList = std.MultiArrayList(Entry);

fn seaInit(stdout: std.fs.File, stdin: std.fs.File, original_termios: std.os.linux.termios) !void {
    try stdout.writeAll("\x1b[?25l\x1b[?1049h");

    var new_termios = original_termios;
    new_termios.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    new_termios.oflag &= ~(linux.OPOST);
    new_termios.cflag |= (linux.CS8);
    new_termios.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    try std.os.tcsetattr(stdin.handle, .FLUSH, new_termios);
}

fn seaDeinit(stdout: std.fs.File, stdin: std.fs.File, original_termios: std.os.linux.termios) void {
    defer std.os.tcsetattr(stdin.handle, .FLUSH, original_termios) catch unreachable;
    stdout.writeAll("\x1b[?1049l\x1b[0m\x1b[?25h") catch unreachable;
}

pub fn main() !void {
    const stdout_f = std.io.getStdOut();

    var bw = std.io.bufferedWriter(stdout_f.writer());
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_alloc = gpa.allocator();

    const stdin_f = std.io.getStdIn();
    const stdin = stdin_f.reader();

    const original_termios = try std.os.tcgetattr(stdin_f.handle);
    try seaInit(stdout_f, stdin_f, original_termios);
    defer seaDeinit(stdout_f, stdin_f, original_termios);

    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    try clearScreen(stdout);
    var cwd_files = try getCwdFiles(arena_alloc);
    var sel = try allocBoolSlice(arena_alloc, cwd_files.len, false);
    try printCwdFiles(stdout, cwd_files, 0, sel);
    try bw.flush();

    var running = true;
    var char_buf: [3]u8 = undefined;
    var cursor: usize = 0;
    while (running) {
        _ = try stdin.read(&char_buf);

        const action = Action.fromInput(char_buf) orelse continue;
        const dir_change = try handleAction(stdout, &running, action, cwd_files, sel, &cursor);

        if (dir_change) |direction| {
            switch (direction) {
                .backwards => {
                    try std.process.changeCurDir("..");
                    // TODO: this needs to search for the bast current dir
                    cursor = 0;
                },
                .forwards => {
                    const new_dir = cwd_files[cursor].name;
                    try std.process.changeCurDir(new_dir);
                    cursor = 0;
                },
            }

            if (!arena.reset(.retain_capacity)) return error.ArenaResetError;
            try clearScreen(stdout);
            cwd_files = try getCwdFiles(arena_alloc);
            sel = try allocBoolSlice(arena_alloc, cwd_files.len, false);
            try printCwdFiles(stdout, cwd_files, cursor, sel);
        }

        try bw.flush();
    }

    // Setup cd on quit if available
    var cd_quit: ?[]const u8 = null;
    defer if (cd_quit) |allocation| gpa_alloc.free(allocation);

    if (std.process.hasEnvVarConstant("SEA_TMPFILE"))
        cd_quit = try std.process.getEnvVarOwned(gpa_alloc, "SEA_TMPFILE");
}

fn handleAction(
    writer: anytype,
    running: *bool,
    action: Action,
    files: []Entry,
    selection: []bool,
    cursor: *usize,
) !?DirChange {
    switch (action) {
        .quit => running.* = false,

        .up, .down => |direction| {
            if (direction == .up)
                cursor.* = std.math.sub(usize, cursor.*, 1) catch files.len -| 1
            else
                cursor.* = if (cursor.* + 1 >= files.len) 0 else cursor.* + 1;
            try clearScreen(writer);
            try printCwdFiles(writer, files, cursor.*, selection);
        },

        .left => return .backwards,

        .right => return .forwards,

        .bottom => {
            cursor.* = files.len -| 1;
            try clearScreen(writer);
            try printCwdFiles(writer, files, cursor.*, selection);
        },

        .top => {
            cursor.* = 0;
            try clearScreen(writer);
            try printCwdFiles(writer, files, cursor.*, selection);
        },

        .select_toggle => {
            selection[cursor.*] = !selection[cursor.*];
            cursor.* += 1;
            try clearScreen(writer);
            try printCwdFiles(writer, files, cursor.*, selection);
        },

        .select_invert => {
            for (selection) |*bool_val|
                bool_val.* = !bool_val.*;
            try clearScreen(writer);
            try printCwdFiles(writer, files, cursor.*, selection);
        },

        .select_all => {
            for (selection) |*bool_val|
                bool_val.* = true;
            try clearScreen(writer);
            try printCwdFiles(writer, files, cursor.*, selection);
        },

        else => {},
    }

    return null;
}

fn clearScreen(writer: anytype) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
}

fn printCwdFiles(
    writer: anytype,
    cwd_files: []const std.fs.Dir.Entry,
    cursor: usize,
    selection: []bool,
) !void {
    const line_down = "\x1b[1E";
    const reverse = "\x1b[7m";
    const reset = "\x1b[0m";

    for (cwd_files, selection, 0..) |file, sel, idx| {
        if (!sel) {
            try writer.writeAll(" ");
        } else {
            try writer.writeAll("\x1b[30;42m>\x1b[0m");
        }
        if (idx == cursor) try writer.writeAll(reverse);
        const style = styleFromKind(file.kind);
        try writer.writeAll(style);
        try writer.writeAll(file.name);
        try writer.writeAll(line_down ++ reset);
    }
}

fn styleFromKind(kind: Entry.Kind) []const u8 {
    const file_style = "";
    const dir_style = "\x1b[1m\x1b[34m";
    const sym_link_style = "\x1b[36m";

    return switch (kind) {
        .file => file_style,
        .directory => dir_style,
        .sym_link => sym_link_style,
        else => "",
    };
}

fn getCwdFiles(arena: Allocator) ![]Entry {
    var cwd = try std.fs.cwd().openDir(".", .{ .iterate = true });
    var dir_iter = cwd.iterate();
    var list = std.ArrayList(std.fs.Dir.Entry).init(arena);
    while (try dir_iter.next()) |entry| {
        const dup_name = try arena.dupe(u8, entry.name);
        const new_entry: Entry = .{
            .name = dup_name,
            .kind = entry.kind,
        };
        try list.append(new_entry);
    }

    const files_slice = try list.toOwnedSlice();
    sortFiles(files_slice);

    return files_slice;
}

fn sortFiles(files: []Entry) void {
    const ascComp = struct {
        fn func(_: void, lhs: Entry, rhs: Entry) bool {
            return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
        }
    }.func;
    std.sort.block(Entry, files, {}, ascComp);
}

fn allocBoolSlice(arena: Allocator, size: usize, value: bool) Allocator.Error![]bool {
    const mem = try arena.alloc(bool, size);
    for (mem) |*b|
        b.* = value;

    return mem;
}
