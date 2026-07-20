const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const neighborhood_mod = b.addModule("neighborhood", .{
        .root_source_file = b.path("src/neighborhood.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_suites = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "test-protocol", .path = "src/test_protocol.zig" },
        .{ .name = "test-suspicion", .path = "src/test_suspicion.zig" },
        .{ .name = "test-memberlist", .path = "src/test_memberlist.zig" },
        .{ .name = "test-gossip", .path = "src/test_gossip.zig" },
        .{ .name = "test-sim", .path = "src/test_sim.zig" },
    };

    const all_tests = b.step("test", "Run all test suites");

    for (test_suites) |t| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(t.path),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("neighborhood", neighborhood_mod);

        const test_exe = b.addTest(.{
            .name = t.name,
            .root_module = test_mod,
        });
        const run_test = b.addRunArtifact(test_exe);

        _ = b.step(t.name, t.name);
        all_tests.dependOn(&run_test.step);
    }

    // Build the library
    const lib_step = b.step("lib", "Build the neighborhood library");
    _ = lib_step;
}
