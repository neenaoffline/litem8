const std = @import("std");
const sqlite = @import("sqlite");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;

// ============================================================================
// Test Utilities
// ============================================================================

const TempDir = struct {
    allocator: Allocator,
    path: []const u8,
    dir: std.fs.Dir,
    migrations_path: []const u8,
    db_path: []const u8,

    fn init(allocator: Allocator) !TempDir {
        // Create unique temp directory
        var buf: [256]u8 = undefined;
        const timestamp = std.time.nanoTimestamp();
        const rand = std.crypto.random.int(u32);
        const dir_name = std.fmt.bufPrint(&buf, "litem8-test-{d}-{d}", .{ timestamp, rand }) catch unreachable;

        const tmp_base = "/tmp";
        const path = try std.fs.path.join(allocator, &.{ tmp_base, dir_name });
        errdefer allocator.free(path);

        // Create the directory
        std.fs.makeDirAbsolute(path) catch |err| {
            std.debug.print("Failed to create temp dir {s}: {}\n", .{ path, err });
            return err;
        };

        const dir = try std.fs.openDirAbsolute(path, .{});

        // Create migrations subdirectory
        try dir.makeDir("migrations");
        const migrations_path = try std.fs.path.join(allocator, &.{ path, "migrations" });
        errdefer allocator.free(migrations_path);

        const db_path = try std.fs.path.join(allocator, &.{ path, "test.db" });

        return TempDir{
            .allocator = allocator,
            .path = path,
            .dir = dir,
            .migrations_path = migrations_path,
            .db_path = db_path,
        };
    }

    fn cleanup(self: *TempDir) void {
        self.dir.close();
        std.fs.deleteTreeAbsolute(self.path) catch |err| {
            std.debug.print("Warning: failed to cleanup temp dir {s}: {}\n", .{ self.path, err });
        };
        self.allocator.free(self.db_path);
        self.allocator.free(self.migrations_path);
        self.allocator.free(self.path);
    }

    fn writeMigration(self: *TempDir, name: []const u8, sql: []const u8) !void {
        const migrations_dir = try self.dir.openDir("migrations", .{});
        var dir = migrations_dir;
        defer dir.close();

        const file = try dir.createFile(name, .{});
        defer file.close();
        try file.writeAll(sql);
    }
};

const RunResult = struct {
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,

    fn deinit(self: *RunResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    fn exitCode(self: *const RunResult) ?u8 {
        return switch (self.term) {
            .Exited => |code| code,
            else => null,
        };
    }

    fn succeeded(self: *const RunResult) bool {
        return self.exitCode() == 0;
    }
};

fn runLitem8(allocator: Allocator, args: []const []const u8) !RunResult {
    const exe_path = build_options.exe_path;

    // Build argv: exe_path + args
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, exe_path);
    for (args) |arg| {
        try argv.append(allocator, arg);
    }

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Collect output (this waits for the process to complete)
    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);

    try child.collectOutput(allocator, &stdout_buf, &stderr_buf, 10 * 1024 * 1024);
    const term = try child.wait();

    const stdout = try stdout_buf.toOwnedSlice(allocator);
    errdefer allocator.free(stdout);
    const stderr = try stderr_buf.toOwnedSlice(allocator);

    return RunResult{
        .allocator = allocator,
        .stdout = stdout,
        .stderr = stderr,
        .term = term,
    };
}

fn openDb(allocator: Allocator, db_path: []const u8) !sqlite.Db {
    const path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(path_z);

    return sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{
            .write = false,
            .create = false,
        },
    });
}

fn tableExists(allocator: Allocator, db: *sqlite.Db, table_name: []const u8) !bool {
    const query = try std.fmt.allocPrint(allocator, "SELECT name FROM sqlite_master WHERE type='table' AND name='{s}'", .{table_name});
    defer allocator.free(query);

    var stmt = db.prepareDynamicWithDiags(query, .{}) catch {
        return false;
    };
    defer stmt.deinit();

    // Use oneAlloc for struct with []const u8 field
    const row = stmt.oneAlloc(struct { name: []const u8 }, allocator, .{}, .{}) catch {
        return false;
    };

    if (row) |r| {
        allocator.free(r.name);
        return true;
    }
    return false;
}

fn getRecordedMigrations(allocator: Allocator, db: *sqlite.Db, table_name: []const u8) ![][]const u8 {
    const query = try std.fmt.allocPrint(allocator, "SELECT name FROM {s} ORDER BY id", .{table_name});
    defer allocator.free(query);

    var stmt = db.prepareDynamicWithDiags(query, .{}) catch |err| {
        std.debug.print("Failed to prepare query: {}\n", .{err});
        return err;
    };
    defer stmt.deinit();

    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    var iter = try stmt.iteratorAlloc(struct { name: []const u8 }, allocator, .{});
    while (try iter.nextAlloc(allocator, .{})) |row| {
        // row.name is allocated by sqlite, we dupe it and then must free the original
        const name_copy = try allocator.dupe(u8, row.name);
        allocator.free(row.name);
        try results.append(allocator, name_copy);
    }

    return results.toOwnedSlice(allocator);
}

fn containsString(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ============================================================================
// E2E Tests
// ============================================================================

test "e2e: up - fresh database" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create two migrations
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (
        \\    id INTEGER PRIMARY KEY,
        \\    name TEXT NOT NULL
        \\);
    );
    try tmp.writeMigration("002_add_posts.sql",
        \\CREATE TABLE posts (
        \\    id INTEGER PRIMARY KEY,
        \\    user_id INTEGER NOT NULL,
        \\    title TEXT NOT NULL
        \\);
    );

    // Run litem8 up
    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    // Should succeed
    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());

    // Verify database state
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(try tableExists(allocator, &db, "users"));
    try std.testing.expect(try tableExists(allocator, &db, "posts"));
    try std.testing.expect(try tableExists(allocator, &db, "schema_migrations"));

    const migrations = try getRecordedMigrations(allocator, &db, "schema_migrations");
    defer {
        for (migrations) |m| allocator.free(m);
        allocator.free(migrations);
    }

    try std.testing.expectEqual(@as(usize, 2), migrations.len);
    try std.testing.expectEqualStrings("001_create_users.sql", migrations[0]);
    try std.testing.expectEqualStrings("002_add_posts.sql", migrations[1]);
}

test "e2e: up - partial run" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create first migration
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );

    // Run first migration
    var result1 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result1.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result1.exitCode());

    // Add second migration
    try tmp.writeMigration("002_add_posts.sql",
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY);
    );

    // Run again
    var result2 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result2.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result2.exitCode());
    try std.testing.expect(containsString(result2.stderr, "Running 1 pending"));

    // Verify both tables exist
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(try tableExists(allocator, &db, "users"));
    try std.testing.expect(try tableExists(allocator, &db, "posts"));

    const migrations = try getRecordedMigrations(allocator, &db, "schema_migrations");
    defer {
        for (migrations) |m| allocator.free(m);
        allocator.free(migrations);
    }
    try std.testing.expectEqual(@as(usize, 2), migrations.len);
}

test "e2e: up - all migrations already run" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );

    // Run first time
    var result1 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result1.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result1.exitCode());

    // Run second time
    var result2 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result2.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result2.exitCode());
    try std.testing.expect(containsString(result2.stderr, "up to date"));
}

test "e2e: up - gap detection" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create migrations 001 and 003
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );
    try tmp.writeMigration("003_add_posts.sql",
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY);
    );

    // Run migrations
    var result1 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result1.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result1.exitCode());

    // Now add migration 002 (gap!)
    try tmp.writeMigration("002_add_something.sql",
        \\CREATE TABLE something (id INTEGER);
    );

    // Run again - should fail
    var result2 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result2.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result2.exitCode());
    try std.testing.expect(containsString(result2.stderr, "gap detected") or
        containsString(result2.stderr, "Gap detected"));
}

test "e2e: up - duplicate migration numbers" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create two migrations with same number
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );
    try tmp.writeMigration("001_create_posts.sql",
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY);
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result.exitCode());
    try std.testing.expect(containsString(result.stderr, "Duplicate migration number") or
        containsString(result.stderr, "duplicate"));
}

test "e2e: up - missing migrations directory" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Delete the migrations directory
    try tmp.dir.deleteDir("migrations");

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result.exitCode());
    try std.testing.expect(containsString(result.stderr, "not found"));
}

test "e2e: up - invalid SQL rollback" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create a valid migration first
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );

    // Create migration with invalid SQL
    try tmp.writeMigration("002_bad_migration.sql",
        \\CREATE TABL broken_syntax;
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result.exitCode());

    // The first migration should still have been applied
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(try tableExists(allocator, &db, "users"));

    // But only one migration should be recorded (the bad one should have rolled back)
    const migrations = try getRecordedMigrations(allocator, &db, "schema_migrations");
    defer {
        for (migrations) |m| allocator.free(m);
        allocator.free(migrations);
    }
    try std.testing.expectEqual(@as(usize, 1), migrations.len);
}

test "e2e: status - no database" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    var result = try runLitem8(allocator, &.{
        "status",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    // Should show error about missing database
    try std.testing.expect(containsString(result.stderr, "not found") or
        containsString(result.stderr, "Database"));
}

test "e2e: status - empty (no migrations run)" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create empty db by touching it via sqlite
    {
        const path_z = try allocator.dupeZ(u8, tmp.db_path);
        defer allocator.free(path_z);
        var db = try sqlite.Db.init(.{
            .mode = .{ .File = path_z },
            .open_flags = .{ .write = true, .create = true },
        });
        db.deinit();
    }

    var result = try runLitem8(allocator, &.{
        "status",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());
    try std.testing.expect(containsString(result.stderr, "No migrations") or
        containsString(result.stderr, "no migrations"));
}

test "e2e: status - with migrations" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create and run migrations
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );
    try tmp.writeMigration("002_add_posts.sql",
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY);
    );

    var result1 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result1.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result1.exitCode());

    // Check status
    var result2 = try runLitem8(allocator, &.{
        "status",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result2.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result2.exitCode());
    try std.testing.expect(containsString(result2.stderr, "001_create_users.sql"));
    try std.testing.expect(containsString(result2.stderr, "002_add_posts.sql"));
}

test "e2e: --help flag" {
    const allocator = std.testing.allocator;

    var result = try runLitem8(allocator, &.{"--help"});
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());
    try std.testing.expect(containsString(result.stderr, "Usage:"));
}

test "e2e: missing required args" {
    const allocator = std.testing.allocator;

    // No arguments at all
    var result1 = try runLitem8(allocator, &.{});
    defer result1.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result1.exitCode());
    try std.testing.expect(containsString(result1.stderr, "required") or
        containsString(result1.stderr, "Usage:"));

    // Missing --migrations
    var result2 = try runLitem8(allocator, &.{ "up", "--db", "/tmp/test.db" });
    defer result2.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result2.exitCode());
    try std.testing.expect(containsString(result2.stderr, "--migrations") or
        containsString(result2.stderr, "required"));
}

test "e2e: custom --table name" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
        "--table",
        "custom_migrations",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());

    // Verify custom table was used
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(try tableExists(allocator, &db, "custom_migrations"));
    try std.testing.expect(!try tableExists(allocator, &db, "schema_migrations"));

    const migrations = try getRecordedMigrations(allocator, &db, "custom_migrations");
    defer {
        for (migrations) |m| allocator.free(m);
        allocator.free(migrations);
    }
    try std.testing.expectEqual(@as(usize, 1), migrations.len);
    try std.testing.expectEqualStrings("001_create_users.sql", migrations[0]);
}

test "e2e: up - hash verification detects modified migration" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create and run a migration
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );

    var result1 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result1.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result1.exitCode());

    // Modify the migration file
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
    );

    // Try to run again - should fail due to hash mismatch
    var result2 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result2.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result2.exitCode());
    try std.testing.expect(containsString(result2.stderr, "modified") or
        containsString(result2.stderr, "changed") or
        containsString(result2.stderr, "hash"));
}

test "e2e: status - hash verification detects modified migration" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create and run a migration
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );

    var result1 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result1.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result1.exitCode());

    // Modify the migration file
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
    );

    // Check status - should fail due to hash mismatch
    var result2 = try runLitem8(allocator, &.{
        "status",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result2.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result2.exitCode());
    try std.testing.expect(containsString(result2.stderr, "modified") or
        containsString(result2.stderr, "changed") or
        containsString(result2.stderr, "hash"));
}

test "e2e: up - hash verification detects missing migration file" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create and run two migrations
    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );
    try tmp.writeMigration("002_add_posts.sql",
        \\CREATE TABLE posts (id INTEGER PRIMARY KEY);
    );

    var result1 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result1.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result1.exitCode());

    // Delete the first migration file
    const migrations_dir = try tmp.dir.openDir("migrations", .{});
    var dir = migrations_dir;
    defer dir.close();
    try dir.deleteFile("001_create_users.sql");

    // Try to run again - should fail due to missing file
    var result2 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result2.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result2.exitCode());
    try std.testing.expect(containsString(result2.stderr, "missing") or
        containsString(result2.stderr, "no longer exists"));
}

test "e2e: hash stored in migrations table" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_create_users.sql",
        \\CREATE TABLE users (id INTEGER PRIMARY KEY);
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());

    // Verify hash is stored in the database
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    var stmt = db.prepareDynamicWithDiags("SELECT hash FROM schema_migrations WHERE name = '001_create_users.sql'", .{}) catch unreachable;
    defer stmt.deinit();

    const row = (stmt.oneAlloc(struct { hash: ?[]const u8 }, allocator, .{}, .{}) catch unreachable).?;
    defer if (row.hash) |h| allocator.free(h);

    try std.testing.expect(row.hash != null);
    try std.testing.expectEqual(@as(usize, 64), row.hash.?.len); // SHA256 = 64 hex chars
}
