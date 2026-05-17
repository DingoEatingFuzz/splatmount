const std = @import("std");
const linux = std.os.linux;

//mount -o bind <source> <target>
pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    switch (args.len) {
        2 => {
            if (std.mem.eql(u8, args[1], "--help")) {
                exitWithHelp();
            } else {
                exitWithArgsError(args.len);
            }
        },
        4 => {
            // Refactor splatmount to handle all its own errors
            try splatmount(args, arena, init);
        },
        else => {
            exitWithArgsError(args.len);
        },
    }
}

fn exitWithHelp() void {
    const help =
        \\splatmount [source] [target] [fstype]
        \\
        \\Splatmount runs `mount -p bind` on every directory in the [source] directory, mounting them in [target].
        \\
        \\source: A filesystem path. Directories in this path will be mounted in target.
        \\target: A filesystem path. Directories in source will be mounted here.
        \\fstype: A filesystem type.
        \\        Try `cat /proc/filesystems` to see available options.
    ;
    std.log.info(help, .{});
    std.process.exit(0);
}

fn exitWithArgsError(len: usize) void {
    std.log.info("Expected 4 arguments, received {d}. Try splatmount --help", .{len});
    std.process.exit(1);
}

fn splatmount(args: []const [:0]const u8, arena: std.mem.Allocator, init: std.process.Init) !void {
    const source = args[1];
    const target = args[2];
    const fstype = args[3]; // btrfs

    var sourceSet = try getSubdirs(source, init.io, arena);
    var targetSet = try getSubdirs(target, init.io, arena);
    defer sourceSet.deinit();
    defer targetSet.deinit();

    std.log.info("Directories in source", .{});
    var iter = sourceSet.iterator();
    var i: u8 = 1;
    while (iter.next()) |entry| : (i += 1) {
        std.log.info("{d}) {s}", .{ i, entry.* });
    }

    std.log.info("Directories in target", .{});
    var iterT = targetSet.iterator();
    i = 1;
    while (iterT.next()) |entry| : (i += 1) {
        std.log.info("{d}) {s}", .{ i, entry.* });
    }

    var mountList = try getMountList(sourceSet, targetSet, arena);
    defer mountList.deinit(arena);

    // Handle the error
    try mountDirs(source, target, fstype, mountList, arena);
}

pub fn getMountList(source: std.BufSet, target: std.BufSet, alloc: std.mem.Allocator) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    var iter = source.iterator();
    while (iter.next()) |entry| {
        if (entry.*[0] != '.' and !target.contains(entry.*)) {
            try list.append(alloc, entry.*);
        }
    }
    return list;
}

pub fn mountDirs(sourcePrefix: [:0]const u8, targetPrefix: [:0]const u8, fstype: [:0]const u8, dirs: std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    for (dirs.items, 1..) |item, idx| {
        const fullsource = try std.mem.concat(allocator, u8, &[_][]const u8{ sourcePrefix, "/", item });
        const fulltarget = try std.mem.concat(allocator, u8, &[_][]const u8{ targetPrefix, "/", item });

        std.log.info("{d}) {s} [[{s} -> {s}]]", .{ idx, item, fullsource, fulltarget });
        // This is jank as hell and needs to be tested
        // Returns an error code, make sure to handle it
        // If any mount fails, call umount on any successful ones (i.e., treat all mounts as a single transaction)
        _ = linux.mount(try allocator.dupeSentinel(u8, fullsource, 0), try allocator.dupeSentinel(u8, fulltarget, 0), fstype, linux.MS.BIND, 0);
    }
}

pub fn getSubdirs(name: [:0]const u8, io: std.Io, alloc: std.mem.Allocator) !std.BufSet {
    var dir = std.Io.Dir.cwd().openDir(io, name, .{ .iterate = true }) catch |err| return err;
    defer dir.close(io);

    var set: std.BufSet = .init(alloc);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            try set.insert(entry.name);
        }
    }

    return set;
}

const expect = std.testing.expect;
const tallocator = std.testing.allocator;

test "mount list contains source entries not found in target" {
    var setA = std.BufSet.init(tallocator);
    defer setA.deinit();
    try setA.insert("abc");
    try setA.insert("def");
    try setA.insert("ghi");

    var setB = std.BufSet.init(tallocator);
    defer setB.deinit();
    try setB.insert("xyz");
    try setB.insert("abc");
    try setB.insert("uvw");

    var list = try getMountList(setA, setB, tallocator);
    defer list.deinit(tallocator);

    try expect(list.items.len == 2);
    try expect(std.mem.eql(u8, list.items[0], "def"));
    try expect(std.mem.eql(u8, list.items[1], "ghi"));
}

test "mount list omits entries starting with '.'" {
    var setA = std.BufSet.init(tallocator);
    defer setA.deinit();
    try setA.insert("abc");
    try setA.insert("def");
    try setA.insert("ghi");
    try setA.insert(".its");
    try setA.insert(".");
    try setA.insert("..");
    try setA.insert(".a secret");

    var setB = std.BufSet.init(tallocator);
    defer setB.deinit();

    var list = try getMountList(setA, setB, tallocator);
    defer list.deinit(tallocator);

    try expect(list.items.len == 3);
    try expect(std.mem.eql(u8, list.items[0], "abc"));
    try expect(std.mem.eql(u8, list.items[1], "def"));
    try expect(std.mem.eql(u8, list.items[2], "ghi"));
}
