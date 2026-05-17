const std = @import("std");
const splatmount = @import("main.zig");

const expect = std.testing.expect;
const allocator = std.testing.allocator;
const io = std.testing.io;

const MockDir = struct {
    name: []const u8,
    files: ?[3][]const u8,
};

const TEST_DIR = "test_dirs";
const DIR_PERMS = std.Io.File.Permissions.default_dir;

fn setup() !void {
    // Make the test dir structure
    try std.Io.Dir.cwd().createDir(io, TEST_DIR, DIR_PERMS);
    var testDir = try std.Io.Dir.cwd().openDir(io, "test_dirs", .{});
    const srcTree = [_]MockDir{
        .{
            .name = "foo",
            .files = .{ "a", "b", "c" },
        },
        .{
            .name = "bar",
            .files = .{ "d", "e", "f" },
        },
        .{
            .name = "baz",
            .files = null,
        },
        .{
            .name = ".hidden",
            .files = .{ "x", "y", "z" },
        },
    };
    const targetTree = [_]MockDir{
        .{
            .name = "foo",
            .files = .{ "x", "y", "z" },
        },
        .{
            .name = "bar",
            .files = null,
        },
    };

    try testDir.createDir(io, "src", DIR_PERMS);
    var srcDir = try testDir.openDir(io, "src", .{});
    for (srcTree) |dir| {
        try srcDir.createDir(io, dir.name, DIR_PERMS);
        var newDir = try srcDir.openDir(io, dir.name, .{});
        if (dir.files) |files| {
            for (files) |file| {
                _ = try newDir.createFile(io, file, .{ .read = true });
            }
        }
    }

    try testDir.createDir(io, "target", DIR_PERMS);
    var targetDir = try testDir.openDir(io, "target", .{});
    for (targetTree) |dir| {
        try targetDir.createDir(io, dir.name, DIR_PERMS);
        var newDir = try targetDir.openDir(io, dir.name, .{});
        if (dir.files) |files| {
            for (files) |file| {
                _ = try newDir.createFile(io, file, .{ .read = true });
            }
        }
    }
}

fn teardown() void {
    // Remove the test dir structure
    std.Io.Dir.cwd().deleteTree(io, TEST_DIR) catch |err| {
        std.log.err("{}", .{err});
    };
}

test "getSubDirs gets all non-empty non-hidden directories" {
    std.testing.log_level = .debug;

    try setup();
    defer teardown();

    var src = try splatmount.getSubdirs(TEST_DIR ++ "/src", io, allocator);
    defer src.deinit();
    try expect(src.count() == 3);
    try expect(src.contains("foo"));
}
