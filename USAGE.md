# zline usage

## Helpers

After looking the first example, you may be curious about a number of features, like:

- Hints
- Completion
- Highlighting
- Validation

All of these features are provided by something called a *helper*. You define your own helper type, and it can provide the following functions:

```zig
pub const Helper = struct {
    // Whatever your completion result is
    pub const Candidate = struct {
        // Text to display when listing
        pub fn display(self: Candidate) []const u8 {}
        // Text to insert in line
        pub fn replacement(self: Candidate) []const u8 {}
    }; 
    // Whatever your hint result is
    pub const Hint = struct {
        pub fn display(self: Hint) []const u8 {}
    };
    
    pub fn complete(
        self: *Helper,
        line: []const u8,
        pos: usize,
        ctx: *zline.Context
    ) !Candidate {}
    
    pub fn highlight(self: *Helper, line: []const u8, pos: usize) []const u8 {}
    
    pub fn hint(
        self: *Helper,
        line: []const u8,
        pos: usize,
        ctx: *zline.Context
    ) !Hint {}
};
```

We'll clarify how to write for all of these features soon, but this is the basic shape of a *complete* helper. You don't need all of these functions if you only want to implement a couple things, like only highlighting or just completion.

