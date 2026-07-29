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

    return sqlite.Db.open(path_z, .{ .write = false, .create = false });
}

fn tableExists(allocator: Allocator, db: *sqlite.Db, table_name: []const u8) !bool {
    _ = allocator;
    var stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?");
    defer stmt.deinit();
    try stmt.bindText(1, table_name);

    return try stmt.step();
}

fn getRecordedMigrations(allocator: Allocator, db: *sqlite.Db, table_name: []const u8) ![][]const u8 {
    const query = try std.fmt.allocPrint(allocator, "SELECT name FROM {s} ORDER BY id", .{table_name});
    defer allocator.free(query);

    var stmt = db.prepareDynamic(allocator, query) catch |err| {
        std.debug.print("Failed to prepare query: {}\n", .{err});
        return err;
    };
    defer stmt.deinit();

    var results: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (results.items) |item| allocator.free(item);
        results.deinit(allocator);
    }

    while (true) {
        const has_row = try stmt.step();
        if (!has_row) break;

        const name = try stmt.columnTextAlloc(allocator, 0) orelse continue;
        try results.append(allocator, name);
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

test "e2e: migration cannot rollback runner transaction" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration(
        "001_rollback.sql",
        "CREATE TABLE rolled_back (id INTEGER); ROLLBACK;",
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

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();
    try std.testing.expect(!try tableExists(allocator, &db, "rolled_back"));

    const migrations = try getRecordedMigrations(allocator, &db, "schema_migrations");
    defer {
        for (migrations) |migration| allocator.free(migration);
        allocator.free(migrations);
    }
    try std.testing.expectEqual(@as(usize, 0), migrations.len);
}

test "e2e: migration cannot commit runner transaction" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration(
        "001_commit.sql",
        "CREATE TABLE committed_early (id INTEGER); COMMIT;",
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

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();
    try std.testing.expect(!try tableExists(allocator, &db, "committed_early"));

    const migrations = try getRecordedMigrations(allocator, &db, "schema_migrations");
    defer {
        for (migrations) |migration| allocator.free(migration);
        allocator.free(migrations);
    }
    try std.testing.expectEqual(@as(usize, 0), migrations.len);
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
        var db = try sqlite.Db.open(path_z, .{ .write = true, .create = true });
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

    var stmt = try db.prepare("SELECT hash FROM schema_migrations WHERE name = '001_create_users.sql'");
    defer stmt.deinit();

    const has_row = try stmt.step();
    try std.testing.expect(has_row);

    const hash = stmt.columnText(0);
    try std.testing.expect(hash != null);
    try std.testing.expectEqual(@as(usize, 64), hash.?.len); // SHA256 = 64 hex chars
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "e2e: empty migration file (0 bytes)" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create an empty migration file
    try tmp.writeMigration("001_empty.sql", "");

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    // Empty migrations should succeed (nothing to do)
    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());
}

test "e2e: migration with only whitespace" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_whitespace.sql", "   \n\t\n   \n");

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());
}

test "e2e: migration with only SQL comments" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_comments.sql",
        \\-- This is a comment
        \\-- Another comment
        \\/* Block comment */
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    // Comments-only should succeed
    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());
}

test "e2e: migration with unicode content" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_unicode.sql",
        \\CREATE TABLE users (
        \\    id INTEGER PRIMARY KEY,
        \\    name TEXT NOT NULL
        \\);
        \\-- Комментарий на русском
        \\INSERT INTO users (name) VALUES ('世界');
        \\INSERT INTO users (name) VALUES ('émoji 🎉');
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

    // Verify unicode data was inserted correctly
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    var stmt = try db.prepare("SELECT name FROM users ORDER BY id");
    defer stmt.deinit();

    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("世界", stmt.columnText(0).?);

    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("émoji 🎉", stmt.columnText(0).?);
}

test "e2e: migration with embedded NUL is rejected without recording" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration(
        "001_embedded_nul.sql",
        "CREATE TABLE before_nul (id INTEGER);\x00CREATE TABLE after_nul (id INTEGER);",
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

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(!try tableExists(allocator, &db, "before_nul"));
    try std.testing.expect(!try tableExists(allocator, &db, "after_nul"));

    const migrations = try getRecordedMigrations(allocator, &db, "schema_migrations");
    defer allocator.free(migrations);
    try std.testing.expectEqual(@as(usize, 0), migrations.len);
}

test "e2e: SQL injection attempt in --table parameter" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    const path_z = try allocator.dupeZ(u8, tmp.db_path);
    defer allocator.free(path_z);
    var setup_db = try sqlite.Db.open(path_z, .{ .write = true, .create = true });
    try setup_db.exec("CREATE TABLE victim (id INTEGER)");
    try setup_db.exec("INSERT INTO victim VALUES (42)");
    setup_db.deinit();

    const database_before = try std.fs.cwd().readFileAlloc(allocator, tmp.db_path, 1024 * 1024);
    defer allocator.free(database_before);

    try tmp.writeMigration("001_test.sql",
        \\CREATE TABLE test (id INTEGER);
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
        "--table",
        "track (id); DROP TABLE victim; --",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result.exitCode());
    try std.testing.expect(containsString(result.stderr, "Invalid table name"));

    const database_after = try std.fs.cwd().readFileAlloc(allocator, tmp.db_path, 1024 * 1024);
    defer allocator.free(database_after);
    try std.testing.expectEqualSlices(u8, database_before, database_after);

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();
    try std.testing.expect(try tableExists(allocator, &db, "victim"));
    try std.testing.expect(!try tableExists(allocator, &db, "track"));
    try std.testing.expect(!try tableExists(allocator, &db, "test"));
    try std.testing.expect(!try tableExists(allocator, &db, "schema_migrations"));

    var sentinel = try db.prepare("SELECT id FROM victim");
    defer sentinel.deinit();
    try std.testing.expect(try sentinel.step());
    try std.testing.expectEqual(@as(i32, 42), sentinel.columnInt(0));
    try std.testing.expect(!try sentinel.step());
}

test "e2e: incompatible existing migration table is rejected without mutation" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    const path_z = try allocator.dupeZ(u8, tmp.db_path);
    defer allocator.free(path_z);
    var setup_db = try sqlite.Db.open(path_z, .{ .write = true, .create = true });
    try setup_db.exec("CREATE TABLE victim (id INTEGER)");
    try setup_db.exec("INSERT INTO victim VALUES (42)");
    setup_db.deinit();

    const database_before = try std.fs.cwd().readFileAlloc(allocator, tmp.db_path, 1024 * 1024);
    defer allocator.free(database_before);

    try tmp.writeMigration("001_test.sql",
        \\CREATE TABLE test (id INTEGER);
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
        "--table",
        "victim",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result.exitCode());

    const database_after = try std.fs.cwd().readFileAlloc(allocator, tmp.db_path, 1024 * 1024);
    defer allocator.free(database_after);
    try std.testing.expectEqualSlices(u8, database_before, database_after);

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();
    try std.testing.expect(try tableExists(allocator, &db, "victim"));
    try std.testing.expect(!try tableExists(allocator, &db, "test"));
    try std.testing.expect(!try tableExists(allocator, &db, "schema_migrations"));
}

test "e2e: constrained table collision is rejected without mutation" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    const path_z = try allocator.dupeZ(u8, tmp.db_path);
    defer allocator.free(path_z);
    var setup_db = try sqlite.Db.open(path_z, .{ .write = true, .create = true });
    try setup_db.exec(
        "CREATE TABLE victim (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE CHECK(name='never'), run_at TEXT NOT NULL)",
    );
    setup_db.deinit();

    const database_before = try std.fs.cwd().readFileAlloc(allocator, tmp.db_path, 1024 * 1024);
    defer allocator.free(database_before);
    try tmp.writeMigration("001_test.sql", "CREATE TABLE test (id INTEGER);");

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
        "--table",
        "victim",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 1), result.exitCode());
    const database_after = try std.fs.cwd().readFileAlloc(allocator, tmp.db_path, 1024 * 1024);
    defer allocator.free(database_after);
    try std.testing.expectEqualSlices(u8, database_before, database_after);
}

test "e2e: compatible legacy migration table gains hash column" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    const path_z = try allocator.dupeZ(u8, tmp.db_path);
    defer allocator.free(path_z);
    var setup_db = try sqlite.Db.open(path_z, .{ .write = true, .create = true });
    try setup_db.exec(
        "CREATE TABLE Legacy_Migrations (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, run_at TEXT NOT NULL)",
    );
    setup_db.deinit();

    try tmp.writeMigration("001_test.sql",
        \\CREATE TABLE legacy_upgrade_test (id INTEGER);
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
        "--table",
        "legacy_migrations",
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();
    var columns = try db.prepare("PRAGMA table_info(legacy_migrations)");
    defer columns.deinit();
    var found_hash = false;
    while (try columns.step()) {
        if (columns.columnText(1)) |name| {
            if (std.mem.eql(u8, name, "hash")) found_hash = true;
        }
    }
    try std.testing.expect(found_hash);

    var second_result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
        "--table",
        "legacy_migrations",
    });
    defer second_result.deinit();
    try std.testing.expectEqual(@as(?u8, 0), second_result.exitCode());
}

test "e2e: temporary table cannot shadow migration metadata" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_temp_shadow.sql",
        \\CREATE TABLE payload (id INTEGER);
        \\CREATE TEMP TABLE schema_migrations (
        \\    id INTEGER PRIMARY KEY,
        \\    name TEXT NOT NULL UNIQUE,
        \\    run_at TEXT NOT NULL,
        \\    hash TEXT
        \\);
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
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();
    try std.testing.expect(try tableExists(allocator, &db, "payload"));

    const migrations = try getRecordedMigrations(allocator, &db, "schema_migrations");
    defer {
        for (migrations) |migration| allocator.free(migration);
        allocator.free(migrations);
    }
    try std.testing.expectEqual(@as(usize, 1), migrations.len);
    try std.testing.expectEqualStrings("001_temp_shadow.sql", migrations[0]);
}

test "e2e: migration filename containing apostrophe is recorded safely" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_owner's_table.sql",
        \\CREATE TABLE quoted_filename (id INTEGER);
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

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();
    try std.testing.expect(try tableExists(allocator, &db, "quoted_filename"));

    const migrations = try getRecordedMigrations(allocator, &db, "schema_migrations");
    defer {
        for (migrations) |migration| allocator.free(migration);
        allocator.free(migrations);
    }
    try std.testing.expectEqual(@as(usize, 1), migrations.len);
    try std.testing.expectEqualStrings("001_owner's_table.sql", migrations[0]);
}

test "e2e: very long migration filename" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create a migration with a very long name (but valid)
    const long_name = "001_" ++ "a" ** 200 ++ ".sql";
    try tmp.writeMigration(long_name,
        \\CREATE TABLE test (id INTEGER);
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
}

test "e2e: migration number with many leading zeros" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("00000001_test.sql",
        \\CREATE TABLE test1 (id INTEGER);
    );
    try tmp.writeMigration("00000002_test.sql",
        \\CREATE TABLE test2 (id INTEGER);
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

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(try tableExists(allocator, &db, "test1"));
    try std.testing.expect(try tableExists(allocator, &db, "test2"));
}

test "e2e: migration with multiple statements and error in middle" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_multi_error.sql",
        \\CREATE TABLE before_error (id INTEGER);
        \\INVALID SQL HERE;
        \\CREATE TABLE after_error (id INTEGER);
    );

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    // Should fail
    try std.testing.expectEqual(@as(?u8, 1), result.exitCode());

    // Transaction should have rolled back - before_error should NOT exist
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(!try tableExists(allocator, &db, "before_error"));
    try std.testing.expect(!try tableExists(allocator, &db, "after_error"));
}

test "e2e: migration creates and drops same table" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_create_drop.sql",
        \\CREATE TABLE temp_table (id INTEGER);
        \\DROP TABLE temp_table;
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

    // Table should not exist after migration
    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(!try tableExists(allocator, &db, "temp_table"));
}

test "e2e: running up twice is idempotent" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_test.sql",
        \\CREATE TABLE test (id INTEGER);
    );

    // Run once
    var result1 = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result1.deinit();
    try std.testing.expectEqual(@as(?u8, 0), result1.exitCode());

    // Run again - should succeed with "up to date" message
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

test "e2e: non-sql files in migrations directory are ignored" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("001_real.sql",
        \\CREATE TABLE real_table (id INTEGER);
    );
    try tmp.writeMigration("README.md", "# This is not a migration");
    try tmp.writeMigration("notes.txt", "Some notes");
    try tmp.writeMigration(".hidden", "hidden file");

    var result = try runLitem8(allocator, &.{
        "up",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());

    // Should only have run 1 migration
    try std.testing.expect(containsString(result.stderr, "1 pending") or
        containsString(result.stderr, "1 migration"));

    var db = try openDb(allocator, tmp.db_path);
    defer db.deinit();

    try std.testing.expect(try tableExists(allocator, &db, "real_table"));
}

test "e2e: large migration number" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    try tmp.writeMigration("999999999_big_number.sql",
        \\CREATE TABLE big_number_test (id INTEGER);
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
}

test "e2e: status on empty migrations directory" {
    const allocator = std.testing.allocator;
    var tmp = try TempDir.init(allocator);
    defer tmp.cleanup();

    // Create db first
    {
        const path_z = try allocator.dupeZ(u8, tmp.db_path);
        defer allocator.free(path_z);
        var db = try sqlite.Db.open(path_z, .{ .write = true, .create = true });
        db.deinit();
    }

    // Run status with empty migrations dir
    var result = try runLitem8(allocator, &.{
        "status",
        "--db",
        tmp.db_path,
        "--migrations",
        tmp.migrations_path,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(?u8, 0), result.exitCode());
}
