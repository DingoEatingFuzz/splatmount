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
    defer testDir.close(io);
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
            .name = "new",
            .files = .{ "g", "h", "i" },
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
    defer srcDir.close(io);
    for (srcTree) |dir| {
        try srcDir.createDir(io, dir.name, DIR_PERMS);
        var newDir = try srcDir.openDir(io, dir.name, .{});
        defer newDir.close(io);
        if (dir.files) |files| {
            for (files) |file| {
                const f = try newDir.createFile(io, file, .{ .read = true });
                f.close(io);
            }
        }
    }

    try testDir.createDir(io, "target", DIR_PERMS);
    var targetDir = try testDir.openDir(io, "target", .{});
    defer targetDir.close(io);
    for (targetTree) |dir| {
        try targetDir.createDir(io, dir.name, DIR_PERMS);
        var newDir = try targetDir.openDir(io, dir.name, .{});
        defer newDir.close(io);
        if (dir.files) |files| {
            for (files) |file| {
                const f = try newDir.createFile(io, file, .{ .read = true });
                f.close(io);
            }
        }
    }
}

fn teardown(mounts: std.ArrayList([]const u8)) void {
    // Unmount everything
    for (mounts.items) |mount| {
        if (allocator.dupeSentinel(u8, mount, 0)) |ms| {
            defer allocator.free(ms);
            // TODO: try closing directories in setup
            // _ = std.os.linux.umount2(ms, std.os.linux.MNT.FORCE);
            const rc = std.os.linux.umount(ms);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                else => |err| {
                    std.log.err("Failed to unmount {s}: {}", .{ mount, err });
                },
            }
        } else |err| {
            std.log.err("Failed to teardown {}", .{err});
        }
    }
    // Remove the test dir structure
    std.Io.Dir.cwd().deleteTree(io, TEST_DIR) catch |err| {
        std.log.err("Could not delete tree {}", .{err});
    };
}

// test "getSubdirs gets all non-empty non-hidden directories" {
//     std.testing.log_level = .debug;
//
//     try setup();
//     defer teardown(.empty);
//
//     var src = try splatmount.getSubdirs(TEST_DIR ++ "/src", io, allocator);
//     defer src.deinit();
//
//     try expect(src.count() == 3);
//     try expect(src.contains("foo"));
//     try expect(src.contains("bar"));
//     try expect(src.contains("new"));
//     try expect(!src.contains("baz"));
//     try expect(!src.contains(".hidden"));
// }

test "splatmount mounts all directories" {
    std.testing.log_level = .debug;
    try setup();

    var mounts = splatmount.splatmount(&[_][:0]const u8{ "__", TEST_DIR ++ "/src", TEST_DIR ++ "/target", "ext4" }, allocator, io);
    defer mounts.deinit(allocator);
    defer {
        for (mounts.items) |mount| allocator.free(mount);
    }
    teardown(mounts);
}
