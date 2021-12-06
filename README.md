# zline

A simple yet powerful line editor for Zig.

## Usage

After installing, getting up and running is pretty simple:

```zig
const std = @import("std");
const zline = @import("zline.zig"); // Or however you have this set up

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init();
    defer arena.deinit();

    var alloc = &arena.allocator;

    var rl = zline.Editor(struct {}).init(alloc, null, .{});
    defer rl.deinit(); // Run clean-up code

    while (true) {
        if (rl.readline(">> ")) |line| {
            if (std.mem.eql(u8, line, "quit")) {
                break;
            }
            std.io.getStdOut().writer().print("line: {s}", .{ line });
            // If not using an arena allocator, make sure you call `alloc.free` here
        } else |err| {
            return err;
        }
    }
}
```

More advanced usage is covered in [`USAGE.md`](/USAGE.md) and the examples. API documentation is in [`API.md`](/API.md)

## Why not use `linenoise`?

Since Zig has easy to use C bindings, why shouldn't you just use `linenoise`? Off the bat, I'd say `linenoise` is a wonderful library. It achieves all of it's goals, and I'd take it any day over readline.

However, `linenoise` does not satisfy many of Zig's goals/best practices, like:

- Allowing custom memory allocators
- Using Zig style `try`/`catch` error handling

In addition, it's API isn't as clean as a pure Zig API. Besides all these things, I also just wanted to try my hand at writing a line editor.

## Prior Work

- [linenoise](https://github.com/antirez/linenoise/)
- [rustyline](https://docs.rs/rustyline/9.0.0/rustyline/)
- [readline](https://tiswww.case.edu/php/chet/readline/rltop.html)
