const std = @import("std");
const zline = @import("./zline.zig");

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var alloc = &arena.allocator;

    // var rl = zline.Editor(Helper).init(alloc, Helper{}, .{});
    var rl = try zline.Editor(struct {}).init(alloc, null, .{});
    // defer rl.deinit(); // Run clean-up code

    while (true) {
        if (rl.readline(">> ")) |line| {
            if (std.mem.eql(u8, line, "quit")) {
                break;
            }
            _ = try std.io.getStdOut().writer().print("line: {s}\n", .{ line });
        } else |err| {
            std.debug.print("exiting: {}", .{ err });
            break;
        }
    }
}
