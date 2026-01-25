const std = @import("std");

/// SQLite compilation flags for a minimal, static build
const sqlite_cflags: []const []const u8 = &.{
    "-DSQLITE_DQS=0", // Disable double-quoted string literals
    "-DSQLITE_THREADSAFE=0", // Single-threaded (faster, smaller)
    "-DSQLITE_DEFAULT_MEMSTATUS=0", // Disable memory status tracking
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1", // Normal sync for WAL mode
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS", // LIKE doesn't match blobs
    "-DSQLITE_MAX_EXPR_DEPTH=0", // Unlimited expression depth
    "-DSQLITE_OMIT_DECLTYPE", // Omit decltype
    "-DSQLITE_OMIT_DEPRECATED", // Omit deprecated features
    "-DSQLITE_OMIT_PROGRESS_CALLBACK", // Omit progress callback
    "-DSQLITE_OMIT_SHARED_CACHE", // Omit shared cache mode
    "-DSQLITE_USE_ALLOCA", // Use alloca for temp allocations
    "-DSQLITE_OMIT_AUTOINIT", // Require explicit init
};

/// Build configuration for a target
const BuildConfig = struct {
    target: std.Target.Query,
    /// If true, bundle SQLite source. If false, link to system libsqlite3.
    bundle_sqlite: bool = true,
    /// Output directory name
    output_dir: []const u8,
};

/// Create an executable with the given configuration
fn createExecutable(
    b: *std.Build,
    config: BuildConfig,
    mod: *std.Build.Module,
) *std.Build.Step.Compile {
    const resolved_target = b.resolveTargetQuery(config.target);

    // Create SQLite module
    const sqlite_mod = b.addModule(b.fmt("sqlite-{s}", .{config.output_dir}), .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = resolved_target,
        .optimize = .ReleaseSafe,
    });

    if (config.bundle_sqlite) {
        sqlite_mod.addIncludePath(b.path("deps/sqlite"));
    }

    // Create executable
    const exe = b.addExecutable(.{
        .name = "litem8",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = resolved_target,
            .optimize = .ReleaseSafe,
            .strip = true,
            .imports = &.{
                .{ .name = "litem8", .module = mod },
                .{ .name = "sqlite", .module = sqlite_mod },
            },
        }),
    });

    if (config.bundle_sqlite) {
        // Compile SQLite from bundled source
        exe.addCSourceFile(.{
            .file = b.path("deps/sqlite/sqlite3.c"),
            .flags = sqlite_cflags,
        });
        exe.addIncludePath(b.path("deps/sqlite"));
    } else {
        // Link against system libsqlite3
        exe.root_module.linkSystemLibrary("sqlite3", .{});
    }

    exe.linkLibC();

    return exe;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundle_sqlite = b.option(bool, "bundle-sqlite", "Bundle SQLite source (default: true)") orelse true;

    // Create SQLite module - the C source is added to the executable, not the module
    const sqlite_mod = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (bundle_sqlite) {
        sqlite_mod.addIncludePath(b.path("deps/sqlite"));
    }

    // Library module
    const mod = b.addModule("litem8", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "litem8",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "litem8", .module = mod },
                .{ .name = "sqlite", .module = sqlite_mod },
            },
        }),
    });

    if (bundle_sqlite) {
        // Add SQLite C source to the executable
        exe.addCSourceFile(.{
            .file = b.path("deps/sqlite/sqlite3.c"),
            .flags = sqlite_cflags,
        });
        exe.addIncludePath(b.path("deps/sqlite"));
    } else {
        // Link against system libsqlite3
        exe.root_module.linkSystemLibrary("sqlite3", .{});
    }
    exe.linkLibC();

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // E2E tests
    const e2e_sqlite_mod = b.addModule("e2e_sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_sqlite_mod.addIncludePath(b.path("deps/sqlite"));

    const e2e_test_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = e2e_sqlite_mod },
        },
    });

    const e2e_tests = b.addTest(.{
        .root_module = e2e_test_mod,
    });

    // Add SQLite to e2e tests
    e2e_tests.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3.c"),
        .flags = sqlite_cflags,
    });
    e2e_tests.addIncludePath(b.path("deps/sqlite"));
    e2e_tests.linkLibC();

    const exe_install_path = b.getInstallPath(.bin, "litem8");
    const options = b.addOptions();
    options.addOption([]const u8, "exe_path", exe_install_path);
    e2e_tests.root_module.addOptions("build_options", options);

    const run_e2e_tests = b.addRunArtifact(e2e_tests);
    run_e2e_tests.step.dependOn(b.getInstallStep());

    // Test step
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_e2e_tests.step);

    // =========================================================================
    // Release targets - static binaries with bundled SQLite
    // =========================================================================

    const release_step = b.step("release", "Build static release binaries (bundled SQLite) for all platforms");

    const static_targets: []const BuildConfig = &.{
        // Linux (musl for static linking)
        .{ .target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .output_dir = "x86_64-linux-musl-static" },
        .{ .target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .output_dir = "aarch64-linux-musl-static" },
        .{ .target = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf }, .output_dir = "arm-linux-musl-static" },
        .{ .target = .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .musl }, .output_dir = "riscv64-linux-musl-static" },
        // macOS
        .{ .target = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .output_dir = "x86_64-macos" },
        .{ .target = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .output_dir = "aarch64-macos" },
        // Windows
        .{ .target = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .output_dir = "x86_64-windows" },
        .{ .target = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .output_dir = "aarch64-windows" },
    };

    for (static_targets) |config| {
        const rel_exe = createExecutable(b, config, mod);
        const target_output = b.addInstallArtifact(rel_exe, .{
            .dest_dir = .{ .override = .{ .custom = config.output_dir } },
        });
        release_step.dependOn(&target_output.step);
    }

    // =========================================================================
    // Release targets - dynamic binaries linking to system SQLite
    // =========================================================================

    const release_dynamic_step = b.step("release-dynamic", "Build dynamic release binaries (system SQLite) for Linux");

    const dynamic_targets: []const BuildConfig = &.{
        // Linux glibc (dynamic linking)
        .{
            .target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .bundle_sqlite = false,
            .output_dir = "x86_64-linux-gnu",
        },
        .{
            .target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
            .bundle_sqlite = false,
            .output_dir = "aarch64-linux-gnu",
        },
        // Linux musl (dynamic linking)
        .{
            .target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
            .bundle_sqlite = false,
            .output_dir = "x86_64-linux-musl",
        },
        .{
            .target = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
            .bundle_sqlite = false,
            .output_dir = "aarch64-linux-musl",
        },
    };

    for (dynamic_targets) |config| {
        const rel_exe = createExecutable(b, config, mod);
        const target_output = b.addInstallArtifact(rel_exe, .{
            .dest_dir = .{ .override = .{ .custom = config.output_dir } },
        });
        release_dynamic_step.dependOn(&target_output.step);
    }

    // =========================================================================
    // Combined release-all target
    // =========================================================================

    const release_all_step = b.step("release-all", "Build all release binaries (static + dynamic)");
    release_all_step.dependOn(release_step);
    release_all_step.dependOn(release_dynamic_step);
}
