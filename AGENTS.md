# Agent Notes

Notes for AI agents working on this codebase.

## Zig 0.15.2 API Changes

This project uses Zig 0.15.2. Several standard library APIs have changed from earlier versions:

### ArrayList

The `std.ArrayList` is now an **unmanaged** type by default. The allocator is passed to methods, not to initialization.

```zig
// OLD (pre-0.15):
var list = std.ArrayList(T).init(allocator);
defer list.deinit();
try list.append(item);
const slice = try list.toOwnedSlice();

// NEW (0.15.2):
var list: std.ArrayList(T) = .empty;
defer list.deinit(allocator);
try list.append(allocator, item);
const slice = try list.toOwnedSlice(allocator);
```

Key differences:
- Initialize with `.empty` or just `var list: std.ArrayList(T) = .{};`
- `deinit(allocator)` takes the allocator
- `append(allocator, item)` takes the allocator as first argument
- `toOwnedSlice(allocator)` takes the allocator

### Standard I/O

The `std.io.getStdOut()` and `std.io.getStdErr()` functions no longer exist. Use `std.fs.File` directly:

```zig
// OLD (pre-0.15):
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

// NEW (0.15.2):
// Option 1: Use std.debug.print for simple output (goes to stderr)
std.debug.print("Hello {s}\n", .{"world"});

// Option 2: Use buffered writer
var buf: [4096]u8 = undefined;
const stdout = std.fs.File.stdout().writer(&buf);
try stdout.print("Hello {s}\n", .{"world"});
```

For CLI tools, `std.debug.print` is often sufficient and simpler.

### File.Writer

The writer API requires a buffer parameter:

```zig
// OLD:
const writer = file.writer();

// NEW (0.15.2):
var buf: [4096]u8 = undefined;
const writer = file.writer(&buf);
// Access the interface via writer.interface if needed
```

### Time/Epoch API

The time epoch structs have different field names:

```zig
// Getting month and day from timestamp
const ts = std.time.timestamp();
const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
const day_secs = epoch_secs.getDaySeconds();
const year_day = epoch_secs.getEpochDay().calculateYearDay();
const month_day = year_day.calculateMonthDay();

// Fields:
// - year_day.year (Year type)
// - year_day.day (u9, day of year 0-365)
// - month_day.month (Month enum)
// - month_day.day_index (u5, 0-indexed day of month)
```

### HashMap

`std.StringHashMap` and `std.HashMap` still have the managed version with `.init(allocator)`, but consider using the unmanaged variants for consistency with ArrayList.

## zig-sqlite Notes

This project uses [zig-sqlite](https://github.com/vrischmann/zig-sqlite) (branch `zig-0.15.1`).

### Dynamic vs Static Queries

- Use `db.prepare()` or `db.prepareWithDiags()` for **comptime-known** query strings
- Use `db.prepareDynamic()` or `db.prepareDynamicWithDiags()` for **runtime** query strings (e.g., when table name is a parameter)

### File Path Requirements

SQLite requires null-terminated strings for file paths:

```zig
// Convert []const u8 to [:0]const u8
const path_z = try allocator.dupeZ(u8, db_path);
defer allocator.free(path_z);

var db = try sqlite.Db.init(.{
    .mode = .{ .File = path_z },
    // ...
});
```

### execMulti Quirk

The `db.execMulti()` function may throw `error.EmptyQuery` when SQL has trailing whitespace after the last statement. Handle this case:

```zig
db.execMulti(sql, .{}) catch |err| {
    if (err == error.EmptyQuery) {
        // This is fine - SQL executed successfully
    } else {
        return err;
    }
};
```

### Iterating Dynamic Queries

For dynamic statements, use `.iterator()` or `.iteratorAlloc()`:

```zig
var stmt = try db.prepareDynamicWithDiags(query, .{});
defer stmt.deinit();

var iter = try stmt.iteratorAlloc(RowType, allocator, .{});
while (try iter.nextAlloc(allocator, .{})) |row| {
    // process row
}
```

### Reading TEXT columns

When reading `[]const u8` fields from the database, you must use `oneAlloc` or `iteratorAlloc` with an allocator - the non-allocating versions cannot read slice types.
