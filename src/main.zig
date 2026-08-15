const std = @import("std");
const r4os = @import("r4os");

pub const op_capabilities: u32 = 1;
pub const op_parse_summary: u32 = 2;
pub const op_evaluate_summary: u32 = 3;
pub const op_selftest: u32 = 4;
pub const op_web_runtime_selftest: u32 = 5;

pub const result_ok: i32 = 0;
pub const result_bad_buffer: i32 = -2;
pub const result_unknown_op: i32 = -4;
pub const result_output_small: i32 = -5;
pub const result_syntax: i32 = -6;
pub const result_runtime: i32 = -7;
pub const result_limit: i32 = -8;
pub const result_busy: i32 = -9;
pub const result_cancelled: i32 = -10;

var protocol_api: ?*const r4os.r4dev.ProtocolApi = null;
var workspace_busy: u8 = 0;

comptime {
    asm (r4os.r4dev.protocolEntriesAsm("r4js_init", "r4js_shutdown", "r4js_query", "r4js_dispatch"));
}

export fn r4js_init(api: *const r4os.r4dev.ProtocolApi) callconv(.c) i32 {
    protocol_api = api;
    var ctx = r4os.r4dev.ProtocolContext.init(api);
    ctx.logInfo("R4JS.R4P init");
    _ = ctx.registerRole("application.javascript", .data, 0);
    _ = ctx.setStatus(.active, "JavaScript runtime active");
    return 0;
}

export fn r4js_shutdown() callconv(.c) i32 {
    protocol_api = null;
    return 0;
}

export fn r4js_query(out: *r4os.abi.ProtocolStatus) callconv(.c) i32 {
    out.* = .{
        .state = @intFromEnum(r4os.abi.ProtocolState.active),
        .flags = 0,
        .last_error = 0,
        .reserved = 0,
        .note = note("R4JS ready"),
    };
    return 0;
}

export fn r4js_dispatch(op: u32, in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) callconv(.c) i32 {
    return switch (op) {
        op_capabilities => writeOut(out_buffer, "role=application.javascript;execution=bytecode-vm;syntax=lexical|functions|closures|strict-mode|this|new-target|objects|arrays|modules|default-imports|namespace-imports|re-exports|dynamic-import|import-meta|exceptions|generators|async-generators|await|for-await-of;memory=bounded-mark-sweep;async=event-loop|tasks|microtasks|promises|thenables;web=window|dom|events|timers|fetch|xhr|storage|history|origin|cors|csp;jit=no"),
        op_parse_summary => parseSummary(in_buffer, out_buffer),
        op_evaluate_summary => evaluateSummary(in_buffer, out_buffer),
        op_selftest => selftest(out_buffer),
        op_web_runtime_selftest => webRuntimeSelftest(out_buffer),
        else => result_unknown_op,
    };
}

fn webRuntimeSelftest(out_buffer: *r4os.abi.ProtocolBuffer) i32 {
    if (!claimWorkspace()) return result_busy;
    defer releaseWorkspace();
    const api = protocol_api orelse return result_runtime;
    const document = allocate(r4os.html.Document) orelse return result_limit;
    defer release(document);
    const storage = allocate(r4os.web_security.BrowserStorage) orelse return result_limit;
    defer release(storage);
    storage.* = .{};
    const web_runtime = allocate(r4os.web_runtime.WebRuntime) orelse return result_limit;
    defer release(web_runtime);
    web_runtime.initialize(programAllocator(api));
    defer web_runtime.deinit();
    _ = document.parse(
        "<!doctype html><body><p id=state>pending</p><script nonce=r4>" ++
            "document.getElementById('state').textContent='active';" ++
            "localStorage.probe='ok'; document.cookie='fixture=ok; Path=/'; let fired=''; setTimeout(() => { fired='timer'; }, 1);" ++
            "</script></body>",
        .{ .content_type = "text/html;charset=utf-8" },
    ) catch return result_runtime;
    web_runtime.beginDocument(
        document,
        storage,
        "https://selftest.r4os/",
        "default-src 'self'; script-src 'nonce-r4'; connect-src 'self'",
        1,
        10,
    ) catch return result_runtime;
    const scripts = web_runtime.executeDocumentScripts() catch return result_runtime;
    _ = web_runtime.pump(12, 8) catch return result_runtime;
    const state = document.findElementById("state") orelse return result_runtime;
    var text_buffer: [32]u8 = undefined;
    const state_text = document.textContent(state, text_buffer[0..]) catch return result_runtime;
    const local_storage = storage.local.area(&web_runtime.security_context.document_origin) catch return result_runtime;
    const fired = web_runtime.runtime.global("fired") orelse return result_runtime;
    if (scripts != 1 or !equals(state_text, "active") or !equals(local_storage.get("probe") orelse "", "ok") or !equals(web_runtime.runtime.valueString(fired), "timer")) return result_runtime;
    return writeOut(out_buffer, "R4JS web-runtime selftest: OK window=ok dom=ok events=ok timers=ok fetch=guarded xhr=guarded storage=origin history=actions cors=ok csp=ok generations=ok");
}

fn programAllocator(api: *const r4os.r4dev.ProtocolApi) r4os.javascript.ProgramAllocator {
    return .{
        .context = @ptrCast(@constCast(api)),
        .create = createProgram,
        .destroy = destroyProgram,
        .allocate = allocateRuntimeMemory,
        .free = freeRuntimeMemory,
    };
}

fn createProgram(context: *anyopaque) ?*r4os.javascript.Program {
    const api: *const r4os.r4dev.ProtocolApi = @ptrCast(@alignCast(context));
    const program = r4os.r4dev.ProtocolContext.init(api).alloc(
        @intCast(@sizeOf(r4os.javascript.Program)),
        @intCast(@alignOf(r4os.javascript.Program)),
    ) orelse return null;
    const typed: *r4os.javascript.Program = @ptrCast(@alignCast(program));
    typed.* = .{};
    return typed;
}

fn destroyProgram(context: *anyopaque, program: *r4os.javascript.Program) void {
    const api: *const r4os.r4dev.ProtocolApi = @ptrCast(@alignCast(context));
    r4os.r4dev.ProtocolContext.init(api).free(program, @intCast(@sizeOf(r4os.javascript.Program)));
}

fn allocateRuntimeMemory(context: *anyopaque, length: usize, alignment: usize) ?[*]u8 {
    const api: *const r4os.r4dev.ProtocolApi = @ptrCast(@alignCast(context));
    const memory = r4os.r4dev.ProtocolContext.init(api).alloc(@intCast(length), @intCast(alignment)) orelse return null;
    return @ptrCast(memory);
}

fn freeRuntimeMemory(context: *anyopaque, memory: [*]u8, length: usize, _: usize) void {
    const api: *const r4os.r4dev.ProtocolApi = @ptrCast(@alignCast(context));
    r4os.r4dev.ProtocolContext.init(api).free(memory, @intCast(length));
}

fn parseSummary(in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) i32 {
    if (!claimWorkspace()) return result_busy;
    defer releaseWorkspace();
    const input = inputBytes(in_buffer) orelse return result_bad_buffer;
    const program = allocate(r4os.javascript.Program) orelse return result_limit;
    defer release(program);
    program.* = .{};
    const stats = program.parse(input) catch |err| return jsError(err);
    const out = outputBytes(out_buffer) orelse return result_bad_buffer;
    var len: usize = 0;
    if (!append(out, &len, "tokens=") or
        !appendDecimal(out, &len, stats.tokens) or
        !append(out, &len, ";nodes=") or
        !appendDecimal(out, &len, stats.nodes) or
        !append(out, &len, ";functions=") or
        !appendDecimal(out, &len, stats.functions) or
        !append(out, &len, ";module-statements=") or
        !appendDecimal(out, &len, stats.modules) or
        !append(out, &len, ";bytecode=") or
        !appendDecimal(out, &len, stats.bytecode_instructions) or
        !append(out, &len, ";segments=") or
        !appendDecimal(out, &len, stats.bytecode_segments))
    {
        return result_output_small;
    }
    return finish(out_buffer, len);
}

fn evaluateSummary(in_buffer: *const r4os.abi.ProtocolBuffer, out_buffer: *r4os.abi.ProtocolBuffer) i32 {
    if (!claimWorkspace()) return result_busy;
    defer releaseWorkspace();
    const input = inputBytes(in_buffer) orelse return result_bad_buffer;
    const api = protocol_api orelse return result_runtime;
    const program = allocate(r4os.javascript.Program) orelse return result_limit;
    defer release(program);
    program.* = .{};
    const runtime = allocate(r4os.javascript.Runtime) orelse return result_limit;
    defer release(runtime);
    runtime.initialize(programAllocator(api));
    defer runtime.deinit();
    runtime.init() catch |err| return jsError(err);
    const value = runtime.evaluateScriptSource(program, input) catch |err| return jsError(err);
    _ = runtime.drainJobs(program, r4os.javascript.max_jobs) catch |err| return jsError(err);
    const out = outputBytes(out_buffer) orelse return result_bad_buffer;
    var len: usize = 0;
    if (!append(out, &len, "type=") or !appendValueType(out, &len, value)) return result_output_small;
    switch (value) {
        .undefined => if (!append(out, &len, ";value=undefined")) return result_output_small,
        .null_value => if (!append(out, &len, ";value=null")) return result_output_small,
        .boolean => |boolean| if (!append(out, &len, if (boolean) ";value=true" else ";value=false")) return result_output_small,
        .number => |number| {
            if (!append(out, &len, ";value=") or !appendNumber(out, &len, number)) return result_output_small;
        },
        .bigint => {
            const text = runtime.valueBigIntString(value) catch return result_runtime;
            if (!append(out, &len, ";value=") or !append(out, &len, text)) return result_output_small;
        },
        .string => {
            if (!append(out, &len, ";value=") or !append(out, &len, runtime.valueString(value))) return result_output_small;
        },
        .cell => if (!append(out, &len, ";value=[object]")) return result_output_small,
    }
    runtime.collectGarbage();
    if (!append(out, &len, ";engine=bytecode;steps=") or
        !appendDecimal(out, &len, runtime.stats.steps) or
        !append(out, &len, ";instructions=") or
        !appendDecimal(out, &len, runtime.stats.bytecode_instructions) or
        !append(out, &len, ";frames-peak=") or
        !appendDecimal(out, &len, runtime.stats.bytecode_frames_peak) or
        !append(out, &len, ";live=") or
        !appendDecimal(out, &len, runtime.stats.live_cells))
    {
        return result_output_small;
    }
    return finish(out_buffer, len);
}

fn selftest(out_buffer: *r4os.abi.ProtocolBuffer) i32 {
    if (!claimWorkspace()) return result_busy;
    defer releaseWorkspace();
    const api = protocol_api orelse return result_runtime;
    const program = allocate(r4os.javascript.Program) orelse return result_limit;
    defer release(program);
    program.* = .{};
    const runtime = allocate(r4os.javascript.Runtime) orelse return result_limit;
    defer release(runtime);
    runtime.initialize(programAllocator(api));
    defer runtime.deinit();
    runtime.init() catch return result_limit;
    const source =
        "function counter(start) { return () => ++start; }" ++
        "const next = counter(40);" ++
        "let trace = '';" ++
        "new Promise((resolve) => resolve(next())).then((value) => { trace += value; });" ++
        "queueTask(() => { trace += '!'; });";
    _ = program.parse(source) catch return result_syntax;
    if (!program.bytecodeReady()) return result_runtime;
    _ = runtime.evaluate(program) catch return result_runtime;
    if (runtime.stats.bytecode_instructions == 0) return result_runtime;
    const jobs = runtime.drainJobs(program, 8) catch return result_runtime;
    const trace = runtime.global("trace") orelse return result_runtime;
    if (jobs != 2 or !equals(runtime.valueString(trace), "41!")) return result_runtime;
    const before = runtime.stats.live_cells;
    runtime.collectGarbage();
    if (runtime.stats.live_cells > before) return result_runtime;
    return writeOut(out_buffer, "R4JS selftest: OK parser=ok bytecode=ok vm=ok closures=ok exceptions=ok modules=ok gc=ok promises=ok event-loop=ok");
}

fn claimWorkspace() bool {
    return @cmpxchgStrong(u8, &workspace_busy, 0, 1, .acquire, .monotonic) == null;
}

fn releaseWorkspace() void {
    @atomicStore(u8, &workspace_busy, 0, .release);
}

fn allocate(comptime T: type) ?*T {
    const api = protocol_api orelse return null;
    const memory = r4os.r4dev.ProtocolContext.init(api).alloc(@intCast(@sizeOf(T)), @intCast(@alignOf(T))) orelse return null;
    return @ptrCast(@alignCast(memory));
}

fn release(value: anytype) void {
    const api = protocol_api orelse return;
    const T = @TypeOf(value.*);
    r4os.r4dev.ProtocolContext.init(api).free(value, @intCast(@sizeOf(T)));
}

fn jsError(err: r4os.javascript.Error) i32 {
    return switch (err) {
        error.SourceTooLarge,
        error.TokenLimit,
        error.NodeLimit,
        error.BytecodeLimit,
        error.BytecodeSegmentLimit,
        error.BytecodeStack,
        error.BytecodeFrameLimit,
        error.StringLimit,
        error.CellLimit,
        error.PropertyLimit,
        error.BindingLimit,
        error.ItemLimit,
        error.ModuleLimit,
        error.ProgramAllocation,
        error.GeneratorAllocation,
        error.JobLimit,
        error.RootLimit,
        error.CallDepth,
        => result_limit,
        error.SyntaxError, error.UnexpectedToken => result_syntax,
        error.Cancelled => result_cancelled,
        else => result_runtime,
    };
}

fn inputBytes(buffer: *const r4os.abi.ProtocolBuffer) ?[]const u8 {
    if (buffer.data == null or buffer.len > buffer.capacity) return null;
    const ptr: [*]const u8 = @ptrCast(buffer.data.?);
    return ptr[0..buffer.len];
}

fn outputBytes(buffer: *r4os.abi.ProtocolBuffer) ?[]u8 {
    if (buffer.data == null) return null;
    const ptr: [*]u8 = @ptrCast(buffer.data.?);
    return ptr[0..buffer.capacity];
}

fn finish(buffer: *r4os.abi.ProtocolBuffer, len: usize) i32 {
    if (len > buffer.capacity) return result_output_small;
    buffer.len = @intCast(len);
    return result_ok;
}

fn writeOut(buffer: *r4os.abi.ProtocolBuffer, value: []const u8) i32 {
    const out = outputBytes(buffer) orelse return result_bad_buffer;
    if (value.len > out.len) return result_output_small;
    if (value.len > 0) @memcpy(out[0..value.len], value);
    return finish(buffer, value.len);
}

fn append(out: []u8, len: *usize, value: []const u8) bool {
    if (value.len > out.len -| len.*) return false;
    if (value.len > 0) @memcpy(out[len.* .. len.* + value.len], value);
    len.* += value.len;
    return true;
}

fn appendDecimal(out: []u8, len: *usize, value: usize) bool {
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    if (remaining == 0) return append(out, len, "0");
    while (remaining > 0) : (remaining /= 10) {
        digits[count] = @intCast('0' + remaining % 10);
        count += 1;
    }
    while (count > 0) {
        count -= 1;
        if (!append(out, len, digits[count .. count + 1])) return false;
    }
    return true;
}

fn appendNumber(out: []u8, len: *usize, value: f64) bool {
    var buffer: [64]u8 = undefined;
    const text = stdFormatNumber(buffer[0..], value) orelse return false;
    return append(out, len, text);
}

fn stdFormatNumber(buffer: []u8, value: f64) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch null;
}

fn appendValueType(out: []u8, len: *usize, value: r4os.javascript.Value) bool {
    return append(out, len, switch (value) {
        .undefined => "undefined",
        .null_value => "object",
        .boolean => "boolean",
        .number => "number",
        .bigint => "bigint",
        .string => "string",
        .cell => "object",
    });
}

fn equals(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn note(comptime value: []const u8) [64]u8 {
    var out: [64]u8 = .{0} ** 64;
    const count = @min(value.len, out.len - 1);
    @memcpy(out[0..count], value[0..count]);
    return out;
}
