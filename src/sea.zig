const std = @import("std");
const Allocator = std.mem.Allocator;
const Entry = std.fs.Dir.Entry;
const linux = std.os.linux;
const page_allocator = std.heap.page_allocator;
const builtin = @import("builtin");

const DynamicBitSet = std.bit_set.DynamicBitSet;
const ByteList = std.ArrayList(u8);
const Window = @import("Window.zig");
const History = @import("History.zig");
const ArgFlags = @import("main.zig").ArgFlags;

const Self = @This();

pub const Action = enum {
    quit,
    left,
    down,
    up,
    right,
    top,
    bottom,
    middle,
    select_toggle,
    select_all,
    select_invert,
    delete,
    move,
    paste,
    hidden_toggle,
    search,

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
            'M' => .middle,

            ' ' => .select_toggle,
            'a' => .select_all,
            'A' => .select_invert,

            'd' => .delete,
            'v' => .move,
            'p' => .paste,

            '.' => .hidden_toggle,
            '/' => .search,

            else => null,
        };
    }
};

const Status = enum {
    running,
    searching,
    quit,
};

pub fn main(args: ArgFlags) !void {
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

    var arena = std.heap.ArenaAllocator.init(page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var path = try getCwdPath(arena_alloc, gpa_alloc);
    defer path.deinit();

    var files = try getCwdFiles(arena_alloc, path.items, false);
    var sel = try DynamicBitSet.initEmpty(arena_alloc, files.len);
    var n_sel: usize = 0;
    var past_sel: usize = 0;
    var win = Window{ .start = 0, .len = 39 };

    var cursor: usize = 0;

    try clearScreen(stdout);
    try printPath(stdout, path.items);
    try printPosition(stdout, cursor, files.len);
    try printSelection(stdout, n_sel, past_sel);
    try printFiles(stdout, files, cursor, sel, win);
    try bw.flush();

    var hist = History.init(gpa_alloc);
    defer hist.deinit();

    var search_files: ?[]const Entry = null;
    defer if (search_files != null) gpa_alloc.free(search_files.?);

    var status = Status.running;
    var hidden = false;
    var char_buf: [3]u8 = undefined;
    while (status != .quit) {
        _ = try stdin.read(&char_buf);

        const action = Action.fromInput(char_buf) orelse continue;

        switch (action) {
            .quit => status = .quit,

            .up, .down => |direction| cursor = moveCursor(
                cursor,
                direction,
                if (status != .searching) files.len else search_files.?.len,
                &win,
            ),

            .left, .right => |move| {
                try resetArena(&arena);

                if (n_sel > 0) {
                    // Store dir in history for later use
                    const dup_path = try gpa_alloc.dupe(u8, path.items);
                    const dup_sel = try sel.unmanaged.clone(gpa_alloc);
                    const sel_files = try getSelectedFiles(gpa_alloc, sel, files);
                    try hist.store(dup_path, sel_files, dup_sel);

                    past_sel += n_sel;
                }

                if (move == .left) {
                    const dir_name = std.fs.path.basename(path.items);
                    moveLeft(&path);
                    files = try getCwdFiles(arena_alloc, path.items, hidden);
                    cursor = findCursorPos(dir_name, files) orelse cursor;
                } else {
                    if (files[cursor].kind != .directory) continue;
                    const dir_name = files[cursor].name;
                    try moveRight(&path, dir_name);
                    files = try getCwdFiles(arena_alloc, path.items, hidden);
                    cursor = 0;
                }
                win.scroll(cursor);

                if (hist.map.getEntry(path.items)) |entry| {
                    sel = .{
                        .unmanaged = try entry.value_ptr.selection.clone(arena_alloc),
                        .allocator = arena_alloc,
                    };
                    n_sel = sel.count();
                    past_sel -= n_sel;

                    // You have to clean up after you get the data
                    gpa_alloc.free(entry.key_ptr.*);
                    gpa_alloc.free(entry.value_ptr.files);
                    entry.value_ptr.selection.deinit(gpa_alloc);
                    hist.map.removeByPtr(entry.key_ptr);
                } else {
                    sel = try DynamicBitSet.initEmpty(arena_alloc, files.len);
                    n_sel = 0;
                }
            },

            .top => {
                cursor = 0;
                win.scroll(cursor);
            },

            .bottom => {
                cursor = files.len -| 1;
                win.scroll(cursor);
            },

            .middle => {
                cursor = (files.len -| 1) / 2;
            },

            .select_toggle => {
                sel.toggle(cursor);
                n_sel = if (sel.isSet(cursor)) n_sel + 1 else n_sel - 1;
                cursor += if (cursor + 1 < files.len) 1 else 0;
            },

            .select_invert => {
                sel.toggleAll();
                n_sel = files.len - n_sel;
            },

            .select_all => {
                sel.setRangeValue(.{ .start = 0, .end = sel.capacity() }, true);
                n_sel = files.len;
            },

            .delete => {
                try deleteHistory(arena_alloc, &hist);
                try deleteCwdSelectedFiles(arena_alloc, path.items, files, sel);

                try resetArena(&arena);

                files = try getCwdFiles(arena_alloc, path.items, hidden);
                sel = try DynamicBitSet.initEmpty(arena_alloc, files.len);

                past_sel = 0;
                n_sel = 0;
            },

            .move => {
                // TODO: have some kind of window error popup when files are not
                // found, the most probable erorr will be that the files were
                // already moved/deleted/renamed higher en the directory
                // hierarchy.
                try moveHistory(arena_alloc, &hist, path.items);

                try resetArena(&arena);

                past_sel = 0;
                n_sel = 0;

                files = try getCwdFiles(arena_alloc, path.items, hidden);
                sel = try DynamicBitSet.initEmpty(arena_alloc, files.len);
                cursor = 0;
            },

            .hidden_toggle => {
                hidden = !hidden;

                try resetArena(&arena);

                files = try getCwdFiles(arena_alloc, path.items, hidden);
                sel = try DynamicBitSet.initEmpty(arena_alloc, files.len);
                cursor = 0;
            },

            .search => {
                try startSearch(stdout_f);
                var search_buf: [1024]u8 = undefined;
                const pattern = blk: {
                    var search_len: usize = 0;
                    while (search_len < search_buf.len) {
                        var s_char_buf: [4]u8 = undefined;
                        const read_len = try stdin.read(&s_char_buf);

                        if (read_len == 1 and s_char_buf[0] == '\n') break;

                        @memcpy(search_buf[search_len..][0..read_len], s_char_buf[0..read_len]);
                        try stdout_f.writeAll(s_char_buf[0..read_len]);
                        search_len += read_len;
                    }

                    break :blk search_buf[0..search_len];
                };

                search_files = switch (status) {
                    .running => try searchFiles(gpa_alloc, files, pattern),
                    .searching => blk: {
                        const old_files = search_files.?;
                        defer gpa_alloc.free(old_files);

                        break :blk try searchFiles(gpa_alloc, old_files, pattern);
                    },
                    else => unreachable,
                };

                // TODO: deal with window positioning, should we store the old
                // one??
                // TODO: have an input to return to the original list
                status = .searching;
                cursor = 0;
            },

            else => {},
        }

        try clearScreen(stdout);
        try printPath(stdout, path.items);
        try printPosition(stdout, cursor, files.len);
        try printSelection(stdout, n_sel, past_sel);
        if (status != .searching)
            try printFiles(stdout, files, cursor, sel, win)
        else
            try printFiles(stdout, search_files.?, cursor, sel, win);

        try bw.flush();
    }

    seaDeinit(stdout_f, stdin_f, original_termios);

    if (args.print_selection) {
        try printHistory(stdout, hist);
        try printCwdSelectedFiles(stdout, path.items, files, sel);
        try bw.flush();
    }

    if (std.process.hasEnvVarConstant("SEA_TMPFILE")) {
        const config_dir = try std.process.getEnvVarOwned(arena_alloc, "SEA_TMPFILE");

        var file = try std.fs.createFileAbsolute(config_dir, .{});
        defer file.close();

        try file.writeAll(path.items);
    }
}

fn seaInit(stdout: std.fs.File, stdin: std.fs.File, original_termios: std.os.linux.termios) !void {
    try stdout.writeAll("\x1b[?25l\x1b[?1049h");

    var new_termios = original_termios;
    // new_termios.iflag &= ~(linux.BRKINT | linux.ICRNL | linux.INPCK | linux.ISTRIP | linux.IXON);
    new_termios.iflag &= ~(linux.BRKINT | linux.INPCK | linux.ISTRIP | linux.IXON);
    new_termios.oflag &= ~(linux.OPOST);
    new_termios.cflag |= (linux.CS8);
    // new_termios.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN | linux.ISIG);
    new_termios.lflag &= ~(linux.ECHO | linux.ICANON | linux.IEXTEN);
    try std.os.tcsetattr(stdin.handle, .FLUSH, new_termios);
}

fn seaDeinit(stdout: std.fs.File, stdin: std.fs.File, original_termios: std.os.linux.termios) void {
    defer std.os.tcsetattr(stdin.handle, .FLUSH, original_termios) catch unreachable;
    stdout.writeAll("\x1b[?1049l\x1b[0m\x1b[?25h") catch unreachable;
}

fn moveLeft(path: *ByteList) void {
    const new_len = blk: {
        const dirname = std.fs.path.dirname(path.items) orelse path.items;
        break :blk dirname.len;
    };
    path.items.len = new_len;
}

fn moveRight(path: *ByteList, postfix: []const u8) !void {
    const writer = path.writer();
    if (path.items.len != 1)
        try writer.print("/{s}", .{postfix})
    else
        try writer.print("{s}", .{postfix});
}

fn findCursorPos(name: []const u8, files: []const Entry) ?usize {
    for (files, 0..) |file, idx| {
        if (std.mem.eql(u8, file.name, name)) return idx;
    }

    return null;
}

fn saveDir() !void {
    return;
}

fn getCwdPath(arena: Allocator, gpa: Allocator) !ByteList {
    const cwd = try std.process.getCwdAlloc(arena);
    var list = ByteList.init(gpa);
    try list.appendSlice(cwd);
    return list;
}

fn clearScreen(writer: anytype) !void {
    try writer.writeAll("\x1b[2J\x1b[H");
}

fn printPath(writer: anytype, path: []const u8) !void {
    return try writer.print("{s}\x1b[1E", .{path});
}

fn printPosition(writer: anytype, cursor: usize, tot_files: usize) !void {
    return if (tot_files > 0)
        try writer.print(" {}/{} ", .{ cursor + 1, tot_files });
}

fn printSelection(writer: anytype, n_selection: usize, past_selection: usize) !void {
    const total = n_selection + past_selection;
    return if (total > 0)
        try writer.print("\x1b[30;42m {} \x1b[0m\x1b[2E", .{total})
    else
        try writer.writeAll("\x1b[2E");
}

fn printFiles(
    writer: anytype,
    files: []const std.fs.Dir.Entry,
    cursor: usize,
    selection: DynamicBitSet,
    win: Window,
) !void {
    const line_down = "\x1b[1E";
    const reverse = "\x1b[7m";
    const reset = "\x1b[0m";

    const start = win.start;
    const end = if (start + win.len > files.len)
        files.len - start
    else
        win.len;

    for (files[start..][0..end], start..) |file, idx| {
        if (!selection.isSet(idx)) {
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

fn getCwdFiles(arena: Allocator, path: []const u8, hidden: bool) ![]Entry {
    var cwd = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    var dir_iter = cwd.iterate();
    var list = std.ArrayList(std.fs.Dir.Entry).init(arena);
    while (try dir_iter.next()) |entry| {
        if (entry.name[0] != '.') {
            const dup_name = try arena.dupe(u8, entry.name);
            const new_entry: Entry = .{
                .name = dup_name,
                .kind = entry.kind,
            };
            try list.append(new_entry);
        } else {
            if (hidden) {
                const dup_name = try arena.dupe(u8, entry.name);
                const new_entry: Entry = .{
                    .name = dup_name,
                    .kind = entry.kind,
                };
                try list.append(new_entry);
            }
        }
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

fn getSelectedFiles(allocator: Allocator, selection: DynamicBitSet, files: []const Entry) ![]const u8 {
    var list = ByteList.init(allocator);
    // defer list.deinit();

    for (files, 0..) |file, idx| {
        if (selection.isSet(idx)) {
            try list.appendSlice(file.name);
            try list.append(0);
        }
    }

    return try list.toOwnedSlice();
}

fn printHistory(writer: anytype, hist: History) !void {
    var map_iter = hist.map.iterator();

    while (map_iter.next()) |map_entry| {
        const dir = map_entry.key_ptr.*;

        var file_iter = std.mem.tokenizeScalar(u8, map_entry.value_ptr.files, 0);

        while (file_iter.next()) |file| {
            // std.debug.print("filename: {s}\n", .{file});
            try writer.print("{s}/{s}\n", .{ dir, file });
        }
    }
}

fn printCwdSelectedFiles(writer: anytype, path: []const u8, files: []const Entry, selection: DynamicBitSet) !void {
    for (files, 0..) |file, idx| {
        if (selection.isSet(idx))
            try writer.print("{s}/{s}\n", .{ path, file.name });
    }
}

fn deleteHistory(arena: Allocator, hist: *History) !void {
    var map_iter = hist.map.iterator();

    var list = ByteList.init(arena);
    defer list.deinit();

    const writer = list.writer();

    while (map_iter.next()) |map_entry| {
        const dir = map_entry.key_ptr.*;

        try writer.print("{s}/", .{dir});

        var file_iter = std.mem.tokenizeScalar(u8, map_entry.value_ptr.files, 0);

        while (file_iter.next()) |file| {
            try list.resize(dir.len + 1);
            try writer.writeAll(file);

            try std.fs.deleteTreeAbsolute(list.items);
        }
    }

    hist.freeOwnedData();
    hist.reset();
}

fn deleteCwdSelectedFiles(
    arena: Allocator,
    path: []const u8,
    files: []const Entry,
    selection: DynamicBitSet,
) !void {
    var list = ByteList.init(arena);
    defer list.deinit();
    const writer = list.writer();

    try writer.print("{s}/", .{path});

    for (files, 0..) |file, idx| {
        if (selection.isSet(idx)) {
            list.resize(path.len + 1) catch unreachable;
            try writer.writeAll(file.name);

            try std.fs.deleteTreeAbsolute(list.items);
        }
    }
}

fn moveHistory(arena: Allocator, hist: *History, path: []const u8) !void {
    var map_iter = hist.map.iterator();

    var list = ByteList.init(arena);
    defer list.deinit();
    const list_writer = list.writer();

    var new_path_list = ByteList.init(arena);
    defer new_path_list.deinit();
    const new_path_writer = new_path_list.writer();
    try new_path_writer.print("{s}/", .{path});

    while (map_iter.next()) |map_entry| {
        const dir = map_entry.key_ptr.*;

        try list_writer.print("{s}/", .{dir});

        var file_iter = std.mem.tokenizeScalar(u8, map_entry.value_ptr.files, 0);

        while (file_iter.next()) |file| {
            list.resize(dir.len + 1) catch unreachable;
            try list_writer.writeAll(file);

            new_path_list.resize(path.len + 1) catch unreachable;
            try new_path_writer.writeAll(file);

            try std.fs.renameAbsolute(list.items, new_path_list.items);
        }
    }

    hist.freeOwnedData();
    hist.reset();
}

fn resetArena(arena: *std.heap.ArenaAllocator) error{ArenaResetError}!void {
    return if (!arena.reset(.retain_capacity)) error.ArenaResetError;
}

fn moveCursor(cursor: usize, direction: Action, tot_files: usize, window: *Window) usize {
    const new_cursor = blk: {
        if (direction == .up) {
            break :blk if (cursor != 0) cursor - 1 else tot_files -| 1;
        } else {
            break :blk if (cursor != tot_files -| 1) cursor + 1 else 0;
        }
    };
    window.scroll(new_cursor);
    return new_cursor;
}

fn searchFiles(gpa: Allocator, files: []const Entry, pattern: []const u8) ![]const Entry {
    var list = std.ArrayList(Entry).init(gpa);
    // defer list.deinit();

    for (files) |file| {
        if (std.mem.containsAtLeast(u8, file.name, 1, pattern))
            try list.append(file);
    }

    return try list.toOwnedSlice();
}

fn startSearch(writer: anytype) !void {
    try writer.writeAll("\x1b[42:0Hpattern: ");
}
