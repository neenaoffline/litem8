const std = @import("std");
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;

// ============================================================================
// Types
// ============================================================================

const Command = enum {
    up,
    status,
};

const Config = struct {
    allocator: Allocator,
    db_path: []const u8,
    migrations_path: []const u8,
    table_name: []const u8,
    command: Command,

    fn initOwned(
        allocator: Allocator,
        db_path: []const u8,
        migrations_path: []const u8,
        table_name: []const u8,
        command: Command,
    ) Allocator.Error!Config {
        const owned_db_path = try allocator.dupe(u8, db_path);
        errdefer allocator.free(owned_db_path);
        const owned_migrations_path = try allocator.dupe(u8, migrations_path);
        errdefer allocator.free(owned_migrations_path);
        const owned_table_name = try allocator.dupe(u8, table_name);

        return .{
            .allocator = allocator,
            .db_path = owned_db_path,
            .migrations_path = owned_migrations_path,
            .table_name = owned_table_name,
            .command = command,
        };
    }

    fn deinit(self: *Config) void {
        self.allocator.free(self.db_path);
        self.allocator.free(self.migrations_path);
        self.allocator.free(self.table_name);
    }
};

const Migration = struct {
    number: u32,
    name: []const u8, // full filename
    path: []const u8, // full path

    fn lessThan(_: void, a: Migration, b: Migration) bool {
        return a.number < b.number;
    }
};

const RunMigration = struct {
    name: []const u8,
    number: u32,
    run_at: []const u8,
    hash: ?[]const u8,
};

const MigrationError = error{
    InvalidFilenameFormat,
    DuplicateMigrationNumber,
    MigrationGapDetected,
    MigrationDirectoryNotFound,
    DatabaseError,
    SqlExecutionError,
    HashMismatch,
};

// ============================================================================
// Hash Utilities
// ============================================================================

/// Compute SHA256 hash of file contents and return as hex string
fn computeFileHash(allocator: Allocator, file_path: []const u8) ![]const u8 {
    const contents = std.fs.cwd().readFileAlloc(
        allocator,
        file_path,
        10 * 1024 * 1024, // 10MB max
    ) catch {
        return MigrationError.SqlExecutionError;
    };
    defer allocator.free(contents);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(contents, &hash, .{});

    // Convert to hex string
    var hex_buf: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        const hex_chars = "0123456789abcdef";
        hex_buf[i * 2] = hex_chars[byte >> 4];
        hex_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }

    return try allocator.dupe(u8, &hex_buf);
}

/// Verify that all run migrations have matching hashes with current files
/// Returns error.HashMismatch if any hash doesn't match
fn verifyMigrationHashes(allocator: Allocator, migrations: []const Migration, run_migrations: []const RunMigration) !void {
    // Build a map of name -> migration for quick lookup
    var migration_map = std.StringHashMap(Migration).init(allocator);
    defer migration_map.deinit();

    for (migrations) |m| {
        try migration_map.put(m.name, m);
    }

    // Check each run migration
    for (run_migrations) |rm| {
        // Skip if no hash stored (legacy migration)
        const stored_hash = rm.hash orelse continue;

        // Find corresponding migration file
        const migration = migration_map.get(rm.name) orelse {
            std.debug.print(
                "Error: Migration file missing!\n" ++
                    "Migration '{s}' was previously run but the file no longer exists.\n",
                .{rm.name},
            );
            return MigrationError.HashMismatch;
        };

        // Compute current hash
        const current_hash = try computeFileHash(allocator, migration.path);
        defer allocator.free(current_hash);

        // Compare hashes
        if (!std.mem.eql(u8, stored_hash, current_hash)) {
            std.debug.print(
                "Error: Migration file has been modified!\n" ++
                    "Migration '{s}' has changed since it was run.\n" ++
                    "  Expected hash: {s}\n" ++
                    "  Current hash:  {s}\n" ++
                    "Modifying already-run migrations can cause inconsistencies.\n",
                .{ rm.name, stored_hash, current_hash },
            );
            return MigrationError.HashMismatch;
        }
    }
}

// ============================================================================
// CLI Argument Parsing
// ============================================================================

fn printUsage() void {
    std.debug.print(
        \\Usage: litem8 <command> --db <path> --migrations <path> [--table <name>]
        \\
        \\Commands:
        \\  up      Run all pending migrations
        \\  status  Show all migrations that have been run
        \\
        \\Options:
        \\  --db <path>          Path to SQLite database file (created if doesn't exist)
        \\  --migrations <path>  Path to directory containing migration files
        \\  --table <name>       Name of schema migrations table (default: schema_migrations)
        \\  --help               Show this help message
        \\
        \\Migration files must be named: <number>_<name>.sql (e.g., 001_create_users.sql)
        \\
    , .{});
}

const ParseResult = union(enum) {
    config: Config,
    help,
    err,
};

fn isValidTableName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;

    for (name[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn parseArgs(allocator: Allocator) !ParseResult {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var db_path: ?[]const u8 = null;
    var migrations_path: ?[]const u8 = null;
    var table_name: []const u8 = "schema_migrations";
    var command: ?Command = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return .help;
        } else if (std.mem.eql(u8, arg, "--db")) {
            db_path = args.next() orelse {
                std.debug.print("Error: --db requires a path argument\n", .{});
                return .err;
            };
        } else if (std.mem.eql(u8, arg, "--migrations")) {
            migrations_path = args.next() orelse {
                std.debug.print("Error: --migrations requires a path argument\n", .{});
                return .err;
            };
        } else if (std.mem.eql(u8, arg, "--table")) {
            table_name = args.next() orelse {
                std.debug.print("Error: --table requires a name argument\n", .{});
                return .err;
            };
        } else if (std.mem.eql(u8, arg, "up")) {
            command = .up;
        } else if (std.mem.eql(u8, arg, "status")) {
            command = .status;
        } else {
            std.debug.print("Error: Unknown argument '{s}'\n", .{arg});
            return .err;
        }
    }

    // Validate required arguments
    if (command == null) {
        std.debug.print("Error: Command required (up or status)\n\n", .{});
        printUsage();
        return .err;
    }

    if (db_path == null) {
        std.debug.print("Error: --db is required\n\n", .{});
        printUsage();
        return .err;
    }

    if (migrations_path == null) {
        std.debug.print("Error: --migrations is required\n\n", .{});
        printUsage();
        return .err;
    }

    if (!isValidTableName(table_name)) {
        std.debug.print("Error: Invalid table name '{s}'\n", .{table_name});
        return .err;
    }

    return .{ .config = try Config.initOwned(
        allocator,
        db_path.?,
        migrations_path.?,
        table_name,
        command.?,
    ) };
}

// ============================================================================
// Migration File Parsing
// ============================================================================

/// Parse migration number from filename.
/// Filename must match pattern: \d+_.+\.sql
/// Returns the number (e.g., "001_init.sql" -> 1, "1_init.sql" -> 1)
fn parseMigrationNumber(filename: []const u8) !u32 {
    // Must end with .sql
    if (!std.mem.endsWith(u8, filename, ".sql")) {
        return MigrationError.InvalidFilenameFormat;
    }

    // Find the underscore
    const underscore_pos = std.mem.indexOf(u8, filename, "_") orelse {
        return MigrationError.InvalidFilenameFormat;
    };

    // Must have at least one digit before underscore
    if (underscore_pos == 0) {
        return MigrationError.InvalidFilenameFormat;
    }

    // Extract the number part
    const number_str = filename[0..underscore_pos];

    // Validate all characters are digits
    for (number_str) |ch| {
        if (ch < '0' or ch > '9') {
            return MigrationError.InvalidFilenameFormat;
        }
    }

    // Must have something between underscore and .sql
    const name_part = filename[underscore_pos + 1 .. filename.len - 4];
    if (name_part.len == 0) {
        return MigrationError.InvalidFilenameFormat;
    }

    // Parse the number
    return std.fmt.parseInt(u32, number_str, 10) catch {
        return MigrationError.InvalidFilenameFormat;
    };
}

/// Load all migrations from a directory, sorted by number.
/// Fails if directory doesn't exist or contains duplicate migration numbers.
fn loadMigrations(allocator: Allocator, dir_path: []const u8) ![]Migration {
    // Open the directory
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return MigrationError.MigrationDirectoryNotFound;
        }
        return err;
    };
    defer dir.close();

    var migrations: std.ArrayList(Migration) = .empty;
    errdefer migrations.deinit(allocator);

    // Iterate through directory entries
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        // Try to parse as migration file
        const number = parseMigrationNumber(entry.name) catch |err| {
            if (err == MigrationError.InvalidFilenameFormat) {
                // Skip files that don't match the migration pattern
                continue;
            }
            return err;
        };

        // Check for duplicate migration numbers
        for (migrations.items) |existing| {
            if (existing.number == number) {
                std.debug.print("Error: Duplicate migration number {d} found:\n  - {s}\n  - {s}\n", .{
                    number,
                    existing.name,
                    entry.name,
                });
                return MigrationError.DuplicateMigrationNumber;
            }
        }

        // Build full path
        const name = try allocator.dupe(u8, entry.name);
        const path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        try migrations.append(allocator, .{
            .number = number,
            .name = name,
            .path = path,
        });
    }

    // Sort by migration number
    const items = try migrations.toOwnedSlice(allocator);
    std.mem.sort(Migration, items, {}, Migration.lessThan);

    return items;
}

// ============================================================================
// Database Operations
// ============================================================================

fn openDatabase(allocator: Allocator, db_path: []const u8, flags: sqlite.OpenFlags) !sqlite.Db {
    const path_z = allocator.dupeZ(u8, db_path) catch {
        return MigrationError.DatabaseError;
    };
    defer allocator.free(path_z);

    return sqlite.Db.open(path_z, flags) catch {
        return MigrationError.DatabaseError;
    };
}

const MigrationsTableState = enum {
    missing,
    legacy,
    current,
};

fn getMigrationsTableState(allocator: Allocator, db: *sqlite.Db, table_name: []const u8) !MigrationsTableState {
    var exists_stmt = db.prepare(
        "SELECT name, sql FROM main.sqlite_master WHERE type='table' AND name=? COLLATE NOCASE",
    ) catch {
        return MigrationError.DatabaseError;
    };
    defer exists_stmt.deinit();
    exists_stmt.bindText(1, table_name) catch return MigrationError.DatabaseError;
    if (!(exists_stmt.step() catch return MigrationError.DatabaseError)) return .missing;

    const actual_name = exists_stmt.columnText(0) orelse return MigrationError.DatabaseError;
    const stored_sql = exists_stmt.columnText(1) orelse return MigrationError.DatabaseError;
    const legacy_unquoted = std.fmt.allocPrint(
        allocator,
        "CREATE TABLE {s} (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, run_at TEXT NOT NULL)",
        .{actual_name},
    ) catch return MigrationError.DatabaseError;
    defer allocator.free(legacy_unquoted);
    const legacy_quoted = std.fmt.allocPrint(
        allocator,
        "CREATE TABLE \"{s}\" (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, run_at TEXT NOT NULL)",
        .{actual_name},
    ) catch return MigrationError.DatabaseError;
    defer allocator.free(legacy_quoted);
    const current_unquoted = std.fmt.allocPrint(
        allocator,
        "CREATE TABLE {s} (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, run_at TEXT NOT NULL, hash TEXT)",
        .{actual_name},
    ) catch return MigrationError.DatabaseError;
    defer allocator.free(current_unquoted);
    const current_quoted = std.fmt.allocPrint(
        allocator,
        "CREATE TABLE \"{s}\" (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, run_at TEXT NOT NULL, hash TEXT)",
        .{actual_name},
    ) catch return MigrationError.DatabaseError;
    defer allocator.free(current_quoted);

    const state: MigrationsTableState = if (std.mem.eql(u8, stored_sql, legacy_unquoted) or std.mem.eql(u8, stored_sql, legacy_quoted))
        .legacy
    else if (std.mem.eql(u8, stored_sql, current_unquoted) or std.mem.eql(u8, stored_sql, current_quoted))
        .current
    else {
        std.debug.print("Error: Existing table '{s}' is not a compatible migrations table\n", .{table_name});
        return MigrationError.DatabaseError;
    };

    var extension_stmt = db.prepare(
        "SELECT 1 FROM main.sqlite_master WHERE tbl_name=? COLLATE NOCASE AND " ++
            "(type='trigger' OR (type='index' AND sql IS NOT NULL)) LIMIT 1",
    ) catch return MigrationError.DatabaseError;
    defer extension_stmt.deinit();
    extension_stmt.bindText(1, actual_name) catch return MigrationError.DatabaseError;
    if (extension_stmt.step() catch return MigrationError.DatabaseError) {
        std.debug.print("Error: Existing table '{s}' has unsupported triggers or indexes\n", .{table_name});
        return MigrationError.DatabaseError;
    }

    return state;
}

fn createMigrationsTable(allocator: Allocator, db: *sqlite.Db, table_name: []const u8) !void {
    const state = try getMigrationsTableState(allocator, db, table_name);
    if (state == .current) return;

    const sql_slice = switch (state) {
        .missing => std.fmt.allocPrint(
            allocator,
            "CREATE TABLE main.\"{s}\" (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, run_at TEXT NOT NULL, hash TEXT)",
            .{table_name},
        ),
        .legacy => std.fmt.allocPrint(allocator, "ALTER TABLE main.\"{s}\" ADD COLUMN hash TEXT", .{table_name}),
        .current => unreachable,
    } catch return MigrationError.DatabaseError;
    defer allocator.free(sql_slice);
    const sql = allocator.dupeZ(u8, sql_slice) catch return MigrationError.DatabaseError;
    defer allocator.free(sql);

    db.exec(sql) catch return MigrationError.DatabaseError;
}

fn getRunMigrations(allocator: Allocator, db: *sqlite.Db, table_name: []const u8) ![]RunMigration {
    const query = std.fmt.allocPrint(
        allocator,
        "SELECT name, run_at, hash FROM main.\"{s}\" ORDER BY id",
        .{table_name},
    ) catch return MigrationError.DatabaseError;
    defer allocator.free(query);

    var stmt = db.prepareDynamic(allocator, query) catch {
        return MigrationError.DatabaseError;
    };
    defer stmt.deinit();

    var results: std.ArrayList(RunMigration) = .empty;
    errdefer results.deinit(allocator);

    while (true) {
        const has_row = stmt.step() catch {
            return MigrationError.DatabaseError;
        };
        if (!has_row) break;

        const name = stmt.columnTextAlloc(allocator, 0) catch {
            return MigrationError.DatabaseError;
        } orelse continue;

        const run_at = stmt.columnTextAlloc(allocator, 1) catch {
            allocator.free(name);
            return MigrationError.DatabaseError;
        } orelse {
            allocator.free(name);
            continue;
        };

        const hash = stmt.columnTextAlloc(allocator, 2) catch {
            allocator.free(name);
            allocator.free(run_at);
            return MigrationError.DatabaseError;
        };

        // Parse migration number from name
        const number = parseMigrationNumber(name) catch {
            // Skip invalid entries (shouldn't happen but be safe)
            allocator.free(name);
            allocator.free(run_at);
            if (hash) |h| allocator.free(h);
            continue;
        };

        try results.append(allocator, .{
            .name = name,
            .number = number,
            .run_at = run_at,
            .hash = hash,
        });
    }

    return results.toOwnedSlice(allocator);
}

fn executeMigration(allocator: Allocator, db: *sqlite.Db, migration: Migration, table_name: []const u8) !void {
    // Read migration file
    const raw_sql = std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        migration.path,
        10 * 1024 * 1024, // 10MB max
    ) catch {
        return MigrationError.SqlExecutionError;
    };
    defer std.heap.page_allocator.free(raw_sql);

    // Compute hash of the migration file
    const hash = try computeFileHash(allocator, migration.path);
    defer allocator.free(hash);

    // Trim whitespace to avoid issues with empty statements
    const sql = std.mem.trim(u8, raw_sql, " \t\n\r");

    // Begin transaction
    db.exec("BEGIN TRANSACTION") catch {
        return MigrationError.SqlExecutionError;
    };
    errdefer {
        db.exec("ROLLBACK") catch {};
    }

    // Execute migration SQL without allowing it to control this transaction.
    db.execMigration(sql) catch |err| {
        std.debug.print("Error executing migration {s}: {}\n", .{ migration.name, err });
        std.debug.print("SQLite error: {s}\n", .{db.getErrorMessage()});
        db.exec("ROLLBACK") catch {};
        return MigrationError.SqlExecutionError;
    };

    // Get current timestamp
    const timestamp = getTimestamp();

    // Record migration with bound values. The table name was validated during argument parsing.
    const insert_sql = std.fmt.allocPrint(
        allocator,
        "INSERT INTO main.\"{s}\" (name, run_at, hash) VALUES (?, ?, ?)",
        .{table_name},
    ) catch return MigrationError.SqlExecutionError;
    defer allocator.free(insert_sql);

    var insert_stmt = db.prepareDynamic(allocator, insert_sql) catch return MigrationError.SqlExecutionError;
    defer insert_stmt.deinit();
    insert_stmt.bindText(1, migration.name) catch return MigrationError.SqlExecutionError;
    insert_stmt.bindText(2, timestamp) catch return MigrationError.SqlExecutionError;
    insert_stmt.bindText(3, hash) catch return MigrationError.SqlExecutionError;
    insert_stmt.exec() catch {
        db.exec("ROLLBACK") catch {};
        return MigrationError.SqlExecutionError;
    };

    // Commit transaction
    db.exec("COMMIT") catch {
        return MigrationError.SqlExecutionError;
    };
}

fn getTimestamp() []const u8 {
    const ts = std.time.timestamp();
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const buf = std.heap.page_allocator.alloc(u8, 19) catch return "1970-01-01 00:00:00";

    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        @as(u8, @intFromEnum(month_day.month)),
        month_day.day_index + 1, // Convert 0-indexed to 1-indexed
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch return "1970-01-01 00:00:00";

    return buf;
}

// ============================================================================
// Commands
// ============================================================================

fn runUp(allocator: Allocator, config: Config) !void {
    // Load migrations from directory
    const migrations = loadMigrations(allocator, config.migrations_path) catch |err| {
        if (err == MigrationError.MigrationDirectoryNotFound) {
            std.debug.print("Error: Migrations directory not found: {s}\n", .{config.migrations_path});
            return err;
        }
        return err;
    };

    if (migrations.len == 0) {
        std.debug.print("No migration files found.\n", .{});
        return;
    }

    // Open database
    var db = try openDatabase(allocator, config.db_path, .{ .write = true, .create = true });
    defer db.deinit();

    // Create migrations table
    try createMigrationsTable(allocator, &db, config.table_name);

    // Get already-run migrations
    const run_migrations = try getRunMigrations(allocator, &db, config.table_name);

    // Verify hashes of already-run migrations
    try verifyMigrationHashes(allocator, migrations, run_migrations);

    // Find max run migration number
    var max_run_number: u32 = 0;
    var run_names = std.StringHashMap(void).init(allocator);
    defer run_names.deinit();

    for (run_migrations) |rm| {
        try run_names.put(rm.name, {});
        if (rm.number > max_run_number) {
            max_run_number = rm.number;
        }
    }

    // Find pending migrations and validate no gaps
    var pending: std.ArrayList(Migration) = .empty;
    defer pending.deinit(allocator);

    for (migrations) |m| {
        if (!run_names.contains(m.name)) {
            // This is a pending migration
            // Check if it would create a gap (number <= max already run)
            if (m.number <= max_run_number) {
                std.debug.print(
                    "Error: Migration gap detected!\n" ++
                        "Migration '{s}' (number {d}) is new but has a number <= the highest run migration ({d}).\n" ++
                        "New migrations must have numbers greater than all previously run migrations.\n",
                    .{ m.name, m.number, max_run_number },
                );
                return MigrationError.MigrationGapDetected;
            }
            try pending.append(allocator, m);
        }
    }

    if (pending.items.len == 0) {
        std.debug.print("All migrations are up to date.\n", .{});
        return;
    }

    // Run pending migrations
    std.debug.print("Running {d} pending migration(s)...\n\n", .{pending.items.len});

    for (pending.items) |migration| {
        std.debug.print("  Running: {s}...", .{migration.name});
        try executeMigration(allocator, &db, migration, config.table_name);
        std.debug.print(" done\n", .{});
    }

    std.debug.print("\nSuccessfully ran {d} migration(s).\n", .{pending.items.len});
}

fn runStatus(allocator: Allocator, config: Config) !void {
    // Check if database exists
    std.fs.cwd().access(config.db_path, .{}) catch {
        std.debug.print("Error: Database file not found: {s}\n", .{config.db_path});
        return;
    };

    // Load migrations from directory (needed for hash verification)
    const migrations = loadMigrations(allocator, config.migrations_path) catch |err| {
        if (err == MigrationError.MigrationDirectoryNotFound) {
            std.debug.print("Error: Migrations directory not found: {s}\n", .{config.migrations_path});
            return err;
        }
        return err;
    };

    // Open database
    var db = try openDatabase(allocator, config.db_path, .{ .write = false, .create = false });
    defer db.deinit();

    // Check if migrations table exists
    var check_stmt = db.prepare(
        "SELECT name FROM main.sqlite_master WHERE type='table' AND name=? COLLATE NOCASE",
    ) catch {
        return MigrationError.DatabaseError;
    };
    defer check_stmt.deinit();
    check_stmt.bindText(1, config.table_name) catch return MigrationError.DatabaseError;

    const table_exists = (check_stmt.step() catch {
        return MigrationError.DatabaseError;
    });

    if (!table_exists) {
        std.debug.print("No migrations have been run yet.\n", .{});
        return;
    }

    // Get run migrations
    const run_migrations = try getRunMigrations(allocator, &db, config.table_name);

    if (run_migrations.len == 0) {
        std.debug.print("No migrations have been run yet.\n", .{});
        return;
    }

    // Verify hashes of run migrations
    try verifyMigrationHashes(allocator, migrations, run_migrations);

    // Print header
    std.debug.print("Run migrations:\n\n", .{});
    std.debug.print("DATE\t\t\t\tNAME\n", .{});
    std.debug.print("----\t\t\t\t----\n", .{});

    // Print each migration
    for (run_migrations) |rm| {
        std.debug.print("{s}\t{s}\n", .{ rm.run_at, rm.name });
    }

    std.debug.print("\nTotal: {d} migration(s)\n", .{run_migrations.len});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    // Use page allocator for CLI tool - memory is reclaimed on process exit
    const allocator = std.heap.page_allocator;

    var config = switch (try parseArgs(allocator)) {
        .config => |c| c,
        .help => return, // Exit 0 for help
        .err => std.process.exit(1),
    };
    defer config.deinit();

    switch (config.command) {
        .up => runUp(allocator, config) catch {
            config.deinit();
            std.process.exit(1);
        },
        .status => runStatus(allocator, config) catch {
            config.deinit();
            std.process.exit(1);
        },
    }
}

test "parseMigrationNumber valid cases" {
    try std.testing.expectEqual(@as(u32, 1), try parseMigrationNumber("1_init.sql"));
    try std.testing.expectEqual(@as(u32, 1), try parseMigrationNumber("001_init.sql"));
    try std.testing.expectEqual(@as(u32, 123), try parseMigrationNumber("123_create_users.sql"));
    try std.testing.expectEqual(@as(u32, 1), try parseMigrationNumber("1_a.sql"));
}

test "parseMigrationNumber invalid cases" {
    try std.testing.expectError(MigrationError.InvalidFilenameFormat, parseMigrationNumber("init.sql"));
    try std.testing.expectError(MigrationError.InvalidFilenameFormat, parseMigrationNumber("_init.sql"));
    try std.testing.expectError(MigrationError.InvalidFilenameFormat, parseMigrationNumber("1_.sql"));
    try std.testing.expectError(MigrationError.InvalidFilenameFormat, parseMigrationNumber("1_init.txt"));
    try std.testing.expectError(MigrationError.InvalidFilenameFormat, parseMigrationNumber("abc_init.sql"));
    try std.testing.expectError(MigrationError.InvalidFilenameFormat, parseMigrationNumber("1a_init.sql"));
}

test "table name validation accepts conservative SQLite identifiers" {
    try std.testing.expect(isValidTableName("schema_migrations"));
    try std.testing.expect(isValidTableName("_migrations2"));
    try std.testing.expect(isValidTableName("Migrations"));
}

test "table name validation rejects unsafe identifiers" {
    try std.testing.expect(!isValidTableName(""));
    try std.testing.expect(!isValidTableName("1migrations"));
    try std.testing.expect(!isValidTableName("schema migrations"));
    try std.testing.expect(!isValidTableName("schema-migrations"));
    try std.testing.expect(!isValidTableName("migrations; DROP TABLE users"));
    try std.testing.expect(!isValidTableName("migratiöns"));
}

test "Config owns argument storage" {
    var db_source = [_]u8{ 'd', 'a', 't', 'a', '.', 'd', 'b' };
    var migrations_source = [_]u8{ 'm', 'i', 'g', 'r', 'a', 't', 'i', 'o', 'n', 's' };
    var table_source = [_]u8{ 'c', 'u', 's', 't', 'o', 'm' };

    var config = try Config.initOwned(
        std.testing.allocator,
        &db_source,
        &migrations_source,
        &table_source,
        .up,
    );
    defer config.deinit();

    @memset(&db_source, 'x');
    @memset(&migrations_source, 'x');
    @memset(&table_source, 'x');

    try std.testing.expectEqualStrings("data.db", config.db_path);
    try std.testing.expectEqualStrings("migrations", config.migrations_path);
    try std.testing.expectEqualStrings("custom", config.table_name);
}
