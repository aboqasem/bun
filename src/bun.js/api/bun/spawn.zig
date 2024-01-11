const JSC = @import("root").bun.JSC;
const bun = @import("root").bun;
const string = bun.string;
const std = @import("std");

fn _getSystem() type {
    // this is a workaround for a Zig stage1 bug
    // the "usingnamespace" is evaluating in dead branches
    return brk: {
        if (comptime bun.Environment.isLinux) {
            const Type = bun.C.linux;
            break :brk struct {
                pub usingnamespace std.os.system;
                pub usingnamespace Type;
            };
        }

        break :brk std.os.system;
    };
}

const Environment = bun.Environment;
const system = _getSystem();

const Maybe = JSC.Node.Maybe;

const fd_t = std.os.fd_t;
const pid_t = if(Environment.isWindows) bun.windows.libuv.uv_pid_t else std.os.pid_t;
const toPosixPath = std.os.toPosixPath;
const errno = std.os.errno;
const mode_t = std.os.mode_t;
const unexpectedErrno = std.os.unexpectedErrno;

pub const BunSpawn = struct {
    pub const Action = extern struct {
        pub const FileActionType = enum(u8) {
            none = 0,
            close = 1,
            dup2 = 2,
            open = 3,
        };

        kind: FileActionType = .none,
        path: ?[*:0]const u8 = null,
        fds: [2]c_int = .{ 0, 0 },
        flags: c_int = 0,
        mode: c_int = 0,

        pub fn init() !Action {
            return .{};
        }

        pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
            if (self.kind == .open) {
                if (self.path) |path| {
                    allocator.free(bun.span(path));
                }
            }
        }
    };

    pub const Actions = struct {
        chdir_buf: ?[*:0]u8 = null,
        actions: std.ArrayListUnmanaged(Action) = .{},
        detached: bool = false,

        pub fn init() !Actions {
            return .{};
        }

        pub fn deinit(self: *Actions) void {
            if (self.chdir_buf) |buf| {
                bun.default_allocator.free(bun.span(buf));
            }

            for (self.actions.items) |*action| {
                action.deinit(bun.default_allocator);
            }

            self.actions.deinit(bun.default_allocator);
        }

        pub fn open(self: *Actions, fd: fd_t, path: []const u8, flags: u32, mode: i32) !void {
            const posix_path = try toPosixPath(path);

            return self.openZ(fd, &posix_path, flags, mode);
        }

        pub fn openZ(self: *Actions, fd: fd_t, path: [*:0]const u8, flags: u32, mode: i32) !void {
            try self.actions.append(bun.default_allocator, .{
                .kind = .open,
                .path = (try bun.default_allocator.dupeZ(u8, bun.span(path))).ptr,
                .flags = @intCast(flags),
                .mode = @intCast(mode),
                .fds = .{ fd, 0 },
            });
        }

        pub fn close(self: *Actions, fd: fd_t) !void {
            try self.actions.append(bun.default_allocator, .{
                .kind = .close,
                .fds = .{ fd, 0 },
            });
        }

        pub fn dup2(self: *Actions, fd: fd_t, newfd: fd_t) !void {
            try self.actions.append(bun.default_allocator, .{
                .kind = .dup2,
                .fds = .{ @truncate(fd), @truncate(newfd) },
            });
        }

        pub fn inherit(self: *Actions, fd: fd_t) !void {
            _ = self;
            _ = fd;

            @panic("not implemented");
        }

        pub fn chdir(self: *Actions, path: []const u8) !void {
            if (self.chdir_buf) |buf| {
                bun.default_allocator.free(bun.span(buf));
            }

            self.chdir_buf = (try bun.default_allocator.dupeZ(u8, path)).ptr;
        }
    };

    pub const Attr = struct {
        detached: bool = false,

        pub fn init() !Attr {
            return Attr{};
        }

        pub fn deinit(_: *Attr) void {}

        pub fn get(self: Attr) !u16 {
            var flags: c_int = 0;

            if (self.detached) {
                flags |= bun.C.POSIX_SPAWN_SETSID;
            }

            return @intCast(flags);
        }

        pub fn set(self: *Attr, flags: u16) !void {
            self.detached = (flags & bun.C.POSIX_SPAWN_SETSID) != 0;
        }

        pub fn resetSignals(this: *Attr) !void {
            _ = this;
        }
    };
};


const win_rusage = struct {
    utime: struct {
        tv_sec: c_long = 0,
        tv_usec: c_long = 0,
    },
    stime: struct {
        tv_sec: c_long = 0,
        tv_usec: c_long = 0,
    },
    maxrss: u0 = 0,
    ixrss: u0 = 0,
    idrss: u0 = 0,
    isrss: u0 = 0,
    minflt: u0 = 0,
    majflt: u0 = 0,
    nswap: u0 = 0,
    inblock: u0 = 0,
    oublock: u0 = 0,
    msgsnd: u0 = 0,
    msgrcv: u0 = 0,
    nsignals: u0 = 0,
    nvcsw: u0 = 0,
    nivcsw: u0 = 0,
};
pub const Rusage = if (Environment.isWindows) win_rusage else std.os.rusage;


// mostly taken from zig's posix_spawn.zig
pub const PosixSpawn = struct {
    pub const WaitPidResult = struct {
        pid: pid_t,
        status: u32,
    };

    pub const PosixSpawnAttr = struct {
        attr: system.posix_spawnattr_t,

        pub fn init() !PosixSpawnAttr {
            var attr: system.posix_spawnattr_t = undefined;
            switch (errno(system.posix_spawnattr_init(&attr))) {
                .SUCCESS => return PosixSpawnAttr{ .attr = attr },
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn deinit(self: *PosixSpawnAttr) void {
            if (comptime bun.Environment.isMac) {
                // https://github.com/ziglang/zig/issues/12964
                _ = system.posix_spawnattr_destroy(&self.attr);
            } else {
                _ = system.posix_spawnattr_destroy(&self.attr);
            }
        }

        pub fn get(self: PosixSpawnAttr) !u16 {
            var flags: c_short = undefined;
            switch (errno(system.posix_spawnattr_getflags(&self.attr, &flags))) {
                .SUCCESS => return @as(u16, @bitCast(flags)),
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn set(self: *PosixSpawnAttr, flags: u16) !void {
            switch (errno(system.posix_spawnattr_setflags(&self.attr, @as(c_short, @bitCast(flags))))) {
                .SUCCESS => return,
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn resetSignals(this: *PosixSpawnAttr) !void {
            if (posix_spawnattr_reset_signals(&this.attr) != 0) {
                return error.SystemResources;
            }
        }

        extern fn posix_spawnattr_reset_signals(attr: *system.posix_spawnattr_t) c_int;
    };

    pub const PosixSpawnActions = struct {
        actions: system.posix_spawn_file_actions_t,

        pub fn init() !PosixSpawnActions {
            var actions: system.posix_spawn_file_actions_t = undefined;
            switch (errno(system.posix_spawn_file_actions_init(&actions))) {
                .SUCCESS => return PosixSpawnActions{ .actions = actions },
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn deinit(self: *PosixSpawnActions) void {
            if (comptime bun.Environment.isMac) {
                // https://github.com/ziglang/zig/issues/12964
                _ = system.posix_spawn_file_actions_destroy(&self.actions);
            } else {
                _ = system.posix_spawn_file_actions_destroy(&self.actions);
            }

            self.* = undefined;
        }

        pub fn open(self: *PosixSpawnActions, fd: fd_t, path: []const u8, flags: u32, mode: mode_t) !void {
            const posix_path = try toPosixPath(path);
            return self.openZ(fd, &posix_path, flags, mode);
        }

        pub fn openZ(self: *PosixSpawnActions, fd: fd_t, path: [*:0]const u8, flags: u32, mode: mode_t) !void {
            switch (errno(system.posix_spawn_file_actions_addopen(&self.actions, fd, path, @as(c_int, @bitCast(flags)), mode))) {
                .SUCCESS => return,
                .BADF => return error.InvalidFileDescriptor,
                .NOMEM => return error.SystemResources,
                .NAMETOOLONG => return error.NameTooLong,
                .INVAL => unreachable, // the value of file actions is invalid
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn close(self: *PosixSpawnActions, fd: fd_t) !void {
            switch (errno(system.posix_spawn_file_actions_addclose(&self.actions, fd))) {
                .SUCCESS => return,
                .BADF => return error.InvalidFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable, // the value of file actions is invalid
                .NAMETOOLONG => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn dup2(self: *PosixSpawnActions, fd: fd_t, newfd: fd_t) !void {
            switch (errno(system.posix_spawn_file_actions_adddup2(&self.actions, fd, newfd))) {
                .SUCCESS => return,
                .BADF => return error.InvalidFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable, // the value of file actions is invalid
                .NAMETOOLONG => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn inherit(self: *PosixSpawnActions, fd: fd_t) !void {
            switch (errno(system.posix_spawn_file_actions_addinherit_np(&self.actions, fd))) {
                .SUCCESS => return,
                .BADF => return error.InvalidFileDescriptor,
                .NOMEM => return error.SystemResources,
                .INVAL => unreachable, // the value of file actions is invalid
                .NAMETOOLONG => unreachable,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn chdir(self: *PosixSpawnActions, path: []const u8) !void {
            const posix_path = try toPosixPath(path);
            return self.chdirZ(&posix_path);
        }

        // deliberately not pub
        fn chdirZ(self: *PosixSpawnActions, path: [*:0]const u8) !void {
            switch (errno(system.posix_spawn_file_actions_addchdir_np(&self.actions, path))) {
                .SUCCESS => return,
                .NOMEM => return error.SystemResources,
                .NAMETOOLONG => return error.NameTooLong,
                .BADF => unreachable,
                .INVAL => unreachable, // the value of file actions is invalid
                else => |err| return unexpectedErrno(err),
            }
        }
    };

    pub const Actions = if (Environment.isLinux) BunSpawn.Actions else PosixSpawnActions;
    pub const Attr = if (Environment.isLinux) BunSpawn.Attr else PosixSpawnAttr;

    const BunSpawnRequest = extern struct {
        chdir_buf: ?[*:0]u8 = null,
        detached: bool = false,
        actions: ActionsList = .{},

        const ActionsList = extern struct {
            ptr: ?[*]const BunSpawn.Action = null,
            len: usize = 0,
        };

        extern fn posix_spawn_bun(
            pid: *c_int,
            request: *const BunSpawnRequest,
            argv: [*:null]?[*:0]const u8,
            envp: [*:null]?[*:0]const u8,
        ) isize;

        pub fn spawn(
            req_: BunSpawnRequest,
            argv: [*:null]?[*:0]const u8,
            envp: [*:null]?[*:0]const u8,
        ) Maybe(pid_t) {
            var req = req_;
            var pid: c_int = 0;

            const rc = posix_spawn_bun(&pid, &req, argv, envp);
            if (comptime bun.Environment.allow_assert)
                bun.sys.syslog("posix_spawn_bun({s}) = {d} ({d})", .{
                    bun.span(argv[0] orelse ""),
                    rc,
                    pid,
                });

            if (rc == 0) {
                return Maybe(pid_t){ .result = @intCast(pid) };
            }

            return Maybe(pid_t){
                .err = .{
                    .errno = @as(bun.sys.Error.Int, @truncate(@intFromEnum(@as(std.c.E, @enumFromInt(rc))))),
                    .syscall = .posix_spawn,
                    .path = bun.span(argv[0] orelse ""),
                },
            };
        }
    };

    pub fn spawnZ(
        path: [*:0]const u8,
        actions: ?Actions,
        attr: ?Attr,
        argv: [*:null]?[*:0]const u8,
        envp: [*:null]?[*:0]const u8,
    ) Maybe(pid_t) {
        if (comptime Environment.isLinux) {
            return BunSpawnRequest.spawn(
                .{
                    .actions = if (actions) |act| .{
                        .ptr = act.actions.items.ptr,
                        .len = act.actions.items.len,
                    } else .{
                        .ptr = null,
                        .len = 0,
                    },
                    .chdir_buf = if (actions) |a| a.chdir_buf else null,
                    .detached = if (attr) |a| a.detached else false,
                },
                argv,
                envp,
            );
        }

        var pid: pid_t = undefined;
        const rc = system.posix_spawn(
            &pid,
            path,
            if (actions) |a| &a.actions else null,
            if (attr) |a| &a.attr else null,
            argv,
            envp,
        );
        if (comptime bun.Environment.allow_assert)
            bun.sys.syslog("posix_spawn({s}) = {d} ({d})", .{
                path,
                rc,
                pid,
            });

        // Unlike most syscalls, posix_spawn returns 0 on success and an errno on failure.
        // That is why std.c.getErrno() is not used here, since that checks for -1.
        if (rc == 0) {
            return Maybe(pid_t){ .result = pid };
        }

        return Maybe(pid_t){
            .err = .{
                .errno = @as(bun.sys.Error.Int, @truncate(@intFromEnum(@as(std.c.E, @enumFromInt(rc))))),
                .syscall = .posix_spawn,
                .path = bun.asByteSlice(path),
            },
        };
    }

    /// Use this version of the `waitpid` wrapper if you spawned your child process using `posix_spawn`
    /// or `posix_spawnp` syscalls.
    /// See also `std.os.waitpid` for an alternative if your child process was spawned via `fork` and
    /// `execve` method.
    pub fn waitpid(pid: pid_t, flags: u32) Maybe(WaitPidResult) {
        
        if(Environment.isWindows) {
            var status: u32 = 0;
            const process: *anyopaque = @ptrFromInt(@as(usize, @intCast(pid)));
            while(true) {
                std.os.windows.WaitForSingleObject(process, 0) catch |err| {
                    return switch(err) {
                       error.WaitTimeOut, error.WaitAbandoned => continue,
                       else => return .{
                            .err = .{
                                .errno = @intFromEnum(std.os.windows.kernel32.GetLastError()),
                                .syscall = .waitpid,
                            },
                       },
                    };
                };
                break;
            }
            if(std.os.windows.kernel32.GetExitCodeProcess(process, &status) == 0) {
                return .{
                    .err = .{
                        .errno = @intFromEnum(std.os.windows.kernel32.GetLastError()),
                        .syscall = .waitpid,
                    },
               };
            }
            return .{
                .result = .{
                    .pid = pid,
                    .status = @as(u32, @bitCast(status)),
                },
            };
        } else {
            var status: c_int = 0;
            while (true) {
                const rc = system.waitpid(pid, &status, @as(c_int, @intCast(flags)));
                switch (errno(rc)) {
                    .SUCCESS => return Maybe(WaitPidResult){
                        .result = .{
                            .pid = @as(pid_t, @intCast(rc)),
                            .status = @as(u32, @bitCast(status)),
                        },
                    },
                    .INTR => continue,

                    else => return JSC.Maybe(WaitPidResult).errnoSys(rc, .waitpid).?,
                }
            }
        }
    }

    /// Same as waitpid, but also returns resource usage information.
    pub fn wait4(pid: pid_t, flags: u32, usage: ?*Rusage) Maybe(WaitPidResult) {
        const Status = c_int;
        var status: Status = 0;
        if(Environment.isWindows) {
            const result = waitpid(pid, flags);
            if(usage) |info| {
                //rusage requested so we try to add some info
                var usage_info: Rusage = .{ .utime = .{}, .stime = .{}};
                const process: *anyopaque = @ptrFromInt(@as(usize, @intCast(pid)));
                const WinTime = std.os.windows.FILETIME;
                var starttime: WinTime = undefined;
                var exittime: WinTime = undefined;
                var kerneltime: WinTime = undefined;
                var usertime: WinTime = undefined;
                // We at least get process times
                if(std.os.windows.kernel32.GetProcessTimes(process, &starttime, &exittime, &kerneltime, &usertime) != 0) {
                    var temp: std.os.windows.ULARGE_INTEGER = undefined;
                    @memcpy(std.mem.asBytes(&temp), std.mem.asBytes(&kerneltime));   
                    if(temp > 0) {
                        usage_info.stime.tv_sec = @intCast(temp / 10000000);
                        usage_info.stime.tv_usec = @intCast(temp % 10000000);
                    }
                    @memcpy(std.mem.asBytes(&temp), std.mem.asBytes(&usertime));
                    if(temp > 0) {
                        usage_info.utime.tv_sec = @intCast(temp / 10000000);
                        usage_info.utime.tv_usec = @intCast(temp % 10000000);
                    }
                }
                info.* = usage_info;
            }
            return result;
        }
        while (true) {
            const rc = system.wait4(pid, &status, @as(c_int, @intCast(flags)), usage);
            switch (errno(rc)) {
                .SUCCESS => return Maybe(WaitPidResult){
                    .result = .{
                        .pid = @as(pid_t, @intCast(rc)),
                        .status = @as(u32, @bitCast(status)),
                    },
                },
                .INTR => continue,

                else => return JSC.Maybe(WaitPidResult).errnoSys(rc, .waitpid).?,
            }
        }
    }
};
