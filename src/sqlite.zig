/// Native SQLite3 bindings using the C API
const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const Allocator = std.mem.Allocator;

pub const Error = error{
    SqliteError,
    SqliteConstraint,
    SqliteBusy,
    SqliteCorrupt,
    InvalidSql,
    OutOfMemory,
};

var initialized: bool = false;

/// Initialize SQLite. Must be called before any other SQLite functions.
/// Safe to call multiple times.
pub fn init() Error!void {
    if (initialized) return;
    const rc = c.sqlite3_initialize();
    if (rc != c.SQLITE_OK) {
        return Error.SqliteError;
    }
    initialized = true;
}

pub const OpenFlags = struct {
    write: bool = true,
    create: bool = true,
};

/// SQLite database connection
pub const Db = struct {
    handle: *c.sqlite3,

    pub fn open(path: [:0]const u8, flags: OpenFlags) Error!Db {
        // Initialize SQLite if needed
        try init();

        var open_flags: c_int = c.SQLITE_OPEN_READWRITE;
        if (flags.create) {
            open_flags |= c.SQLITE_OPEN_CREATE;
        }
        if (!flags.write) {
            open_flags = c.SQLITE_OPEN_READONLY;
        }

        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &handle, open_flags, null);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| {
                _ = c.sqlite3_close(h);
            }
            return Error.SqliteError;
        }

        return Db{ .handle = handle.? };
    }

    pub fn deinit(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Execute SQL that doesn't return rows
    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql.ptr, null, null, &err_msg);
        if (err_msg) |msg| {
            c.sqlite3_free(msg);
        }
        if (rc != c.SQLITE_OK) {
            return mapError(rc);
        }
    }

    /// Execute multiple SQL statements (semicolon separated)
    pub fn execMulti(self: *Db, sql: []const u8) Error!void {
        if (std.mem.indexOfScalar(u8, sql, 0) != null) {
            return Error.InvalidSql;
        }

        // sqlite3_exec requires null-terminated string
        var buf: [64 * 1024]u8 = undefined;
        if (sql.len >= buf.len) {
            return Error.OutOfMemory;
        }
        @memcpy(buf[0..sql.len], sql);
        buf[sql.len] = 0;

        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, &buf, null, null, &err_msg);
        if (err_msg) |msg| {
            c.sqlite3_free(msg);
        }
        if (rc != c.SQLITE_OK) {
            return mapError(rc);
        }
    }

    /// Prepare a statement
    pub fn prepare(self: *Db, sql: [:0]const u8) Error!Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            return mapError(rc);
        }
        return Statement{ .handle = stmt.?, .db = self };
    }

    /// Prepare a statement from non-null-terminated string
    pub fn prepareDynamic(self: *Db, allocator: Allocator, sql: []const u8) (Error || Allocator.Error)!Statement {
        const sql_z = try allocator.dupeZ(u8, sql);
        defer allocator.free(sql_z);

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql_z.ptr, @intCast(sql_z.len + 1), &stmt, null);
        if (rc != c.SQLITE_OK) {
            return mapError(rc);
        }
        return Statement{ .handle = stmt.?, .db = self };
    }

    /// Get last error message
    pub fn getErrorMessage(self: *Db) []const u8 {
        const msg = c.sqlite3_errmsg(self.handle);
        if (msg) |m| {
            return std.mem.span(m);
        }
        return "unknown error";
    }

    fn mapError(rc: c_int) Error {
        return switch (rc) {
            c.SQLITE_CONSTRAINT => Error.SqliteConstraint,
            c.SQLITE_BUSY => Error.SqliteBusy,
            c.SQLITE_CORRUPT => Error.SqliteCorrupt,
            c.SQLITE_NOMEM => Error.OutOfMemory,
            else => Error.SqliteError,
        };
    }
};

/// SQLite prepared statement
pub const Statement = struct {
    handle: *c.sqlite3_stmt,
    db: *Db,

    pub fn deinit(self: *Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    /// Reset statement for re-execution
    pub fn reset(self: *Statement) void {
        _ = c.sqlite3_reset(self.handle);
    }

    /// Bind text parameter (1-indexed)
    pub fn bindText(self: *Statement, index: c_int, value: []const u8) Error!void {
        const rc = c.sqlite3_bind_text(self.handle, index, value.ptr, @intCast(value.len), c.SQLITE_TRANSIENT);
        if (rc != c.SQLITE_OK) {
            return Db.mapError(rc);
        }
    }

    /// Bind null parameter (1-indexed)
    pub fn bindNull(self: *Statement, index: c_int) Error!void {
        const rc = c.sqlite3_bind_null(self.handle, index);
        if (rc != c.SQLITE_OK) {
            return Db.mapError(rc);
        }
    }

    /// Execute statement that doesn't return rows
    pub fn exec(self: *Statement) Error!void {
        const rc = c.sqlite3_step(self.handle);
        if (rc != c.SQLITE_DONE and rc != c.SQLITE_ROW) {
            return Db.mapError(rc);
        }
    }

    /// Step to next row, returns false if no more rows
    pub fn step(self: *Statement) Error!bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) {
            return true;
        } else if (rc == c.SQLITE_DONE) {
            return false;
        } else {
            return Db.mapError(rc);
        }
    }

    /// Get column count
    pub fn columnCount(self: *Statement) c_int {
        return c.sqlite3_column_count(self.handle);
    }

    /// Get text column value (0-indexed)
    pub fn columnText(self: *Statement, index: c_int) ?[]const u8 {
        const text = c.sqlite3_column_text(self.handle, index);
        if (text == null) {
            return null;
        }
        const len = c.sqlite3_column_bytes(self.handle, index);
        if (len <= 0) {
            return "";
        }
        return text[0..@intCast(len)];
    }

    /// Get text column value and duplicate it (0-indexed)
    pub fn columnTextAlloc(self: *Statement, allocator: Allocator, index: c_int) Allocator.Error!?[]const u8 {
        const text = self.columnText(index);
        if (text) |t| {
            return try allocator.dupe(u8, t);
        }
        return null;
    }

    /// Get integer column value (0-indexed)
    pub fn columnInt(self: *Statement, index: c_int) i32 {
        return c.sqlite3_column_int(self.handle, index);
    }

    /// Get int64 column value (0-indexed)
    pub fn columnInt64(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, index);
    }

    /// Check if column is NULL (0-indexed)
    pub fn columnIsNull(self: *Statement, index: c_int) bool {
        return c.sqlite3_column_type(self.handle, index) == c.SQLITE_NULL;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "init can be called multiple times" {
    try init();
    try init();
    try init();
}

test "open and close in-memory database" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();
}

test "open database with read-only flag on non-existent file fails" {
    const result = Db.open("/nonexistent/path/db.sqlite", .{ .write = false, .create = false });
    try std.testing.expectError(Error.SqliteError, result);
}

test "exec creates table" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");

    // Verify table exists
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='test'");
    defer stmt.deinit();

    const has_row = try stmt.step();
    try std.testing.expect(has_row);
    try std.testing.expectEqualStrings("test", stmt.columnText(0).?);
}

test "exec with invalid SQL returns error" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    const result = db.exec("INVALID SQL SYNTAX");
    try std.testing.expectError(Error.SqliteError, result);
}

test "execMulti runs multiple statements" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.execMulti(
        \\CREATE TABLE a (id INTEGER);
        \\CREATE TABLE b (id INTEGER);
        \\INSERT INTO a VALUES (1);
        \\INSERT INTO b VALUES (2);
    );

    // Verify both tables exist and have data
    var stmt_a = try db.prepare("SELECT id FROM a");
    defer stmt_a.deinit();
    try std.testing.expect(try stmt_a.step());
    try std.testing.expectEqual(@as(i32, 1), stmt_a.columnInt(0));

    var stmt_b = try db.prepare("SELECT id FROM b");
    defer stmt_b.deinit();
    try std.testing.expect(try stmt_b.step());
    try std.testing.expectEqual(@as(i32, 2), stmt_b.columnInt(0));
}

test "execMulti with SQL too large returns error" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    // Create SQL larger than 64KB buffer
    const large_sql = "SELECT 1;" ** 10000;
    const result = db.execMulti(large_sql);
    try std.testing.expectError(Error.OutOfMemory, result);
}

test "prepare and execute SELECT" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)");
    try db.exec("INSERT INTO users (name, age) VALUES ('Alice', 30)");
    try db.exec("INSERT INTO users (name, age) VALUES ('Bob', 25)");

    var stmt = try db.prepare("SELECT name, age FROM users ORDER BY name");
    defer stmt.deinit();

    // First row
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("Alice", stmt.columnText(0).?);
    try std.testing.expectEqual(@as(i32, 30), stmt.columnInt(1));

    // Second row
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("Bob", stmt.columnText(0).?);
    try std.testing.expectEqual(@as(i32, 25), stmt.columnInt(1));

    // No more rows
    try std.testing.expect(!try stmt.step());
}

test "prepareDynamic works with runtime string" {
    const allocator = std.testing.allocator;

    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (value TEXT)");
    try db.exec("INSERT INTO test VALUES ('hello')");

    const table_name = "test";
    const sql = try std.fmt.allocPrint(allocator, "SELECT value FROM {s}", .{table_name});
    defer allocator.free(sql);

    var stmt = try db.prepareDynamic(allocator, sql);
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("hello", stmt.columnText(0).?);
}

test "bindText and bindNull" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)");

    var insert = try db.prepare("INSERT INTO test (name) VALUES (?)");
    defer insert.deinit();

    // Insert with text
    try insert.bindText(1, "Alice");
    try insert.exec();

    // Reset and insert with NULL
    insert.reset();
    try insert.bindNull(1);
    try insert.exec();

    // Verify
    var select = try db.prepare("SELECT name FROM test ORDER BY id");
    defer select.deinit();

    try std.testing.expect(try select.step());
    try std.testing.expectEqualStrings("Alice", select.columnText(0).?);

    try std.testing.expect(try select.step());
    try std.testing.expect(select.columnIsNull(0));
    try std.testing.expect(select.columnText(0) == null);
}

test "columnTextAlloc duplicates string" {
    const allocator = std.testing.allocator;

    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (name TEXT)");
    try db.exec("INSERT INTO test VALUES ('hello world')");

    var stmt = try db.prepare("SELECT name FROM test");
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());

    const text = try stmt.columnTextAlloc(allocator, 0);
    defer if (text) |t| allocator.free(t);

    try std.testing.expectEqualStrings("hello world", text.?);
}

test "columnInt64 for large values" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (big_num INTEGER)");
    try db.exec("INSERT INTO test VALUES (9223372036854775807)"); // Max i64

    var stmt = try db.prepare("SELECT big_num FROM test");
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());
    try std.testing.expectEqual(@as(i64, 9223372036854775807), stmt.columnInt64(0));
}

test "columnCount returns correct count" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (a INT, b INT, c INT, d INT)");

    var stmt = try db.prepare("SELECT a, b, c, d FROM test");
    defer stmt.deinit();

    try std.testing.expectEqual(@as(c_int, 4), stmt.columnCount());
}

test "getErrorMessage returns meaningful message" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    // Cause an error
    _ = db.exec("INVALID") catch {};

    const msg = db.getErrorMessage();
    try std.testing.expect(msg.len > 0);
    try std.testing.expect(!std.mem.eql(u8, msg, "unknown error"));
}

test "constraint violation returns SqliteConstraint" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (id INTEGER PRIMARY KEY)");
    try db.exec("INSERT INTO test VALUES (1)");

    const result = db.exec("INSERT INTO test VALUES (1)"); // Duplicate primary key
    try std.testing.expectError(Error.SqliteConstraint, result);
}

test "statement reset allows re-execution" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (id INTEGER)");
    try db.exec("INSERT INTO test VALUES (1), (2), (3)");

    var stmt = try db.prepare("SELECT id FROM test");
    defer stmt.deinit();

    // First iteration
    var count: usize = 0;
    while (try stmt.step()) {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);

    // Reset and iterate again
    stmt.reset();
    count = 0;
    while (try stmt.step()) {
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "empty string column" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (name TEXT)");
    try db.exec("INSERT INTO test VALUES ('')");

    var stmt = try db.prepare("SELECT name FROM test");
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());
    try std.testing.expect(!stmt.columnIsNull(0));
    try std.testing.expectEqualStrings("", stmt.columnText(0).?);
}

test "unicode text" {
    var db = try Db.open(":memory:", .{});
    defer db.deinit();

    try db.exec("CREATE TABLE test (name TEXT)");

    var insert = try db.prepare("INSERT INTO test VALUES (?)");
    defer insert.deinit();

    const unicode_text = "Hello 世界 🌍 émoji";
    try insert.bindText(1, unicode_text);
    try insert.exec();

    var select = try db.prepare("SELECT name FROM test");
    defer select.deinit();

    try std.testing.expect(try select.step());
    try std.testing.expectEqualStrings(unicode_text, select.columnText(0).?);
}
