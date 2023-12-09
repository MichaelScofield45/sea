const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const page_allocator = std.heap.page_allocator;

const sea = @import("sea.zig");

pub fn main() !void {
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
