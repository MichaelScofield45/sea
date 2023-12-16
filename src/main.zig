const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const page_allocator = std.heap.page_allocator;

const sea = @import("sea.zig");

const ArgFlags = struct {
    print_selection: bool = false,
};

pub fn main() !void {
    var args_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer args_arena.deinit();
    const args_alloc = args_arena.allocator();

    // TODO: parse arguments and validate
    const args = try std.process.argsAlloc(args_alloc);
    _ = args;

    try sea.main();

    // Reset colors, clear screen, go home, and enable cursor again
    // try stdout_f.writeAll("\x1B[0m\x1B[?25h");
    //
    // if (cd_quit) |lastd_path| {
    //     const dirname = std.fs.path.dirname(lastd_path) orelse {
    //         std.log.err("could not get config directory for cd on quit, given" ++
    //             "directory was: {s}", .{lastd_path});
    //         std.process.exit(1);
    //     };
    //
    //     var root = try std.fs.openDirAbsolute("/", .{});
    //     defer root.close();
    //
    //     try root.makePath(dirname);
    //
    //     const file = try std.fs.createFileAbsolute(lastd_path, .{});
    //     defer file.close();
    //     try file.writer().print("cd {s}", .{cwd});
    // }
    //
    // // Disable alternative buffer
    // try stdout_f.writeAll("\x1B[?1049l");
}
