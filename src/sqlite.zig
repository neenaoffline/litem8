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
