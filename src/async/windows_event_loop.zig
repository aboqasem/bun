const bun = @import("root").bun;
const Output = bun.Output;
const JSC = bun.JSC;
const uws = bun.uws;
const Environment = bun.Environment;
const std = @import("std");
const uv = bun.windows.libuv;
pub const Loop = uv.Loop;
const FileSink = JSC.WebCore.FileSink;
const FIFO = JSC.WebCore.FIFO;
const Subprocess = JSC.Subprocess;

pub const KeepAlive = struct {
    // handle.init zeroes the memory
    handle: uv.uv_async_t = undefined,

    status: Status = .inactive,

    const log = Output.scoped(.KeepAlive, false);

    const Status = enum { active, inactive, done };

    pub inline fn isActive(this: KeepAlive) bool {
        if (comptime Environment.allow_assert) {
            if (this.status == .active) {
                std.debug.assert(this.handle.isActive());
            }
        }
        return this.status == .active;
    }

    /// Make calling ref() on this poll into a no-op.
    pub fn disable(this: *KeepAlive) void {
        if (this.status == .active) {
            this.unref(JSC.VirtualMachine.get());
            this.handle.close(null);
        }

        this.status = .done;
    }

    /// Only intended to be used from EventLoop.Pollable
    pub fn deactivate(this: *KeepAlive, loop: *Loop) void {
        _ = loop;
        if (this.status != .active)
            return;

        this.status = .inactive;
        this.handle.close(null);
    }

    /// Only intended to be used from EventLoop.Pollable
    pub fn activate(this: *KeepAlive, loop: *Loop) void {
        if (this.status != .active)
            return;

        this.status = .active;
        this.handle.init(loop, null);
    }

    pub fn init() KeepAlive {
        return .{};
    }

    /// Prevent a poll from keeping the process alive.
    pub fn unref(this: *KeepAlive, vm: *JSC.VirtualMachine) void {
        _ = vm;
        if (this.status != .active)
            return;
        this.status = .inactive;
        this.handle.unref();
    }

    /// From another thread, Prevent a poll from keeping the process alive.
    pub fn unrefConcurrently(this: *KeepAlive, vm: *JSC.VirtualMachine) void {
        _ = vm;
        if (this.status != .active)
            return;
        this.status = .inactive;

        // TODO: https://github.com/oven-sh/bun/pull/4410#discussion_r1317326194
        this.handle.unref();
    }

    /// Prevent a poll from keeping the process alive on the next tick.
    pub fn unrefOnNextTick(this: *KeepAlive, vm: *JSC.VirtualMachine) void {
        _ = vm;
        if (this.status != .active)
            return;
        this.status = .inactive;
        this.handle.unref();
    }

    /// From another thread, prevent a poll from keeping the process alive on the next tick.
    pub fn unrefOnNextTickConcurrently(this: *KeepAlive, vm: *JSC.VirtualMachine) void {
        _ = vm;
        if (this.status != .active)
            return;
        this.status = .inactive;
        // TODO: https://github.com/oven-sh/bun/pull/4410#discussion_r1317326194
        this.handle.unref();
    }

    /// Allow a poll to keep the process alive.
    pub fn ref(this: *KeepAlive, vm: *JSC.VirtualMachine) void {
        if (this.status != .inactive)
            return;
        this.status = .active;
        this.handle.init(vm.event_loop_handle.?, null);
        this.handle.ref();
    }

    /// Allow a poll to keep the process alive.
    pub fn refConcurrently(this: *KeepAlive, vm: *JSC.VirtualMachine) void {
        if (this.status != .inactive)
            return;
        this.status = .active;
        // TODO: https://github.com/oven-sh/bun/pull/4410#discussion_r1317326194
        this.handle.init(vm.event_loop_handle.?, null);
        this.handle.ref();
    }

    pub fn refConcurrentlyFromEventLoop(this: *KeepAlive, loop: *JSC.EventLoop) void {
        this.refConcurrently(loop.virtual_machine);
    }

    pub fn unrefConcurrentlyFromEventLoop(this: *KeepAlive, loop: *JSC.EventLoop) void {
        this.unrefConcurrently(loop.virtual_machine);
    }
};

const Posix = @import("./posix_event_loop.zig");

pub const FilePoll = struct {
    fd: bun.FileDescriptor,
    owner: Owner = undefined,
    flags: Flags.Set = Flags.Set{},
    next_to_free: ?*FilePoll = null,
    handle: ?uv.uv_poll_t,
    pub const Flags = Posix.FilePoll.Flags;
    pub const Owner = Posix.FilePoll.Owner;

    const log = Output.scoped(.FilePoll, false);

    pub inline fn isActive(this: *const FilePoll) bool {
        return this.flags.contains(.has_incremented_poll_count);
    }

    pub inline fn isWatching(this: *const FilePoll) bool {
        return !this.flags.contains(.needs_rearm) and (this.flags.contains(.poll_readable) or this.flags.contains(.poll_writable) or this.flags.contains(.poll_process));
    }

    pub inline fn isKeepingProcessAlive(this: *const FilePoll) bool {
        return !this.flags.contains(.closed) and this.isActive();
    }

    pub fn isRegistered(this: *const FilePoll) bool {
        return this.flags.contains(.poll_writable) or this.flags.contains(.poll_readable) or this.flags.contains(.poll_process) or this.flags.contains(.poll_machport);
    }

    /// Make calling ref() on this poll into a no-op.
    pub fn disableKeepingProcessAlive(this: *FilePoll, vm: *JSC.VirtualMachine) void {
        if (this.flags.contains(.closed))
            return;
        this.flags.insert(.closed);

        vm.event_loop_handle.?.active_handles -= @as(u32, @intFromBool(this.flags.contains(.has_incremented_poll_count)));
    }

    pub fn init(vm: *JSC.VirtualMachine, fd: bun.FileDescriptor, flags: Flags.Struct, comptime Type: type, owner: *Type) *FilePoll {
        return initWithOwner(vm, fd, flags, Owner.init(owner));
    }

    pub fn initWithOwner(vm: *JSC.VirtualMachine, fd: bun.FileDescriptor, flags: Flags.Struct, owner: Owner) *FilePoll {
        var poll = vm.rareData().filePolls(vm).get();
        poll.fd = fd;
        poll.flags = Flags.Set.init(flags);
        poll.owner = owner;
        poll.next_to_free = null;

        return poll;
    }

    pub fn initWithPackageManager(m: *bun.PackageManager, fd: bun.FileDescriptor, flags: Flags.Struct, owner: anytype) *FilePoll {
        return initWithPackageManagerWithOwner(m, fd, flags, Owner.init(owner));
    }

    pub fn initWithPackageManagerWithOwner(manager: *bun.PackageManager, fd: bun.FileDescriptor, flags: Flags.Struct, owner: Owner) *FilePoll {
        var poll = manager.file_poll_store.get();
        poll.fd = fd;
        poll.flags = Flags.Set.init(flags);
        poll.owner = owner;
        poll.next_to_free = null;

        return poll;
    }

    pub fn deinit(this: *FilePoll) void {
        const vm = JSC.VirtualMachine.get();
        this.deinitWithVM(vm);
    }

    pub inline fn fileDescriptor(this: *FilePoll) bun.FileDescriptor {
        return this.fd;
    }

    pub const deinitForceUnregister = deinit;
    fn uvEventPoll(handle: *uv.uv_poll_t, status: c_int, events: c_int) callconv(.C) void {
        const data = handle.data orelse return;
        const this: *FilePoll = @ptrCast(@alignCast(data));

        if (this.flags.contains(.one_shot)) {
            _ = uv.uv_poll_stop(handle);
        }

        if (status != 0) {
            this.updateFlags(Flags.fromLibUVEvent(uv.UV_DISCONNECT));
        } else {
            this.updateFlags(Flags.fromLibUVEvent(events));
        }

        this.onUpdate(0);
    }

    pub fn onUpdate(poll: *FilePoll, size_or_offset: i64) void {
        if (poll.flags.contains(.one_shot) and !poll.flags.contains(.needs_rearm)) {
            poll.flags.insert(.needs_rearm);
        }

        var ptr = poll.owner;
        switch (ptr.tag()) {
            @field(Owner.Tag, "FIFO") => {
                log("onUpdate libuv (fd: {d}) FIFO", .{poll.fd});
                ptr.as(FIFO).ready(size_or_offset, poll.flags.contains(.hup));
            },
            @field(Owner.Tag, "Subprocess") => {
                log("onUpdate libuv (fd: {d}) Subprocess", .{poll.fd});
                var loader = ptr.as(JSC.Subprocess);

                loader.onExitNotificationTask();
            },
            @field(Owner.Tag, "FileSink") => {
                log("onUpdate libuv (fd: {d}) FileSink", .{poll.fd});
                var loader = ptr.as(JSC.WebCore.FileSink);
                loader.onPoll(size_or_offset, 0);
            },

            else => {
                log("onUpdate libuv (fd: {d}) disconnected?", .{poll.fd});
            },
        }
    }
    fn updateFlags(poll: *FilePoll, updated: Flags.Set) void {
        var flags = poll.flags;
        flags.remove(.readable);
        flags.remove(.writable);
        flags.remove(.process);
        flags.remove(.machport);
        flags.remove(.eof);
        flags.remove(.hup);

        flags.setUnion(updated);
        poll.flags = flags;
    }
    pub fn register(this: *FilePoll, loop: *Loop, flag: Flags, one_shot: bool) JSC.Maybe(void) {
        std.debug.assert(this.fd != bun.invalid_fd);

        const system_fd = bun.FDImpl.decode(this.fd).system();
        this.handle = std.mem.zeroes(uv.uv_poll_t);
        if (one_shot) {
            this.flags.insert(.one_shot);
        }

        const handle = &(this.handle.?);
        if (uv.uv_poll_init_socket(loop, handle, system_fd).errno()) |err| {
            if (JSC.Maybe(void).errnoSys(err, .epoll_ctl)) |errno| {
                return errno;
            }
        }
        handle.data = this;
        const events: c_int = switch (flag) {
            .process,
            .readable,
            => uv.UV_READABLE | uv.UV_DISCONNECT,
            .writable => uv.UV_WRITABLE | uv.UV_DISCONNECT,
            else => unreachable,
        };
        if (uv.uv_poll_start(handle, events, FilePoll.uvEventPoll).errno()) |err| {
            if (JSC.Maybe(void).errnoSys(err, .epoll_ctl)) |errno| {
                return errno;
            }
        }
        this.flags.insert(.was_ever_registered);
        this.flags.insert(switch (flag) {
            .process, .readable => .poll_readable,
            .writable => .poll_writable,
            else => unreachable,
        });
        this.flags.remove(.needs_rearm);
        return JSC.Maybe(void).success;
    }
    pub fn unregister(this: *FilePoll) bool {
        uv.uv_unref(@ptrFromInt(this.fd));
        if (this.handle != null) {
            return uv.uv_poll_stop(&this.handle.?).errno() == null;
        }
        return true;
    }

    fn deinitPossiblyDefer(this: *FilePoll, vm: *JSC.VirtualMachine, loop: *Loop, polls: *FilePoll.Store) void {
        if (this.isRegistered()) {
            _ = loop;
            _ = this.unregister();
        }

        const was_ever_registered = this.flags.contains(.was_ever_registered);
        this.flags = Flags.Set{};
        this.fd = bun.invalid_fd;
        polls.put(this, vm, was_ever_registered);
    }

    pub fn isReadable(this: *FilePoll) bool {
        const readable = this.flags.contains(.readable);
        this.flags.remove(.readable);
        return readable;
    }

    pub fn isHUP(this: *FilePoll) bool {
        const readable = this.flags.contains(.hup);
        this.flags.remove(.hup);
        return readable;
    }

    pub fn isEOF(this: *FilePoll) bool {
        const readable = this.flags.contains(.eof);
        this.flags.remove(.eof);
        return readable;
    }

    pub fn clearEvent(poll: *FilePoll, flag: Flags) void {
        poll.flags.remove(flag);
    }

    pub fn isWritable(this: *FilePoll) bool {
        const readable = this.flags.contains(.writable);
        this.flags.remove(.writable);
        return readable;
    }

    pub fn deinitWithVM(this: *FilePoll, vm: *JSC.VirtualMachine) void {
        const loop = vm.event_loop_handle.?;
        this.deinitPossiblyDefer(vm, loop, vm.rareData().filePolls(vm));
    }

    pub fn enableKeepingProcessAlive(this: *FilePoll, vm: *JSC.VirtualMachine) void {
        if (!this.flags.contains(.closed))
            return;
        this.flags.remove(.closed);

        vm.event_loop_handle.?.active_handles += @as(u32, @intFromBool(this.flags.contains(.has_incremented_poll_count)));
    }

    pub fn canActivate(this: *const FilePoll) bool {
        return !this.flags.contains(.has_incremented_poll_count);
    }

    /// Only intended to be used from EventLoop.Pollable
    pub fn deactivate(this: *FilePoll, loop: *Loop) void {
        std.debug.assert(this.flags.contains(.has_incremented_poll_count));
        loop.active_handles -= @as(u32, @intFromBool(this.flags.contains(.has_incremented_poll_count)));
        this.flags.remove(.has_incremented_poll_count);
    }

    /// Only intended to be used from EventLoop.Pollable
    pub fn activate(this: *FilePoll, loop: *Loop) void {
        loop.active_handles += @as(u32, @intFromBool(!this.flags.contains(.closed) and !this.flags.contains(.has_incremented_poll_count)));
        this.flags.insert(.has_incremented_poll_count);
    }

    pub inline fn canRef(this: *const FilePoll) bool {
        if (this.flags.contains(.closed))
            return false;

        return !this.flags.contains(.has_incremented_poll_count);
    }

    pub inline fn canUnref(this: *const FilePoll) bool {
        return this.flags.contains(.has_incremented_poll_count);
    }

    pub fn onEnded(this: *FilePoll, vm: *JSC.VirtualMachine) void {
        this.flags.remove(.keeps_event_loop_alive);
        this.flags.insert(.closed);
        this.deactivate(vm.event_loop_handle.?);
    }

    /// Prevent a poll from keeping the process alive.
    pub fn unref(this: *FilePoll, vm: *JSC.VirtualMachine) void {
        if (!this.canUnref())
            return;
        log("unref", .{});
        this.deactivate(vm.event_loop_handle.?);
    }

    /// Allow a poll to keep the process alive.
    pub fn ref(this: *FilePoll, vm: *JSC.VirtualMachine) void {
        if (this.canRef())
            return;
        log("ref", .{});
        this.activate(vm.event_loop_handle.?);
    }

    const HiveArray = bun.HiveArray(FilePoll, 128).Fallback;

    pub const Store = struct {
        hive: HiveArray,
        pending_free_head: ?*FilePoll = null,
        pending_free_tail: ?*FilePoll = null,

        const log = Output.scoped(.FilePoll, false);

        pub fn init(allocator: std.mem.Allocator) Store {
            return .{
                .hive = HiveArray.init(allocator),
            };
        }

        pub fn get(this: *Store) *FilePoll {
            return this.hive.get();
        }

        pub fn processDeferredFrees(this: *Store) void {
            var next = this.pending_free_head;
            while (next) |current| {
                next = current.next_to_free;
                current.next_to_free = null;
                this.hive.put(current);
            }
            this.pending_free_head = null;
            this.pending_free_tail = null;
        }

        pub fn put(this: *Store, poll: *FilePoll, vm: *JSC.VirtualMachine, ever_registered: bool) void {
            if (!ever_registered) {
                this.hive.put(poll);
                return;
            }

            std.debug.assert(poll.next_to_free == null);

            if (this.pending_free_tail) |tail| {
                std.debug.assert(this.pending_free_head != null);
                std.debug.assert(tail.next_to_free == null);
                tail.next_to_free = poll;
            }

            if (this.pending_free_head == null) {
                this.pending_free_head = poll;
                std.debug.assert(this.pending_free_tail == null);
            }

            poll.flags.insert(.ignore_updates);
            this.pending_free_tail = poll;
            std.debug.assert(vm.after_event_loop_callback == null or vm.after_event_loop_callback == @as(?JSC.OpaqueCallback, @ptrCast(&processDeferredFrees)));
            vm.after_event_loop_callback = @ptrCast(&processDeferredFrees);
            vm.after_event_loop_callback_ctx = this;
        }
    };
};

pub const Waker = struct {
    loop: *bun.uws.UVLoop,

    pub fn init(_: std.mem.Allocator) !Waker {
        return .{ .loop = bun.uws.UVLoop.init() };
    }

    pub fn getFd(this: *const Waker) bun.FileDescriptor {
        _ = this;

        @compileError("Waker.getFd is unsupported on Windows");
    }

    pub fn initWithFileDescriptor(_: std.mem.Allocator, _: bun.FileDescriptor) Waker {
        @compileError("Waker.initWithFileDescriptor is unsupported on Windows");
    }

    pub fn wait(this: Waker) void {
        this.loop.wait();
    }

    pub fn wake(this: *const Waker) void {
        this.loop.wakeup();
    }
};
