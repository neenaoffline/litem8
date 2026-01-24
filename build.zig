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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create SQLite module - the C source is added to the executable, not the module
    const sqlite_mod = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_mod.addIncludePath(b.path("deps/sqlite"));

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

    // Add SQLite C source to the executable
    exe.addCSourceFile(.{
        .file = b.path("deps/sqlite/sqlite3.c"),
        .flags = sqlite_cflags,
    });
    exe.addIncludePath(b.path("deps/sqlite"));
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
    // Cross-compilation targets for static binaries
    // =========================================================================

    const release_step = b.step("release", "Build static release binaries for all platforms");

    const targets: []const std.Target.Query = &.{
        // Linux (musl for static linking)
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf },
        .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .musl },
        // macOS
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        // Windows
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    for (targets) |t| {
        const release_target = b.resolveTargetQuery(t);

        const rel_sqlite_mod = b.addModule(b.fmt("sqlite-{s}-{s}", .{
            @tagName(t.cpu_arch orelse .x86_64),
            @tagName(t.os_tag orelse .linux),
        }), .{
            .root_source_file = b.path("src/sqlite.zig"),
            .target = release_target,
            .optimize = .ReleaseSafe,
        });
        rel_sqlite_mod.addIncludePath(b.path("deps/sqlite"));

        const rel_exe = b.addExecutable(.{
            .name = "litem8",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = release_target,
                .optimize = .ReleaseSafe,
                .imports = &.{
                    .{ .name = "litem8", .module = mod },
                    .{ .name = "sqlite", .module = rel_sqlite_mod },
                },
            }),
        });

        rel_exe.addCSourceFile(.{
            .file = b.path("deps/sqlite/sqlite3.c"),
            .flags = sqlite_cflags,
        });
        rel_exe.addIncludePath(b.path("deps/sqlite"));
        rel_exe.linkLibC();

        const target_output = b.addInstallArtifact(rel_exe, .{
            .dest_dir = .{
                .override = .{
                    .custom = b.fmt("{s}-{s}", .{
                        @tagName(t.cpu_arch orelse .x86_64),
                        @tagName(t.os_tag orelse .linux),
                    }),
                },
            },
        });

        release_step.dependOn(&target_output.step);
    }
}
