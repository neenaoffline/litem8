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
    db_path: []const u8,
    migrations_path: []const u8,
    table_name: []const u8,
    command: Command,
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
};

const MigrationError = error{
    InvalidFilenameFormat,
    DuplicateMigrationNumber,
    MigrationGapDetected,
    MigrationDirectoryNotFound,
    DatabaseError,
    SqlExecutionError,
};

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

    return .{ .config = Config{
        .db_path = db_path.?,
        .migrations_path = migrations_path.?,
        .table_name = table_name,
        .command = command.?,
    } };
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
    for (number_str) |c| {
        if (c < '0' or c > '9') {
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

fn openDatabase(allocator: Allocator, db_path: []const u8) !sqlite.Db {
    // Convert to sentinel-terminated string for C API
    const path_z = allocator.dupeZ(u8, db_path) catch {
        return MigrationError.DatabaseError;
    };
    defer allocator.free(path_z);

    return sqlite.Db.init(.{
        .mode = .{ .File = path_z },
        .open_flags = .{
            .write = true,
            .create = true,
        },
    }) catch {
        return MigrationError.DatabaseError;
    };
}

fn createMigrationsTable(db: *sqlite.Db, table_name: []const u8) !void {
    // Build CREATE TABLE statement
    const create_sql = std.fmt.allocPrint(
        std.heap.page_allocator,
        "CREATE TABLE IF NOT EXISTS {s} (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, run_at TEXT NOT NULL)",
        .{table_name},
    ) catch return MigrationError.DatabaseError;
    defer std.heap.page_allocator.free(create_sql);

    db.execDynamic(create_sql, .{}, .{}) catch {
        return MigrationError.DatabaseError;
    };
}

const MigrationRow = struct {
    name: []const u8,
    run_at: []const u8,
};

fn getRunMigrations(allocator: Allocator, db: *sqlite.Db, table_name: []const u8) ![]RunMigration {
    const query = std.fmt.allocPrint(
        allocator,
        "SELECT name, run_at FROM {s} ORDER BY id",
        .{table_name},
    ) catch return MigrationError.DatabaseError;
    defer allocator.free(query);

    var stmt = db.prepareDynamicWithDiags(query, .{}) catch {
        return MigrationError.DatabaseError;
    };
    defer stmt.deinit();

    var results: std.ArrayList(RunMigration) = .empty;
    errdefer results.deinit(allocator);

    var iter = stmt.iteratorAlloc(MigrationRow, allocator, .{}) catch {
        return MigrationError.DatabaseError;
    };

    while (true) {
        const row = iter.nextAlloc(allocator, .{}) catch {
            return MigrationError.DatabaseError;
        };
        if (row == null) break;

        const r = row.?;
        const name = r.name;
        const run_at = r.run_at;

        // Parse migration number from name
        const number = parseMigrationNumber(name) catch {
            // Skip invalid entries (shouldn't happen but be safe)
            continue;
        };

        try results.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .number = number,
            .run_at = try allocator.dupe(u8, run_at),
        });
    }

    return results.toOwnedSlice(allocator);
}

fn executeMigration(db: *sqlite.Db, migration: Migration, table_name: []const u8) !void {
    // Read migration file
    const raw_sql = std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        migration.path,
        10 * 1024 * 1024, // 10MB max
    ) catch {
        return MigrationError.SqlExecutionError;
    };
    defer std.heap.page_allocator.free(raw_sql);

    // Trim whitespace to avoid "empty query" errors from trailing newlines
    const sql = std.mem.trim(u8, raw_sql, " \t\n\r");
    if (sql.len == 0) {
        // Empty migration file - nothing to do
        return;
    }

    // Begin transaction
    db.execDynamic("BEGIN TRANSACTION", .{}, .{}) catch {
        return MigrationError.SqlExecutionError;
    };
    errdefer {
        db.execDynamic("ROLLBACK", .{}, .{}) catch {};
    }

    // Execute migration SQL using exec for multi-statement support
    // Note: execMulti has a bug with trailing whitespace, so we catch EmptyQuery and treat it as success
    db.execMulti(sql, .{}) catch |err| {
        // EmptyQuery can happen if SQL ends with whitespace after last statement - that's OK
        if (err == error.EmptyQuery) {
            // This is fine - the SQL was executed successfully
        } else {
            std.debug.print("Error executing migration {s}: {}\n", .{ migration.name, err });
            // Get detailed error from SQLite
            const detail = db.getDetailedError();
            std.debug.print("SQLite error: {s}\n", .{detail.message});
            db.execDynamic("ROLLBACK", .{}, .{}) catch {};
            return MigrationError.SqlExecutionError;
        }
    };

    // Get current timestamp
    const timestamp = getTimestamp();

    // Record migration
    const insert_sql = std.fmt.allocPrint(
        std.heap.page_allocator,
        "INSERT INTO {s} (name, run_at) VALUES ('{s}', '{s}')",
        .{ table_name, migration.name, timestamp },
    ) catch return MigrationError.SqlExecutionError;
    defer std.heap.page_allocator.free(insert_sql);

    db.execDynamic(insert_sql, .{}, .{}) catch {
        db.execDynamic("ROLLBACK", .{}, .{}) catch {};
        return MigrationError.SqlExecutionError;
    };

    // Commit transaction
    db.execDynamic("COMMIT", .{}, .{}) catch {
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
    var db = try openDatabase(allocator, config.db_path);
    defer db.deinit();

    // Create migrations table
    try createMigrationsTable(&db, config.table_name);

    // Get already-run migrations
    const run_migrations = try getRunMigrations(allocator, &db, config.table_name);

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
        try executeMigration(&db, migration, config.table_name);
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

    // Open database
    var db = try openDatabase(allocator, config.db_path);
    defer db.deinit();

    // Check if migrations table exists
    const check_sql = std.fmt.allocPrint(
        allocator,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='{s}'",
        .{config.table_name},
    ) catch return MigrationError.DatabaseError;
    defer allocator.free(check_sql);

    var check_stmt = db.prepareDynamicWithDiags(check_sql, .{}) catch {
        return MigrationError.DatabaseError;
    };
    defer check_stmt.deinit();

    // Use oneAlloc() to check if table exists (returns single row or null)
    const table_exists = (check_stmt.oneAlloc(struct { name: []const u8 }, allocator, .{}, .{}) catch {
        return MigrationError.DatabaseError;
    }) != null;

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

    const config = switch (try parseArgs(allocator)) {
        .config => |c| c,
        .help => return, // Exit 0 for help
        .err => std.process.exit(1),
    };

    switch (config.command) {
        .up => runUp(allocator, config) catch |err| {
            if (@TypeOf(err) == MigrationError) {
                std.process.exit(1);
            }
            return err;
        },
        .status => runStatus(allocator, config) catch |err| {
            if (@TypeOf(err) == MigrationError) {
                std.process.exit(1);
            }
            return err;
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
