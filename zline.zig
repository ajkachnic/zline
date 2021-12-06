const std = @import("std");
const testing = std.testing;

const ArrayList = std.ArrayList;

const MAX_LINE = 4096;

var maskmode: bool = false;
var rawmode: bool = false;
var mlmode: bool = false;

const unsupported_terms: []const []const u8 = &.{ "dumb", "cons25", "emacs", "ansi" };
const VTIME = 5;
const VMIN = 6;

const TIOCGWINSZ = 0x5413;

var history: [][]u8 = undefined;
var orig_termios: std.os.termios = undefined;

var stdin = std.io.getStdIn(); // stdin file descriptor
var stdout = std.io.getStdOut(); // stdout file descriptor
var stderr = std.io.getStdErr(); // stderr file descriptor

var stdoutWriter = std.io.bufferedWriter(stdout.writer());

pub const Completions = ArrayList([]const u8);

pub const KeyAction = enum(u8) {
    nil = 0, // No KeyAction
    ctrl_a = 1, // Ctrl-A
    ctrl_b = 2, // Ctrl-B
    ctrl_c = 3, // Ctrl-C
    ctrl_d = 4, // Ctrl-D
    ctrl_e = 5, // Ctrl-E
    ctrl_f = 6, // Ctrl-F
    ctrl_h = 8, // Ctrl-h
    tab = 9, // tab
    ctrl_k = 11, // Ctrl-K
    ctrl_l = 12, // Ctrl-L
    enter = 13, // Enter
    ctrl_n = 14, // Ctrl-N
    ctrl_p = 16, // Ctrl-P
    ctrl_t = 20, // Ctrl-T
    ctrl_u = 21, // Ctrl-U
    ctrl_w = 23, // Ctrl-W
    esc = 27, // Escape
    backspace = 127, // Backspace
};

pub fn maskModeEnable() void {
    maskmode = true;
}

/// Disable mask mode.
pub fn maskModeDisable() void {
    maskmode = false;
}

/// Set whether or not to use multi-line mode.
pub fn setMultiline(ml: bool) void {
    mlmode = ml;
}
pub fn isUnsupportedTerm() bool {
    var maybe_term = std.os.getenv("TERM");

    if (maybe_term) |term| {
        for (unsupported_terms) |unsupported_term| {
            if (std.mem.eql(u8, term, unsupported_term)) {
                return true;
            }
        }
    }

    return false;
}

pub const Context = struct {};

// ========== Low-level terminal handling ==========

/// Enable "mask mode". When it is enabled, instead of the input that
/// the user is typing, the terminal will just display a corresponding
/// number of asterisks, like "****". This is useful for passwords and
/// other secrets that should not be displayed.
pub fn enableRawMode(file: std.fs.File) !void {
    if (!file.isTty()) {
        return error.NotTTY;
    }
    orig_termios = std.os.tcgetattr(file.handle) catch {
        return error.FailedToGetTermios;
    };
    var raw = orig_termios;

    // zig fmt: off
    // input modes: no break, no CR to NL, no parity check, no strip
    // char, no start/stop output control.
    raw.iflag &= 
        ~(@intCast(u32, std.os.linux.BRKINT | std.os.linux.ICRNL 
        | std.os.linux.INPCK | std.os.linux.ISTRIP | std.os.linux.IXON));
    // output modes - disable post processing
    raw.oflag &= ~(@intCast(u32, std.os.linux.OPOST));
    // control modes - set 8 bit chars
    raw.cflag |= (std.os.linux.CS8);
    // local modes - echoing off, canonical off, no extended 
    // functions, no signal chars (^Z,^C)
    raw.lflag &= ~(@intCast(u32, std.os.linux.ECHO | std.os.linux.ICANON  | std.os.linux.IEXTEN | std.os.linux.ISIG));
    // control chars - set return condition: min number of bytes and timer.
    // We want to read to return every single byte, without timeout.
    raw.cc[VMIN] = 1;
    raw.cc[VTIME] = 0;
    // zig fmt: on
    std.os.tcsetattr(file.handle, std.os.TCSA.FLUSH, raw) catch {
        return error.FailedToPutTermInRawMode;
    };

    rawmode = true;
}

pub fn disableRawMode() !void {
    if (rawmode) {
        std.os.tcsetattr(stdin.handle, std.os.TCSA.FLUSH, orig_termios) catch {
            return error.FailedToRestoreTermios;
        };
        rawmode = false;
    }
}

pub fn deinit() void {
    disableRawMode() catch {
        std.debug.warn("Failed to disable raw mode", .{});
    };
}

pub fn getCursorPosition() !u32 {
    var out_buf: [32]u8 = [_]u8{0} ** 32;
    var i: u32 = 0;

    _ = try stdout.write("\x1b[6n");

    var reader = stdin.reader();
    var size = reader.read(&out_buf) catch 0;

    while (i < size) {
        if (out_buf[i] == 'R') {
            break;
        }
        i += 1;
    }
    if (out_buf[0] != @enumToInt(KeyAction.esc) or out_buf[1] != '[') {
        return error.InvalidEscapeResponse;
    }

    var rows_slice = std.mem.sliceTo(out_buf[2..], ';');
    var cols_slice = std.mem.sliceTo(out_buf[rows_slice.len + 3 ..], 'R');

    var columns = try std.fmt.parseUnsigned(u32, cols_slice, 10);
    _ = try std.fmt.parseUnsigned(i32, rows_slice, 10);

    return columns;
}

/// Try to get the number of columns in the current terminal.
/// Or assume 80 if it fails
fn getColumns() u32 {
    var ws: std.os.linux.winsize = .{
        .ws_row = 0,
        .ws_col = 0,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    if (std.os.linux.ioctl(stdout.handle, TIOCGWINSZ, @ptrToInt(&ws)) != 0 and ws.ws_col == 0) {
        // ioctl() failed, try to get the columns from the
        // terminal itself.
        var start = getCursorPosition() catch return 80;

        // Go to right margin and get position
        _ = stdin.write("\x1b[999C") catch return 80;
        var columns = getCursorPosition() catch return 80;

        // Restore position
        if (columns > start) {
            stdin.writer().print("\x1b[{d}D", .{columns - start}) catch {
                // Can't recover
            };
        }

        return columns;
    } else {
        return ws.ws_col;
    }
}

// Clear the screen. Used to handle ctrl+l
fn clearScreen() void {
    stdin.write("\x1b[H\x1b[2J") catch {};
}

// Beep, used for completion when there is nothing to complete or when all
// the choices were already shown.
fn beep() void {
    stderr.write("\x07") catch {};
}

pub fn addCompletion(lc: *Completions, str: []const u8) !void {
    try lc.append(str);
}

// ========== Line editing ==========
// fn refreshShowHints(state: State) void {}

pub fn Editor(comptime Helper: type) type {
    return struct {
        const Self = @This();
        const State = struct {
            prompt: []const u8, // Prompt to display
            pos: u64 = 0, // Current cursor position
            oldpos: u64 = 0, // Previous refresh cursor position
            cols: u64, // Number of columns in terminal
            maxrows: u64, // Maximum number of rows in terminal (multiline mode)
            history_index: u64, // History index we are currently editing

            pub fn init() State {
                return State{
                    .prompt = "",
                    .pos = 0,
                    .oldpos = 0,
                    .cols = 0,
                    .maxrows = 0,
                    .history_index = 0,
                };
            }
        };
        const History = struct {
            index: usize,
            history: std.ArrayList([]const u8),
        };
        const Hint = if (@hasDecl(Helper, "Hint")) Helper.Hint else struct {
            const This = @This();
            fn display(self: This) []const u8 {
                _ = self;
                return "";
            }
            fn deinit(self: This) void { _ = self; }
        };
        const Candidate = if (@hasDecl(Helper, "Candidate")) Helper.Candidate else struct {
            const This = @This();
            fn display(self: This) []const u8 {
                _ = self;
                return "";
            }
            fn replacement(self: This) []const u8 {
                _ = self;
                return "";
            }
        };

        pub const ReadlineError = error{
            Eof, // Ctrl-D
            Interupted, // Ctrl-C
        };

        alloc: *std.mem.Allocator,
        buffer: std.ArrayList(u8),
        state: State,
        stdin: std.fs.File,
        stdout: std.fs.File,
        stderr: std.fs.File,
        helper: ?Helper,

        pub fn init(alloc: *std.mem.Allocator, helper: ?Helper, comptime options: anytype) !Self {
            _ = options;
            return Self{
                .alloc = alloc,
                .state = State.init(),
                .buffer = try std.ArrayList(u8).initCapacity(alloc, 4096),
                .helper = helper,

                .stdin = std.io.getStdIn(),
                .stdout = std.io.getStdOut(),
                .stderr = std.io.getStdErr(),
            };
        }

        pub fn readline(self: *Self, prompt: []const u8) ![]u8 {
            var buf = try std.ArrayList(u8).initCapacity(self.alloc, 4096);
            if (!self.stdin.isTty()) {
                // Not a tty: read from file / pipe. In this mode we don't want any
                // limit to the line size, so we call a function to handle that
                return (try self.readlineNoTty()) orelse "";
            } else if (isUnsupportedTerm()) {
                try self.stdout.writeAll(prompt);
                // TODO: Only read to newline
                // TODO: Consider readAllAlloc here instead
                try self.stdin.reader().readAllArrayList(&buf, MAX_LINE);
                return self.buffer.toOwnedSlice();
            } else {
                try self.readlineRaw(buf, prompt);
                return self.buffer.toOwnedSlice();
            }
        }

        fn readlineNoTty(self: *Self) !?[]u8 {
            return self.stdin.reader().readUntilDelimiterOrEofAlloc(self.alloc, '\n', 1024 * 1024);
        }

        fn readlineRaw(self: *Self, buf: std.ArrayList(u8), prompt: []const u8) !void {
            try enableRawMode(self.stdin);
            self.edit(buf, prompt) catch |err| {
                disableRawMode() catch {};
                return err;
            };
            disableRawMode() catch {};
            _ = try self.stdout.write("\n");
        }

        fn edit(self: *Self, buf: std.ArrayList(u8), prompt: []const u8) !void {
            self.buffer = buf;
            self.state.prompt = prompt;
            self.state.oldpos = 0;
            self.state.pos = 0;
            self.state.cols = getColumns();
            self.state.maxrows = 0;
            self.state.history_index = 0;

            try self.stdout.writeAll(prompt);

            loop: while (true) {
                var ch = try self.stdin.reader().readByte();

                // TODO: Handle autocomplete here
                switch (ch) {
                    @enumToInt(KeyAction.enter) => {
                        // if (self.mlmode) {
                        //     try self.editMoveEnd();
                        // }
                        try self._refreshLine(false);
                        break :loop;
                    },
                    @enumToInt(KeyAction.backspace) => {
                        try self.editBackspace();
                    },
                    @enumToInt(KeyAction.ctrl_c) => return ReadlineError.Interupted,
                    @enumToInt(KeyAction.ctrl_d) => {
                        // remove char at right, or if line is empty, act as
                        // end-of-file
                        if (self.buffer.items.len > 0) {
                            try self.editDelete();
                        } else {
                            return ReadlineError.Eof;
                        }
                    },
                    @enumToInt(KeyAction.esc) => {
                        var a = try self.stdin.reader().readByte();
                        var b = try self.stdin.reader().readByte();
                        if (a == '[') {
                            if (b >= '0' and b <= '9') {
                                // Extended escape, read additional byte
                                var c = try self.stdin.reader().readByte();
                                if (c == '~') {
                                    if (b == '3') {
                                        // Delete key
                                        try self.editDelete();
                                    }
                                }
                            } else {
                                switch (b) {
                                    'A' => {}, // Up
                                    'B' => {}, // Down
                                    'C' => try self.editMoveRight(), // Right
                                    'D' => try self.editMoveLeft(), // Left
                                    'H' => {}, // Home
                                    'F' => {}, // End
                                    else => {},
                                }
                            }
                        }
                    },
                    else => {
                        try self.editInsert(ch);
                    },
                }
            }
        }

        /// Insert the character `c` at cursor current position
        fn editInsert(self: *Self, c: u8) !void {
            try self.buffer.insert(self.state.pos, c);
            self.state.pos += 1;
            try self.refreshLine();
        }


        /// Move cursor on the left.
        fn editMoveLeft(self: *Self) !void {
            if (self.state.pos > 0) {
                self.state.pos -= 1;
                try self.refreshLine();
            }
        }

        /// Move cursor on the right.
        fn editMoveRight(self: *Self) !void {
            if (self.state.pos != self.buffer.items.len) {
                self.state.pos += 1;
                try self.refreshLine();
            }
        }


        /// Move cursor to the end of the line.
        fn editMoveHome(self: *Self) !void {
            if (self.state.pos != 0) {
                self.state.pos = 0;
                try self.refreshLine();
            }
        }
        /// Move cursor to the end of the line.
        fn editMoveEnd(self: *Self) !void {
            if (self.state.pos != self.buffer.items.len) {
                self.state.pos = self.buffer.items.len;
                try self.refreshLine();
            }
        }

        /// Backspace implementation.
        fn editBackspace(self: *Self) !void {
            if (self.state.pos > 0 and self.buffer.items.len > 0) {
                if (self.buffer.items.len > self.state.pos) {
                    _ = self.buffer.orderedRemove(self.state.pos);
                } else {
                    _ = self.buffer.pop();
                }
                self.state.pos -= 1;
                try self.refreshLine();
            }
        }

        /// Delete the character at right of the cursor without altering the cursor
        /// position. Basically this is what happens with the "Delete" keyboard key
        fn editDelete(self: *Self) !void {
            if (self.state.pos >= 0 and self.state.pos < self.buffer.items.len) {
                _ = self.buffer.orderedRemove(self.state.pos);
                try self.refreshLine();
            }
        }
        fn refreshLine(self: *Self) !void {
            return self._refreshLine(true);
        }

        fn _refreshLine(self: *Self, show_hints: bool) !void {
            // TODO: Support multiline here
            var bufp: usize = 0;
            var len = self.buffer.items.len;
            var pos = self.state.pos;
            var writer = std.io.bufferedWriter(self.stdout.writer());

            // Not really sure what this is doing but linenoise does it too
            // "If your friend jumped off a bridge would you do it too???" shut up
            while ((self.state.prompt.len + pos) >= self.state.cols) {
                bufp += 1;
                len -= 1;
                pos -= 1;
            }
            while ((self.state.prompt.len + len) > self.state.cols) {
                len -= 1;
            }

            _ = try writer.write("\r");
            // Write the prompt and the current buffer content
            _ = try writer.write(self.state.prompt);
            if (maskmode) {
                while (len > 0) {
                    _ = try writer.write("*");
                    len -= 1;
                }
            } else {
                _ = try writer.write(self.buffer.items[bufp .. len - bufp]);
            }
            try writer.flush();
            if (show_hints) {
                try self.refreshShowHints(self.state.prompt.len);
            }
            // Erase to right
            _ = try writer.write("\x1b[0K");
            // Move cursor to original position
            _ = try writer.writer().print("\r\x1b[{d}C", .{pos + self.state.prompt.len});
            try writer.flush();
        }

        fn refreshShowHints(self: *Self, plen: usize) !void {
            var writer = std.io.bufferedWriter(self.stdout.writer());
            if (try self.getHint()) |hint| {
                defer hint.deinit();
                var color: u8 = 90; // TODO: Allow customing color
                var bold = false;

                var hint_text = hint.display();
                var max_len = self.state.cols - (plen + self.buffer.items.len);
                if (hint_text.len > max_len) hint_text = hint_text[0..max_len - 1];
                _ = try writer.writer().print("\x1b[{d};{d};49m", .{ @boolToInt(bold), color });
                _ = try writer.write(hint_text);
                _ = try writer.write("\x1b[0m");
                try writer.flush();
            }
        }

        // helper utilities
        fn getHint(self: *Self) !?Hint {
            if (self.helper) |helper| {
                if (comptime std.meta.trait.hasFn("hint")(Helper)) {
                    // Use helper function if available
                    return try Helper.hint(helper, self.buffer.items, self.state.pos);
                } else {
                    // Otherwise, default to nothing
                    return null;
                }
            }
            std.debug.print("no helper", .{});
            return null;
        }
    };
}


pub const Term = struct {
    cols: u64, // Number of columns in terminal
    maxrows: u64, // Maximum number of rows in terminal (multiline mode)
};

// Note: I don't really know how to test a line editor lmao
test "toggle raw mode" {
    try enableRawMode(stdin);
    std.debug.print("cols: {d}", .{try getCursorPosition()});
    std.debug.warn("cols: {d}", .{getColumns()});
    try disableRawMode();

    deinit();
}
