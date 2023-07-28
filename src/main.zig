const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Sea = @import("sea.zig");
const PastDir = Sea.PastDir;

pub fn main() !void {
    const stdout_file = std.io.getStdOut();

    // Enable alternative buffer
    try stdout_file.writeAll("\x1B[?1049h");

    // FIXME: This errors out when using a pipe, which it should not since we are
    // using the alternative buffer.
    const config = std.io.tty.detectConfig(stdout_file);
    if (config == .no_color) {
        std.log.err("your terminal does not support ANSI escape code sequences", .{});
        std.process.exit(1);
    }

    var bw = std.io.bufferedWriter(stdout_file.writer());
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdin_file = std.io.getStdIn();
    const stdin = stdin_file.reader();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const print_selected_on_quit = blk: {
        if (args.len == 1) break :blk false;

        for (args[1..]) |arg|
            if (std.mem.eql(u8, "-p", arg) or std.mem.eql(u8, "--picker", arg))
                break :blk true;

        break :blk false;
    };

    var sea = try Sea.init(allocator, stdin_file);
    defer sea.deinit(stdin_file);

    try sea.appendCwdEntries(allocator);
    try sea.resetSelectionAndResize(sea.entries.len());

    var input_char: u8 = 0;
    try stdout.writeAll("\x1B[?25l");

    var cwd_buffer: [4096]u8 = undefined;
    const cwd_path = try std.process.getCwd(&cwd_buffer);
    sea.cwd = cwd_path;

    // Setup cd on quit if available
    var cd_quit: ?[]const u8 = null;
    defer if (cd_quit) |allocation| allocator.free(allocation);

    if (std.process.hasEnvVarConstant("SEA_TMPFILE"))
        cd_quit = try std.process.getEnvVarOwned(allocator, "SEA_TMPFILE");

    var past_dirs = std.StringHashMap(PastDir).init(allocator);
    defer {
        var it = past_dirs.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.idxs);
            allocator.free(entry.value_ptr.names);
        }
        past_dirs.deinit();
    }

    // Main loop
    while (true) : (input_char = try stdin.readByte()) {
        var timer = try std.time.Timer.start();

        const event = try sea.handleInput(allocator, &past_dirs, input_char, &cwd_buffer);
        switch (event) {
            .quit => break, // Quit application
            .move, .select => {},
            .ch_dir => |selection| {
                if (selection) |value|
                    try past_dirs.put(value.cwd, .{
                        .idxs = value.true_idxs,
                        .names = value.names,
                    });
            },
        }

        const end = timer.read();

        // Reset colors, clear screen, and go to top left corner
        try stdout.writeAll("\x1B[0m\x1B[2J\x1B[H");

        // Debug info
        if (builtin.mode == .Debug) {
            try stdout.print("Loop time: {}\x1B[1E", .{std.fmt.fmtDuration(end)});
            try stdout.print("Memory allocated: {d:.1}\x1B[1E", .{
                std.fmt.fmtIntSizeDec(sea.entries.names.allocatedSlice().len +
                    sea.entries.indices.allocatedSlice().len +
                    sea.selection.items.len),
            });
            try stdout.print("Terminal size: {} rows\x1B[1E", .{sea.s_win.height});
            try stdout.print("Scroll window: {}\x1B[1E", .{sea.s_win});
            try stdout.print("Cursor selection index: {}\x1B[1E", .{sea.cursor});
        }

        try sea.printStatus(stdout, blk: {
            var it = past_dirs.valueIterator();
            var total: usize = 0;
            while (it.next()) |value|
                total += value.idxs.len;

            break :blk total;
        });

        try sea.printEntries(stdout);

        try bw.flush();
    }

    // Reset colors, clear screen, go home, and enable cursor again
    try stdout_file.writeAll("\x1B[0m\x1B[?25h");

    if (cd_quit) |lastd_path| {
        const dirname = std.fs.path.dirname(lastd_path) orelse {
            std.log.err("could not get config directory for cd on quit, given" ++
                "directory was: {s}", .{lastd_path});
            std.process.exit(1);
        };

        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();

        try root.makePath(dirname);

        const file = try std.fs.createFileAbsolute(lastd_path, .{});
        defer file.close();
        try file.writer().print("cd {s}", .{sea.cwd});
    }

    // Disable alternative buffer
    try stdout_file.writeAll("\x1B[?1049l");

    if (print_selected_on_quit) {
        var it = past_dirs.iterator();
        while (it.next()) |entry| {
            const dirname = entry.key_ptr.*;
            var str_it = std.mem.splitScalar(u8, entry.value_ptr.names, 0);
            while (str_it.next()) |filename|
                try stdout.print("{s}/{s}\x1B[1E", .{ dirname, filename });
        }

        const dirname = sea.cwd;
        for (sea.selection.items, 0..) |item, idx| {
            if (item) {
                try stdout.print(
                    "{s}/{s}\x1B[1E",
                    .{ dirname, sea.entries.getNameAtEntryIndex(idx) },
                );
            }
        }
        try bw.flush();
    }
}
