const std = @import("std");
const Io = std.Io;
const linux = std.os.linux;
const fs = std.fs;
const StringHashMap = std.StringHashMap;
const BufSet = std.BufSet;

const splatmount = @import("splatmount");

//mount -o bind <source> <target>
pub fn main(init: std.process.Init) !void {
    // This is appropriate for anything that lives as long as the process.
    const arena: std.mem.Allocator = init.arena.allocator();

    // Accessing command line arguments:
    const args = try init.minimal.args.toSlice(arena);
    std.debug.assert(args.len == 3);

    const source = args[1];
    const target = args[2];
    std.log.info("source: {s}", .{source});
    std.log.info("target: {s}\n", .{target});

    // Ls the source directory
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

    std.log.info("Directories to mount", .{});
    var iterD = sourceSet.iterator();
    i = 1;
    while (iterD.next()) |entry| {
        if (!targetSet.contains(entry.*) and entry.*[0] != '.') {
            std.log.info("{d}) {s}", .{ i, entry.* });
            i += 1;
        }
    }

    // Remove all directories present in both sets
    // For each, call linux.mount(...)
}

pub fn getSubdirs(name: [:0]const u8, io: Io, alloc: std.mem.Allocator) !std.BufSet {
    var dir = Io.Dir.cwd().openDir(io, name, .{ .iterate = true }) catch |err| return err;
    defer dir.close(io);

    var set: BufSet = .init(alloc);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            try set.insert(entry.name);
        }
    }

    return set;
}
