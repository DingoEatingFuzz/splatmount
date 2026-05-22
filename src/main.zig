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
            _ = splatmount(args, arena, init.io);
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

// Return the set of new mounts (target paths)
pub fn splatmount(args: []const [:0]const u8, arena: std.mem.Allocator, io: std.Io) std.ArrayList([]const u8) {
    const source = args[1];
    const target = args[2];
    const fstype = args[3]; // btrfs

    var sourceSet = getSubdirs(source, io, arena) catch |err| {
        std.log.err("Failed to get source directories: {}", .{err});
        std.process.exit(1);
    };
    var targetSet = getSubdirs(target, io, arena) catch |err| {
        std.log.err("Failed to get target directories: {}", .{err});
        std.process.exit(1);
    };

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

    var mountList = getMountList(sourceSet, targetSet, arena) catch |err| {
        std.log.err("Out of memory when determining mount list: {}", .{err});
        std.process.exit(1);
    };

    defer mountList.deinit(arena);

    // Handle the error
    return mountDirs(source, target, fstype, mountList, io, arena) catch |err| {
        switch (err) {
            error.InsufficientPermissions => std.log.err("Insufficient permissions. Try running with sudo", .{}),
            error.NoSuchDirectory => std.log.err("Could not find a directory", .{}),
            else => std.log.err("Failed to mount all directories. No directories mounted.", .{}),
        }
        std.process.exit(1);
    };
}

pub fn getMountList(source: std.BufSet, target: std.BufSet, alloc: std.mem.Allocator) !std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    var iter = source.iterator();
    while (iter.next()) |entry| {
        // Include entries in target that are empty
        if (entry.*[0] != '.' and !target.contains(entry.*)) {
            try list.append(alloc, entry.*);
        }
    }
    return list;
}

pub fn mountDirs(sourcePrefix: [:0]const u8, targetPrefix: [:0]const u8, fstype: [:0]const u8, dirs: std.ArrayList([]const u8), io: std.Io, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var newdirs: std.ArrayList([:0]const u8) = .empty;
    var newmounts: std.ArrayList([:0]const u8) = .empty;
    var abort = false;
    var ret: anyerror = undefined;

    defer newdirs.deinit(allocator);
    defer newmounts.deinit(allocator);

    // Before making any directories or mounting anything, ensure we can build all the strings
    var dirpairs: std.ArrayList([2][:0]const u8) = .empty;
    defer dirpairs.deinit(allocator);

    for (dirs.items) |item| {
        const fullsource = try std.mem.concat(allocator, u8, &[_][]const u8{ sourcePrefix, "/", item });
        const fulltarget = try std.mem.concat(allocator, u8, &[_][]const u8{ targetPrefix, "/", item });
        defer allocator.free(fullsource);
        defer allocator.free(fulltarget);

        const mountFrom = try allocator.dupeSentinel(u8, fullsource, 0);
        const mountTo = try allocator.dupeSentinel(u8, fulltarget, 0);

        try dirpairs.append(allocator, .{ mountFrom, mountTo });
    }
    defer {
        for (dirpairs.items) |pair| {
            allocator.free(pair[0]);
            allocator.free(pair[1]);
        }
    }

    std.log.info("Required mounts:", .{});
    for (dirpairs.items, 1..) |pair, idx| {
        std.log.info("{d}) {s} -> {s}", .{ idx, pair[0], pair[1] });
    }

    std.log.info("Making mounts", .{});
    for (dirpairs.items, 1..) |pair, idx| {
        const fullsource = pair[0];
        const fulltarget = pair[1];

        // If the target dir doesn't exist, make it (needed to mount on)
        std.log.info("{d}) Making missing dir: {s}", .{ idx, fulltarget });
        const maybeDir = std.Io.Dir.cwd().createDir(io, fulltarget, std.Io.File.Permissions.default_dir);
        if (maybeDir) {
            newdirs.append(allocator, fulltarget) catch |nerr| {
                std.log.err("Could not create new dir {s}", .{fulltarget});
                ret = nerr;
                abort = true;
                std.Io.Dir.cwd().deleteDir(io, fulltarget) catch |cleanErr| {
                    std.log.err("Could not clean up new dir {s}", .{fulltarget});
                    ret = cleanErr;
                };
                break;
            };
        } else |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    abort = true;
                    std.log.err("Surprise error when attempting to create a dir", .{});
                    ret = err;
                },
            }
        }

        std.log.info("{d}) Mounting: {s} -> {s}", .{ idx, fullsource, fulltarget });

        const rc = linux.mount(fullsource, fulltarget, fstype, linux.MS.BIND, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                newmounts.append(allocator, fulltarget) catch |err| {
                    _ = linux.umount(fulltarget);
                    abort = true;
                    std.log.err("Could not allocate newmount", .{});
                    ret = err;
                    break;
                };
                continue;
            },
            else => |err| {
                abort = true;
                std.log.err("Kernel error from mount syscall", .{});
                switch (err) {
                    .PERM => ret = error.InsufficientPermissions,
                    .NOENT => ret = error.NoSuchDirectory,
                    else => |ierr| ret = std.posix.unexpectedErrno(ierr),
                }
                break;
            },
        }
    }

    // mountDirs is transactional: if anything fails, undo everything that succeeded.
    if (abort) {
        for (newmounts.items) |mnt| {
            const rc = linux.umount(mnt);
            switch (linux.errno(rc)) {
                .SUCCESS => continue,
                else => {
                    std.log.err("Kernel error from umount syscall {s}", .{mnt});
                    ret = error.CouldNotCleanUpMounts;
                },
            }
        }
        for (newdirs.items) |dir| {
            std.Io.Dir.cwd().deleteDir(io, dir) catch {
                std.log.err("Could not delete dir {s}", .{dir});
                if (ret != error.CouldNotCleanUpMounts) {
                    ret = error.CouldNotCleanUpDirectories;
                }
            };
        }
        return ret;
    }

    var mounted: std.ArrayList([]const u8) = .empty;
    for (dirpairs.items) |item| {
        const copy = std.mem.Allocator.dupe(allocator, u8, item[1]) catch {
            return error.SuccessfullyMountedFailedToReport;
        };
        mounted.append(allocator, copy) catch {
            return error.SuccessfullyMountedFailedToReport;
        };
    }
    return mounted;
}

pub fn getSubdirs(name: [:0]const u8, io: std.Io, alloc: std.mem.Allocator) !std.BufSet {
    var dir = try std.Io.Dir.cwd().openDir(io, name, .{ .iterate = true });
    defer dir.close(io);

    var set: std.BufSet = .init(alloc);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            // Exclude hidden directories
            if (entry.name[0] == '.') continue;

            // Exclude empty subdirs
            const subdirName = try std.fs.path.resolve(alloc, &[_][]const u8{ name, entry.name });
            defer alloc.free(subdirName);

            var subdir = try std.Io.Dir.cwd().openDir(io, subdirName, .{ .iterate = true });
            defer subdir.close(io);
            var subiter = subdir.iterate();

            // If next returns an entry, the directory is not empty
            if (try subiter.next(io)) |_| {
                try set.insert(entry.name);
            }
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
