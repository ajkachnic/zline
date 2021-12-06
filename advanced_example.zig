const std = @import("std");
const zline = @import("./zline.zig");

pub const Helper = struct {
    // Whatever your completion result is
    pub const Candidate = struct {
        // Text to display when listing
        pub fn display(self: Candidate) []const u8 {
            _ = self;
            return "";
        }
        // Text to insert in line
        pub fn replacement(self: Candidate) []const u8 {
            _ = self;
            return "";
        }
    }; 
    // Whatever your hint result is
    pub const Hint = struct {
        text: []const u8,
        pub fn display(self: Hint) []const u8 {
            return self.text;
        }
        pub fn deinit(self: Hint) void { _ = self; }
    };
    
    pub fn complete(
        self: *Helper,
        line: []const u8,
        pos: usize,
        ctx: *zline.Context
    ) !Candidate {
        _ = self;
        _ = line;
        _ = pos;
        _ = ctx;
        return Candidate {};
    }
    
    pub fn highlight(self: *Helper, line: []const u8, pos: usize) []const u8 {
        _ = self;
        _ = pos;
        return line;
    }
    
    pub fn hint(
        self: *Helper,
        line: []const u8,
        pos: usize,
        // ctx: *zline.Context
    ) !?Hint {
        _ = self;
        _ = line;
        _ = pos;

        if (std.mem.eql(u8, line, "hello")) {
            return Hint { .text = " world" };
        }
        // _ = ctx;
        return null;
    }
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var alloc = &arena.allocator;
    var helper = Helper{};

    // var rl = zline.Editor(Helper).init(alloc, Helper{}, .{});
    var rl = try zline.Editor(Helper).init(alloc, helper, .{});
    // defer rl.deinit(); // Run clean-up code

    while (true) {
        if (rl.readline(">> ")) |line| {
            if (std.mem.eql(u8, line, "quit")) {
                break;
            }
            _ = try std.io.getStdOut().writer().print("line: {s}\n", .{ line });
        } else |err| {
            std.debug.print("\nexiting: {}", .{ err });
            break;
        }
    }
}
