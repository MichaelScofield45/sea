const std = @import("std");
const linux = std.os.linux;
const EntryList = @import("entry_list.zig");

const sea = @import("sea.zig");
const State = sea.State;

pub fn main() !void {
    const stdout_file = std.io.getStdOut();
    const config = std.io.tty.detectConfig(stdout_file);

    var bw = std.io.bufferedWriter(stdout_file.writer());
    const stdout = bw.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var dir_list = try EntryList.initCapacity(allocator, 1024);
    defer dir_list.deinit();

    var file_list = try EntryList.initCapacity(allocator, 1024);
    defer file_list.deinit();

    try sea.appendCwdEntries(&dir_list, &file_list);

    const stdin_file = std.io.getStdIn();
    const stdin = stdin_file.reader();

    // Setup terminal and state
    var state = State{
        .cursor = 0,
        .running = true,
        .cwd_name = undefined,
        .original_termios = undefined,
    };

    try sea.init(stdin_file, &state);
    defer sea.deinit(stdin_file, state);

    var input_char: u8 = 0;
    try stdout.writeAll("\x1B[?25l");

    // Main loop
    while (state.running) : (input_char = try stdin.readByte()) {
        var cwd_buffer: [4096]u8 = undefined;
        const cwd_path = try std.process.getCwd(&cwd_buffer);
        state.cwd_name = std.fs.path.basename(cwd_path);

        try sea.handleInput(input_char, &state, &dir_list, &file_list);
        if (!state.running) break;

        // Reset colors and clear screen
        try stdout.writeAll("\x1B[0m\x1B[2J\x1B[H");

        try stdout.print("Memory allocated: {d:.1}\x1B[1E", .{
            std.fmt.fmtIntSizeDec(dir_list.names.allocatedSlice().len +
                dir_list.end_indices.allocatedSlice().len +
                file_list.names.allocatedSlice().len +
                file_list.end_indices.allocatedSlice().len),
        });

        try stdout.print("Cursor selection index: {}\x1B[2E", .{state.cursor});

        try config.setColor(stdout, .blue);
        try config.setColor(stdout, .bold);

        // TODO: Handle logic for scrolling
        for (dir_list.getEndIndices(), 0..) |_, entry_idx| {
            if (entry_idx == state.cursor)
                try stdout.writeAll("\x1B[30;44m")
            else
                try stdout.writeAll("\x1B[1;34;49m");

            try stdout.print("{s}\x1B[1E", .{dir_list.getNameAtEntryIndex(entry_idx)});
        }

        try config.setColor(stdout, .reset);
        for (file_list.getEndIndices(), 0..) |_, entry_idx| {
            if (entry_idx + dir_list.getTotalEntries() == state.cursor)
                try stdout.writeAll("\x1B[30;47m")
            else
                try stdout.writeAll("\x1B[0m");

            try stdout.print("{s}\x1B[1E", .{file_list.getNameAtEntryIndex(entry_idx)});
        }

        try bw.flush();
    }

    // Reset colors, clear screen, go home, and enable cursor again
    try stdout_file.writeAll("\x1B[0m\x1B[2J\x1B[H\x1B[?25h");
}
