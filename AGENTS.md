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

## Native SQLite Bindings

This project uses bundled SQLite source (`deps/sqlite/sqlite3.c`) with native C bindings in `src/sqlite.zig`. No external SQLite library dependencies are required.

### Opening a Database

```zig
const sqlite = @import("sqlite");

// Open database (SQLite is auto-initialized on first use)
const path_z = try allocator.dupeZ(u8, db_path);
defer allocator.free(path_z);

var db = try sqlite.Db.open(path_z, .{ .write = true, .create = true });
defer db.deinit();
```

### Executing SQL

```zig
// Execute single statement (null-terminated)
try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY)");

// Execute multiple statements
try db.execMulti("CREATE TABLE a (id INT); CREATE TABLE b (id INT);");
```

### Prepared Statements

```zig
// For compile-time known SQL (null-terminated)
var stmt = try db.prepare("SELECT name FROM users WHERE id = ?");
defer stmt.deinit();

// For runtime SQL
var stmt2 = try db.prepareDynamic(allocator, sql_string);
defer stmt2.deinit();

// Bind parameters (1-indexed)
try stmt.bindText(1, name);
try stmt.bindNull(2);

// Execute and iterate
while (try stmt.step()) {
    const name = stmt.columnText(0);  // Returns ?[]const u8
    const id = stmt.columnInt(1);      // Returns i32
}

// Or get allocated copy
const name = try stmt.columnTextAlloc(allocator, 0);
```

### Building

The project builds statically linked binaries for distribution:

```bash
# Debug build (native)
zig build

# Static release binaries for all platforms
zig build release

# Output in zig-out/{arch}-{os}/
```
