const std = @import("std");

pub fn isPath(str: []const u8) bool {
    return std.mem.startsWith(u8, str, "/");
}

pub fn splitPath(path: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, path[1..], '/');
}

pub fn pathLength(path: []const u8) usize {
    var parts = splitPath(path);
    var length: usize = 0;

    inline while (parts.next()) |_|
        length += 1;

    return length;
}

pub fn paramType(comptime type_name: []const u8) type {
    if (std.mem.eql(u8, type_name, "u32")) {
        return u32;
    } else if (std.mem.eql(u8, type_name, "[]u8")) {
        return []const u8;
    } else {
        @compileError("Unsupported parameter type");
    }
}

pub fn stripError(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |info| info.payload,
        else => T,
    };
}

const TypeParser = struct {
    fn @"[]u8"(src: []const u8) []const u8 {
        return src;
    }

    fn @"u32"(src: []const u8) !u32 {
        return std.fmt.parseInt(u32, src, 10);
    }
};

pub fn parseType(comptime type_name: []const u8) type {
    const method = @field(TypeParser, type_name);
    switch (@typeInfo(@TypeOf(method))) {
        .@"fn" => |f| {
            const rt = f.return_type orelse @compileError("Function must return a type");
            return stripError(rt);
        },
        else => @compileError("Expected a function type"),
    }
}

pub fn patternType(comptime pattern: []const u8) type {
    comptime {
        const proto = std.builtin.Type.StructField{
            .name = "none",
            .type = void,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        };
        var parts = splitPath(pattern);
        var fields: [100]std.builtin.Type.StructField = @splat(proto);
        var index = 0;

        while (parts.next()) |part| {
            if (!std.mem.startsWith(u8, part, ":")) continue;
            if (index >= fields.len)
                @compileError("Too many path parameters");

            const tag = part[1..];

            const colon = std.mem.indexOfScalar(u8, tag, ':') orelse
                @compileError("Invalid path parameter format");

            var name: [colon:0]u8 = @splat(' ');
            for (name, 0..) |_, i| name[i] = tag[i];

            fields[index] = std.builtin.Type.StructField{
                .name = &name,
                .type = parseType(tag[colon + 1 ..]),
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = 0,
            };
            index += 1;
        }

        return @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = fields[0..index],
                .decls = &[_]std.builtin.Type.Declaration{},
                .is_tuple = false,
            },
        });
    }
}

pub fn matchPath(comptime pattern: []const u8, _: []const u8) ?patternType(pattern) {
    // if (std.mem.eql(u8, path, "/user/:id:u32")) {
    //     return UserId{ .id = 999 };
    // }
    return null;
    // comptime var parts = splitPath(pattern);
    // var pit = splitPath(path);
    // var obj = patternType(pattern){};
    // inline while (parts.next()) |patp| {
    //     const pitp = pit.next();
    //     if (pitp == null)
    //         return null; // Path does not match
    //     if (std.mem.startsWith(u8, patp, ":")) {
    //         const colon = std.mem.indexOfScalar(u8, patp, ':') orelse {
    //             @compileError("Invalid path parameter format");
    //         };
    //         const name = patp[0..colon];
    //         const type_name = patp[colon + 1 ..];
    //         if (std.mem.eql(u8, type_name, "u32")) {
    //             @field(obj, name) = 0;
    //         } else if (std.mem.eql(u8, type_name, "[]u8")) {
    //             @field(obj, name) = pitp;
    //         } else {
    //             @compileError("Unsupported parameter type");
    //         }
    //     } else {
    //         if (!std.mem.eql(u8, patp, pitp))
    //             return null; // Path does not match
    //     }
    // }

    // return obj;
}

pub fn make_despatch(comptime T: type) type {
    // switch (@typeInfo(T)) {
    //     .@"struct" => |info| {
    //         inline for (info.decls) |decl| {
    //             const name = decl.name;
    //         }
    //     },
    //     else => @compileError("Expected a struct type for the router"),
    // }

    return struct {
        router: T,
        const Self = @This();

        pub fn despatch(self: Self, path: []const u8) void {
            switch (@typeInfo(T)) {
                .@"struct" => |info| {
                    // std.debug.print("struct\n", .{});
                    inline for (info.decls) |decl| {
                        const name = decl.name;
                        if (matchPath(name, path)) |params| {
                            const method = @field(T, name);
                            switch (@typeInfo(@TypeOf(method))) {
                                .@"fn" => |f| {
                                    switch (f.params.len) {
                                        1 => method(self.router),
                                        2 => method(self.router, params),
                                        else => @compileError("Unexpected number of parameters"),
                                    }
                                },
                                else => @compileError("Expected a function type"),
                            }
                        }
                    }
                },
                else => @compileError("Expected a struct type for the router"),
            }
        }
    };
}

pub fn main() !void {
    const info = patternType("/user/:id:u32/:name:[]u8"){ .id = 999, .name = "John Doe" };
    std.debug.print("User ID: {d}, Name: {s}\n", .{ info.id, info.name });
    // Prints to stderr, ignoring potential errors.
    const Router = struct {
        const Self = @This();

        pub fn @"/index"(_: Self) void {
            std.debug.print("Hello, world!\n", .{});
        }

        pub fn @"/user/:id:u32"(_: Self, params: anytype) void {
            std.debug.print("user {d}\n", .{params.id});
        }

        // pub fn @"/tags/:tag:[]u8"(_: Self, params: struct { tag: []const u8 }) void {
        //     std.debug.print("tag {s}\n", .{params.tag});
        // }
    };
    const Despatch = make_despatch(Router);
    const router = Router{};
    const despatch = Despatch{ .router = router };
    despatch.despatch("/user/:id:u32");
    // despatch.despatch("/index");
    // router.@"/user/:id:u32"(.{ .id = 42 });
}
