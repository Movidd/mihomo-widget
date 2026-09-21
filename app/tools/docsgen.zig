// docsgen.zig — the whole docs pipeline for docs/API-REFERENCE.md, in Zig.
//
//   zig build docs-gen           rewrite the generated cells (add `-- -n` for a dry run)
//   zig build docs-check         verify the doc against app/src; non-zero exit on drift
//
// Why Zig and not the old PowerShell scripts: facts must come from a real parse
// (std.zig.Ast ships with the pinned toolchain), and once the facts are AST-derived the
// only work left is markdown surgery - splitting table rows, refreshing cells, appending
// rows. Doing that next to the parser removes a JSON hop, a second language, and the
// "keep these two regexes in sync" hazard that came with it.
//
// What this tool owns (regenerated, never hand-edit):
//   section 1  `| symbol | loc | description |` per `### <module>.zig`:
//              - "loc" recomputed (~line, joined with / for multi-symbol rows)
//              - public fn / struct|enum|union const that the doc never mentions => a new
//                row with an EMPTY description (check fails until a human writes one line)
//              - symbols deleted from source are NOT removed: that would drop their prose,
//                and the check is the thing that should shout about them
//   section 2  endpoint rows are verified against mihomo.zig (method + path literal)
//   section 3  conf key table: type/default recomputed from the Config field facts; keys
//              the source parses but the doc never lists are appended
//   the generated cells themselves: `check` re-runs that same comparison report-only, so a
//   hand-edited loc / type / default cell fails the gate instead of silently rotting until
//   somebody happens to run `gen`.
// Everything else (说明/用途 prose, the main.zig anchor table, §4, §5) is hand-written and
// only ever read, never rewritten. Output is byte-identical when there is nothing to say -
// `docs-gen` on a fresh tree prints "updated 0, appended 0, skipped 0" and does not write.
const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: docsgen gen   <src-dir> <doc.md> [-n]   rewrite the generated cells
    \\       docsgen check <src-dir> <doc.md>        verify the doc against the sources
    \\
;

// Words that are never a row's symbol: parameter names, Zig keywords/type names, short
// names used as plain prose (file names, registry value names spelled in a sentence).
// One list for both modes: the generator only uses it to pick a line to report, the
// checker to skip a word it should not judge.
const STOP = [_][]const u8{
    "pub",          "fn",            "struct",   "enum",     "union",       "const",
    "var",          "bool",          "void",     "self",     "comptime",    "callconv",
    "u8",           "u16",           "u32",      "u64",      "i8",          "i16",
    "i32",          "i64",           "f32",      "f64",      "usize",       "isize",
    "anyopaque",    "want",          "text",     "buf",      "data",        "path",
    "out",          "src",           "dst",      "hwnd",     "reason",      "cover",
    "args",         "arena",         "exe_dir",  "heap",     "max",         "sec",
    "res",          "n",             "s",        "w",        "h",           "x",
    "y",            "c",             "g",        "p",        "k",           "v",
    "up",           "dn",            "i",        "j",        "ev",          "g0",
    "g1",           "enable",        "has_device", "kind",   "result",      "exit_after",
    "nodes",
    "nodes_n",      "sel",           "first",    "kb",       "mb",          "gb",
    "auto",         "bytes_per_s",   "timeout",  "url",      "name",        "port",
    "host",         "secret",        "group",    "node",     "ifindex",     "cands",
    "levels",       "p0",            "bytes",    "body",     "method",      "object",
    "extra_header", "timeout_ms",    "mixed_port", "self_abs", "on",        "defer",
    "switch",       "spawned",       "direct",   "x8001",    "GENERIC_READ",
    "FILE_SHARE_READ_WRITE",         "OPEN_EXISTING",       "CREATE_ALWAYS",
    "FILE_ATTRIBUTE_NORMAL",         "INVALID_HANDLE",
};

fn isStop(word: []const u8) bool {
    for (STOP) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- facts (app/src)

const Decl = struct {
    name: []const u8,
    /// "fn" | "const" | "var": the mut_token text of the declaration
    kind: []const u8,
    /// "struct" | "enum" | "union" when the initializer starts with that keyword, else ""
    container: []const u8,
    is_pub: bool,
    /// "" for non-fn declarations; "name" or "name(a, b)" for functions
    sig: []const u8,
    /// 1-based line of the declaration
    line: usize,
};

/// The §1 row criterion, shared by the generator (which appends the missing rows) and the
/// checker (which reports them): public fns, and public struct|enum|union consts. One
/// predicate is what keeps the two from disagreeing about what "documented" means.
fn isGapSymbol(d: Decl) bool {
    return d.is_pub and (std.mem.eql(u8, d.kind, "fn") or
        (std.mem.eql(u8, d.kind, "const") and d.container.len != 0));
}

const ConfKey = struct { key: []const u8, field: []const u8 };
const ConfField = struct { name: []const u8, type_text: []const u8, default_text: []const u8 };

const ModuleFacts = struct {
    file: []const u8,
    decls: []const Decl,
    /// every identifier token plus every word inside a string literal (sorted, unique).
    /// Comments are excluded on purpose: "this name exists" must mean real code.
    names: []const []const u8,
    /// string literals exactly as written, for the §2 path check
    string_literals: []const []const u8,
};

const Facts = struct {
    modules: []const ModuleFacts,
    conf_keys: []const ConfKey,
    conf_fields: []const ConfField,

    fn module(self: Facts, file: []const u8) ?ModuleFacts {
        for (self.modules) |m| {
            if (std.mem.eql(u8, m.file, file)) return m;
        }
        return null;
    }

    /// Line to report for a symbol, 0 when unknown. Ranked like the text scan this
    /// replaced: pub fn > pub const > fn > const > var.
    fn declLine(self: Facts, file: []const u8, name: []const u8) usize {
        const m = self.module(file) orelse return 0;
        var best_rank: usize = 9;
        var best_line: usize = 0;
        for (m.decls) |d| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            const rank: usize = if (std.mem.eql(u8, d.kind, "fn"))
                (if (d.is_pub) @as(usize, 1) else 3)
            else if (std.mem.eql(u8, d.kind, "const"))
                (if (d.is_pub) @as(usize, 2) else 4)
            else
                5;
            if (rank < best_rank) {
                best_rank = rank;
                best_line = d.line;
            }
        }
        return best_line;
    }

    fn hasName(self: Facts, file: []const u8, name: []const u8) bool {
        const m = self.module(file) orelse return false;
        for (m.names) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    fn hasNameAnywhere(self: Facts, name: []const u8) bool {
        for (self.modules) |m| {
            for (m.names) |n| {
                if (std.mem.eql(u8, n, name)) return true;
            }
        }
        return false;
    }

    fn fieldOfKey(self: Facts, key: []const u8) ?[]const u8 {
        for (self.conf_keys) |k| {
            if (std.mem.eql(u8, k.key, key)) return k.field;
        }
        return null;
    }

    fn confField(self: Facts, name: []const u8) ?ConfField {
        for (self.conf_fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

fn collectFacts(arena: Allocator, io: std.Io, src_dir: []const u8) !Facts {
    var dir = try std.Io.Dir.openDirAbsolute(io, src_dir, .{ .iterate = true });
    defer dir.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        try files.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, files.items, {}, strLess);

    var modules: std.ArrayList(ModuleFacts) = .empty;
    var conf_keys: std.ArrayList(ConfKey) = .empty;
    var conf_fields: std.ArrayList(ConfField) = .empty;
    for (files.items) |file| {
        const src = try dir.readFileAllocOptions(io, file, arena, .limited(8 << 20), .of(u8), 0);
        const ast = try Ast.parse(arena, src, .zig);
        if (ast.errors.len != 0) {
            std.debug.print("docsgen: {s} does not parse ({d} parse error(s))\n", .{ file, ast.errors.len });
            return error.ParseFailed;
        }
        var decls: std.ArrayList(Decl) = .empty;
        try collectDecls(arena, ast, ast.rootDecls(), &decls, &conf_fields);
        var names: std.ArrayList([]const u8) = .empty;
        var literals: std.ArrayList([]const u8) = .empty;
        try collectTokens(arena, ast, &names, &literals);
        if (std.mem.eql(u8, file, "main.zig")) try collectConf(arena, ast, &conf_keys);
        try modules.append(arena, .{
            .file = file,
            .decls = try decls.toOwnedSlice(arena),
            .names = try sortDedup(arena, names.items),
            .string_literals = try sortDedup(arena, literals.items),
        });
    }
    return .{
        .modules = try modules.toOwnedSlice(arena),
        .conf_keys = try conf_keys.toOwnedSlice(arena),
        .conf_fields = try conf_fields.toOwnedSlice(arena),
    };
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Sorted, de-duplicated copy of `items`.
fn sortDedup(arena: Allocator, items: [][]const u8) ![]const []const u8 {
    std.mem.sort([]const u8, items, {}, strLess);
    var n: usize = 0;
    for (items) |s| {
        if (n != 0 and std.mem.eql(u8, items[n - 1], s)) continue;
        items[n] = s;
        n += 1;
    }
    return arena.dupe([]const u8, items[0..n]);
}

fn containerKeyword(ast: Ast, init_node: Ast.Node.Index) []const u8 {
    return switch (ast.tokenTag(ast.firstToken(init_node))) {
        .keyword_struct => "struct",
        .keyword_enum => "enum",
        .keyword_union => "union",
        else => "",
    };
}

/// "name" when the function takes no parameters, else "name(a, b)" - the shape the doc
/// table already uses for hand-written rows.
fn sigOf(arena: Allocator, ast: Ast, proto: Ast.full.FnProto) ![]const u8 {
    const name = ast.tokenSlice(proto.name_token.?);
    var params: std.ArrayList(u8) = .empty;
    var it = Ast.full.FnProto.iterate(&proto, &ast);
    while (it.next()) |p| {
        if (params.items.len != 0) try params.appendSlice(arena, ", ");
        if (p.name_token) |name_tok| {
            if (p.comptime_noalias) |kw| {
                try params.appendSlice(arena, ast.tokenSlice(kw));
                try params.append(arena, ' ');
            }
            try params.appendSlice(arena, ast.tokenSlice(name_tok));
        } else {
            try params.appendSlice(arena, "...");
        }
    }
    if (params.items.len == 0) return name;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, name);
    try buf.append(arena, '(');
    try buf.appendSlice(arena, params.items);
    try buf.append(arena, ')');
    return buf.items;
}

/// Declarations of a container (the file root, or a struct/enum/union body), recursing
/// into nested containers and collecting their fields on the way.
fn collectDecls(
    arena: Allocator,
    ast: Ast,
    members: []const Ast.Node.Index,
    decls: *std.ArrayList(Decl),
    fields: *std.ArrayList(ConfField),
) !void {
    for (members) |node| switch (ast.nodeTag(node)) {
        .fn_decl => {
            var buf: [1]Ast.Node.Index = undefined;
            const proto = ast.fullFnProto(&buf, node) orelse continue;
            const name_tok = proto.name_token orelse continue;
            try decls.append(arena, .{
                .name = ast.tokenSlice(name_tok),
                .kind = "fn",
                .container = "",
                .is_pub = proto.visib_token != null,
                .sig = try sigOf(arena, ast, proto),
                .line = ast.tokenLocation(0, proto.firstToken()).line + 1,
            });
        },
        .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {
            const vd = ast.fullVarDecl(node) orelse continue;
            var container: []const u8 = "";
            if (vd.ast.init_node.unwrap()) |init| {
                container = containerKeyword(ast, init);
                var buf: [2]Ast.Node.Index = undefined;
                if (ast.fullContainerDecl(&buf, init)) |cd| {
                    try collectFields(arena, ast, cd.ast.members, fields);
                    try collectDecls(arena, ast, cd.ast.members, decls, fields);
                }
            }
            try decls.append(arena, .{
                .name = ast.tokenSlice(vd.ast.mut_token + 1),
                .kind = ast.tokenSlice(vd.ast.mut_token),
                .container = container,
                .is_pub = vd.visib_token != null,
                .sig = "",
                .line = ast.tokenLocation(0, vd.firstToken()).line + 1,
            });
        },
        else => {},
    };
}

fn collectFields(
    arena: Allocator,
    ast: Ast,
    members: []const Ast.Node.Index,
    fields: *std.ArrayList(ConfField),
) !void {
    for (members) |node| {
        const cf = ast.fullContainerField(node) orelse continue;
        // the conf table documents `name: Type = default,` shapes only
        const type_node = cf.ast.type_expr.unwrap() orelse continue;
        const val_node = cf.ast.value_expr.unwrap() orelse continue;
        try fields.append(arena, .{
            .name = ast.tokenSlice(cf.ast.main_token),
            .type_text = ast.getNodeSource(type_node),
            .default_text = ast.getNodeSource(val_node),
        });
    }
}

fn collectTokens(
    arena: Allocator,
    ast: Ast,
    names: *std.ArrayList([]const u8),
    literals: *std.ArrayList([]const u8),
) !void {
    const tags = ast.tokens.items(.tag);
    for (tags, 0..) |tag, i| switch (tag) {
        .identifier => try names.append(arena, ast.tokenSlice(@intCast(i))),
        // `@intCast` is a real API name: keep it, without the sigil
        .builtin => {
            const s = ast.tokenSlice(@intCast(i));
            if (s.len > 1) try names.append(arena, s[1..]);
        },
        // A string literal is real code (conf keys, registry value names, file names the
        // doc is allowed to cite), so its words count as names too - while the raw
        // literal is kept for the §2 path check.
        .string_literal => {
            const s = ast.tokenSlice(@intCast(i));
            try literals.append(arena, s);
            try names.appendSlice(arena, try identRuns(arena, s, 1));
        },
        else => {},
    };
}

/// conf key -> Config field, read off the `std.mem.eql(u8, key, "..")` branches: the
/// then-branch's first `self.<field>` is the target (a `self.setFace(val)` call means
/// font_face, which lands in the `face_w` buffer).
fn collectConf(arena: Allocator, ast: Ast, keys: *std.ArrayList(ConfKey)) !void {
    for (0..ast.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        const branch = ast.fullIf(node) orelse continue;
        var cbuf: [1]Ast.Node.Index = undefined;
        const call = ast.fullCall(&cbuf, branch.ast.cond_expr) orelse continue;
        if (call.ast.params.len != 3) continue;
        if (ast.nodeTag(call.ast.fn_expr) != .field_access) continue;
        const field_tok = ast.nodeData(call.ast.fn_expr).node_and_token[1];
        if (!std.mem.eql(u8, ast.tokenSlice(field_tok), "eql")) continue;
        const key_arg = call.ast.params[1];
        if (ast.nodeTag(key_arg) != .identifier) continue;
        if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(key_arg)), "key")) continue;
        const lit = call.ast.params[2];
        if (ast.nodeTag(lit) != .string_literal) continue;
        const raw = ast.tokenSlice(ast.nodeMainToken(lit));
        if (raw.len < 2) continue;
        const field = selfFieldIn(ast, branch.ast.then_expr) orelse continue;
        const key = raw[1 .. raw.len - 1];
        var seen = false;
        for (keys.items) |k| {
            if (std.mem.eql(u8, k.key, key)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        try keys.append(arena, .{
            .key = key,
            .field = if (std.mem.eql(u8, field, "setFace")) "face_w" else field,
        });
    }
}

/// First `self.<field>` inside `node`, by source order.
fn selfFieldIn(ast: Ast, node: Ast.Node.Index) ?[]const u8 {
    const lo = ast.firstToken(node);
    const hi = ast.lastToken(node);
    var best_tok: Ast.TokenIndex = 0;
    var best: ?[]const u8 = null;
    for (0..ast.nodes.len) |i| {
        const cur: Ast.Node.Index = @enumFromInt(i);
        if (ast.nodeTag(cur) != .field_access) continue;
        const tok = ast.firstToken(cur);
        if (tok < lo or ast.lastToken(cur) > hi) continue;
        const d = ast.nodeData(cur).node_and_token;
        if (ast.nodeTag(d[0]) != .identifier) continue;
        if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(d[0])), "self")) continue;
        if (best == null or tok < best_tok) {
            best_tok = tok;
            best = ast.tokenSlice(d[1]);
        }
    }
    return best;
}

// ---------------------------------------------------------------- markdown

const Doc = struct {
    arena: Allocator,
    lines: std.ArrayList([]const u8),
    /// the file as loaded, for "does the doc mention X anywhere" tests: rows appended by
    /// this run must not make a sibling symbol look documented
    original: []const u8,

    fn load(arena: Allocator, io: std.Io, path: []const u8) !Doc {
        const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0);
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, source, '\n');
        while (it.next()) |l| try lines.append(arena, l);
        return .{ .arena = arena, .lines = lines, .original = source };
    }

    fn text(self: *const Doc) []const u8 {
        return self.original;
    }

    /// 0-based index of the first line that starts with `header` (a section marker).
    fn lineStartingWith(self: *const Doc, header: []const u8) ?usize {
        for (self.lines.items, 0..) |l, i| {
            if (std.mem.startsWith(u8, lineBody(l), header)) return i;
        }
        return null;
    }

    /// Join the lines back with '\n'. Rows are stored without their terminator and keep a
    /// trailing '\r' verbatim, so a CRLF working copy round-trips unchanged.
    fn render(self: *const Doc, out: *std.ArrayList(u8)) !void {
        for (self.lines.items, 0..) |l, i| {
            if (i != 0) try out.append(self.arena, '\n');
            try out.appendSlice(self.arena, l);
        }
    }

    fn insertRow(self: *Doc, at: usize, row: []const u8) void {
        self.lines.insert(self.arena, at, row) catch @panic("OOM");
    }

    fn setRow(self: *Doc, at: usize, row: []const u8) void {
        self.lines.items[at] = row;
    }
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

/// Line content without its terminator. Only '\r' is stripped: the doc's own rows are
/// written back verbatim, but structure (headings, separators, table shape) is recognized
/// regardless of how the line happens to end.
fn lineBody(line: []const u8) []const u8 {
    return std.mem.trimEnd(u8, line, "\r");
}

/// A `| a | b |` line split on every '|' (the leading/trailing empties included). Cells
/// keep their padding: rewriting a cell must not reflow the columns around it, and an
/// escaped `\|` splits like a raw one - same as the scan this replaced.
fn splitCells(arena: Allocator, line: []const u8) ![][]const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, line, '|');
    while (it.next()) |c| try cells.append(arena, c);
    return cells.toOwnedSlice(arena);
}

/// `| \`symbol\` | ...`: a row whose first cell starts with a code span - the shape both
/// the symbol table and the conf table use (the hand-written anchor table does not).
fn rowStartsWithBacktickedCell(line: []const u8) bool {
    var i: usize = 0;
    if (i >= line.len or line[i] != '|') return false;
    i += 1;
    while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
    return i < line.len and line[i] == '`';
}

/// `:--- |` or `|---|`: a table's separator row.
fn isTableSeparator(line: []const u8) bool {
    var i: usize = 0;
    if (i >= line.len or line[i] != '|') return false;
    i += 1;
    while (i < line.len and std.ascii.isWhitespace(line[i])) i += 1;
    if (i < line.len and line[i] == ':') i += 1;
    var dashes: usize = 0;
    while (i < line.len and line[i] == '-') : (i += 1) dashes += 1;
    return dashes >= 3;
}

/// The first table whose first data row starts with a backticked cell, i.e. the symbol /
/// conf tables rather than the hand-written anchor table. Returns row indices.
fn findTable(arena: Allocator, doc: *const Doc, from: usize, to: usize) !?[]const usize {
    var i = from;
    while (i + 1 < to) : (i += 1) {
        if (!isTableSeparator(doc.lines.items[i])) continue;
        var rows: std.ArrayList(usize) = .empty;
        var j = i + 1;
        while (j < to and std.mem.startsWith(u8, doc.lines.items[j], "|")) : (j += 1) {
            try rows.append(arena, j);
        }
        if (rows.items.len == 0) continue;
        const cells = try splitCells(arena, doc.lines.items[rows.items[0]]);
        if (cells.len > 1 and std.mem.startsWith(u8, std.mem.trimStart(u8, cells[1], " \t"), "`")) {
            return try rows.toOwnedSlice(arena);
        }
        i = rows.items[rows.items.len - 1];
    }
    return null;
}

/// Contents of each `` `span` `` in `s`, left to right.
fn backtickedSpans(arena: Allocator, s: []const u8) ![][]const u8 {
    var spans: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '`') {
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, s, i + 1, '`') orelse break;
        try spans.append(arena, s[i + 1 .. end]);
        i = end + 1;
    }
    return spans.toOwnedSlice(arena);
}

/// `[A-Za-z_][A-Za-z0-9_]*` runs in `s`.
fn identRuns(arena: Allocator, s: []const u8, min_len: usize) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (!std.ascii.isAlphabetic(s[i]) and s[i] != '_') {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_')) j += 1;
        if (j - i >= min_len) try out.append(arena, s[i..j]);
        i = j;
    }
    return out.toOwnedSlice(arena);
}

/// Backticked spans that are exactly `[a-z0-9_]+` - conf keys, as the §3 table writes them.
fn keySpans(arena: Allocator, s: []const u8) ![][]const u8 {
    const spans = try backtickedSpans(arena, s);
    var out: std.ArrayList([]const u8) = .empty;
    for (spans) |span| {
        if (span.len == 0) continue;
        var ok = true;
        for (span) |c| {
            if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '_') {
                ok = false;
                break;
            }
        }
        if (ok) try out.append(arena, span);
    }
    return out.toOwnedSlice(arena);
}

/// Conf keys the §3 table lists, in file order. The generator ("which keys are missing")
/// and the checker ("which keys are listed") read this one list: they used to walk the
/// section with different row filters and could therefore disagree about "listed".
fn docConfKeys(arena: Allocator, doc: *const Doc, sec3: usize, sec4: usize) !std.ArrayList([]const u8) {
    var keys: std.ArrayList([]const u8) = .empty;
    for (doc.lines.items[sec3..sec4]) |line| {
        if (!rowStartsWithBacktickedCell(line)) continue;
        const cells = try splitCells(arena, line);
        if (cells.len < 2) continue;
        for (try keySpans(arena, cells[1])) |k| try keys.append(arena, k);
    }
    return keys;
}

/// Start of the next `### <module>.zig` block at or after `from`, or null once §1 ends.
/// Blocks are located by re-scanning instead of from a precomputed index list: appending
/// rows shifts every later line, so a list taken up front would go stale mid-run.
fn nextBlockStart(doc: *const Doc, from: usize) ?usize {
    var i = from;
    while (i < doc.lines.items.len) : (i += 1) {
        const l = lineBody(doc.lines.items[i]);
        if (std.mem.startsWith(u8, l, "## ")) return null; // left section 1
        if (!std.mem.startsWith(u8, l, "### ")) continue;
        const token = std.mem.trim(u8, l[4..], " \t");
        const name = token[0 .. std.mem.indexOfAny(u8, token, " \t") orelse token.len];
        if (std.mem.endsWith(u8, name, ".zig")) return i;
    }
    return null;
}

/// The `### <module>.zig` name of a heading line, already trimmed of its `\r`.
fn blockModule(doc: *const Doc, at: usize) []const u8 {
    const l = lineBody(doc.lines.items[at]);
    const token = std.mem.trim(u8, l[4..], " \t");
    return token[0 .. std.mem.indexOfAny(u8, token, " \t") orelse token.len];
}

/// `~12` or `~12/34`: the loc cells this tool is allowed to refresh. Anything else
/// (a hand-written range like `~146-252`) is left alone.
fn isLocCell(s: []const u8) bool {
    if (s.len < 2 or s[0] != '~') return false;
    var i: usize = 1;
    var digits: usize = 0;
    while (true) {
        if (i >= s.len) return digits > 0;
        if (std.ascii.isDigit(s[i])) {
            digits += 1;
            i += 1;
            continue;
        }
        if (s[i] == '/' and digits > 0) {
            digits = 0;
            i += 1;
            continue;
        }
        return false;
    }
}

/// `^[0-9./ ]*$`: a default cell the tool may recompute. Everything else (an em dash,
/// "see Config") belongs to the prose writer.
fn isPlainNumberCell(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c) and c != '.' and c != '/' and c != ' ') return false;
    }
    return true;
}

/// Doc words as a set: a name occurs in the doc iff it is one of its identifier runs, so
/// one precomputed set replaces a `\bname\b` rescan of the whole doc per declaration.
const DocWords = std.array_hash_map.String(void);

fn docWords(arena: Allocator, doc: *const Doc) !DocWords {
    var set: DocWords = .empty;
    for (try identRuns(arena, doc.text(), 1)) |w| try set.put(arena, w, {});
    return set;
}

/// First-occurrence order, one copy per distinct string.
fn uniqueJoin(arena: Allocator, items: []const []const u8, sep: []const u8) ![]const u8 {
    var uniq: std.array_hash_map.String(void) = .empty;
    for (items) |it| try uniq.put(arena, it, {});
    return std.mem.join(arena, sep, uniq.keys());
}

fn fmt(arena: Allocator, comptime f: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(arena, f, args);
}

/// Reassembles a rewritten row, keeping its columns and a CRLF terminator intact.
fn rebuildRow(arena: Allocator, row: []const u8, cr: bool) ![]const u8 {
    return if (cr) fmt(arena, "{s}\r", .{row}) else row;
}

const Report = struct {
    changed: std.ArrayList([]const u8) = .empty,
    added: std.ArrayList([]const u8) = .empty,
    skipped: std.ArrayList([]const u8) = .empty,
};

// ---------------------------------------------------------------- gen

fn section1(doc: *Doc, facts: Facts, rep: *Report, apply: bool) !void {
    const arena = doc.arena;
    const words = try docWords(arena, doc);
    const sec1 = doc.lineStartingWith("## 1. ") orelse return error.MissingSection;
    var cursor = sec1 + 1; // skip the section heading itself
    while (nextBlockStart(doc, cursor)) |start| {
        const end = nextBlockStart(doc, start + 1) orelse doc.lineStartingWith("## 2. ").?;
        const mod = blockModule(doc, start);
        if (facts.module(mod) == null) {
            cursor = end;
            continue;
        }

        const rows = (try findTable(arena, doc, start, end)) orelse continue;
        for (rows) |ri| {
            const raw = doc.lines.items[ri];
            if (isTableSeparator(raw)) continue;
            const cr = raw.len > 0 and raw[raw.len - 1] == '\r';
            const cells = try splitCells(arena, if (cr) raw[0 .. raw.len - 1] else raw);
            if (cells.len < 5) continue;
            const spans = try backtickedSpans(arena, cells[1]);
            var ids: std.ArrayList([]const u8) = .empty;
            for (spans) |span| {
                const runs = try identRuns(arena, span, 3);
                for (runs) |r| {
                    if (!isStop(r)) try ids.append(arena, r);
                }
            }
            var nums: std.ArrayList([]const u8) = .empty;
            for (ids.items) |id| {
                const ln = facts.declLine(mod, id);
                if (ln > 0) try nums.append(arena, try fmt(arena, "{d}", .{ln}));
            }
            if (nums.items.len == 0) {
                try rep.skipped.append(arena, try fmt(arena, "{s} : cannot locate any symbol of row '{s}'", .{ mod, trim(cells[1]) }));
                continue;
            }
            if (!isLocCell(trim(cells[2]))) continue;
            const want = try fmt(arena, "~{s}", .{try std.mem.join(arena, "/", nums.items)});
            if (std.mem.eql(u8, trim(cells[2]), want)) continue;
            try rep.changed.append(arena, try fmt(arena, "{s} : loc {s} -> {s}", .{ mod, trim(cells[2]), want }));
            if (apply) {
                const row = try fmt(arena, "|{s}| {s} |{s}|", .{ cells[1], want, cells[3] });
                doc.setRow(ri, try rebuildRow(arena, row, cr));
            }
        }

        // Append public symbols the doc never mentions: public fns first (that is the
        // shape the table uses), then public struct|enum|union consts.
        const m = facts.module(mod).?;
        var new_rows: std.ArrayList([]const u8) = .empty;
        for (m.decls) |d| {
            if (!isGapSymbol(d) or !std.mem.eql(u8, d.kind, "fn") or words.contains(d.name)) continue;
            const cell = try fmt(arena, "`{s}`", .{d.sig});
            try rep.added.append(arena, try fmt(arena, "{s} : + {s}", .{ mod, cell }));
            try new_rows.append(arena, try fmt(arena, "| {s} | ~{d} |  |", .{ cell, d.line }));
        }
        for (m.decls) |d| {
            if (!isGapSymbol(d) or std.mem.eql(u8, d.kind, "fn") or words.contains(d.name)) continue;
            const cell = try fmt(arena, "`{s}` ({s})", .{ d.name, d.container });
            try rep.added.append(arena, try fmt(arena, "{s} : + {s}", .{ mod, cell }));
            try new_rows.append(arena, try fmt(arena, "| {s} | ~{d} |  |", .{ cell, d.line }));
        }
        if (apply) {
            var insert_at = rows[rows.len - 1] + 1;
            for (new_rows.items) |row| {
                doc.insertRow(insert_at, row);
                insert_at += 1;
            }
        }
        cursor = end;
    }
}

fn section3(doc: *Doc, facts: Facts, rep: *Report, apply: bool) !void {
    const arena = doc.arena;
    const sec3 = doc.lineStartingWith("## 3. ") orelse return error.MissingSection;
    const sec4 = doc.lineStartingWith("## 4. ") orelse return error.MissingSection;

    const rows = (try findTable(arena, doc, sec3, sec4)) orelse return;
    const last_row = rows[rows.len - 1];
    const doc_keys = try docConfKeys(arena, doc, sec3, sec4);
    for (rows) |ri| {
        const raw = doc.lines.items[ri];
        const cr = raw.len > 0 and raw[raw.len - 1] == '\r';
        const cells = try splitCells(arena, if (cr) raw[0 .. raw.len - 1] else raw);
        if (cells.len < 4) continue;
        const keys = try keySpans(arena, cells[1]);

        var types: std.ArrayList([]const u8) = .empty;
        var defs: std.ArrayList([]const u8) = .empty;
        var ok = true;
        for (keys) |k| {
            const field = facts.fieldOfKey(k) orelse {
                ok = false;
                break;
            };
            const f = facts.confField(field) orelse {
                ok = false;
                break;
            };
            try types.append(arena, docType(field, f.type_text));
            const old_def = trim(if (cells.len > 3) cells[3] else "");
            const d = docDefault(f.default_text);
            // keep human-owned defaults: anything that is not a plain number list
            // (an em dash, "see Config", ...) is not ours to recompute
            if (!isPlainNumberCell(old_def)) {
                try defs.append(arena, old_def);
            } else {
                try defs.append(arena, d orelse old_def);
            }
        }
        if (!ok or keys.len == 0) {
            try rep.skipped.append(arena, try fmt(arena, "sec3 : cannot derive type/default for {s}", .{try std.mem.join(arena, "/", keys)}));
            continue;
        }
        const want_type = try uniqueJoin(arena, types.items, " / ");
        const want_def = try uniqueJoin(arena, defs.items, " / ");
        if (std.mem.eql(u8, trim(cells[2]), want_type) and std.mem.eql(u8, trim(cells[3]), want_def)) continue;
        try rep.changed.append(arena, try fmt(arena, "sec3 : {s} -> {s} / {s}", .{ try std.mem.join(arena, "/", keys), want_type, want_def }));
        if (apply) {
            const row = try fmt(arena, "| {s} | {s} | {s} |{s}|", .{ trim(cells[1]), want_type, want_def, if (cells.len > 4) cells[4] else "" });
            doc.setRow(ri, try rebuildRow(arena, row, cr));
        }
    }

    // keys the source parses but the table never lists
    var missing: std.ArrayList([]const u8) = .empty;
    for (facts.conf_keys) |k| {
        var listed = false;
        for (doc_keys.items) |dk| {
            if (std.mem.eql(u8, dk, k.key)) {
                listed = true;
                break;
            }
        }
        if (!listed) try missing.append(arena, k.key);
    }
    std.mem.sort([]const u8, missing.items, {}, strLess);
    for (missing.items) |key| {
        const field = facts.fieldOfKey(key) orelse continue;
        const f = facts.confField(field) orelse continue;
        const d = docDefault(f.default_text) orelse "n/a";
        try rep.added.append(arena, try fmt(arena, "sec3 : + {s}", .{key}));
        if (apply) doc.insertRow(last_row + 1 + rep.added.items.len - 1, try fmt(arena, "| `{s}` | {s} | {s} |  |", .{ key, docType(field, f.type_text), d }));
    }
}

fn docType(field: []const u8, zig_type: []const u8) []const u8 {
    if (std.mem.eql(u8, field, "face_w")) return "ASCII";
    if (std.mem.startsWith(u8, field, "c_")) return "hex";
    if (std.mem.eql(u8, zig_type, "bool")) return "0/1";
    return zig_type;
}

/// Null means "the source default is not something the table can print" - the caller then
/// keeps whatever a human wrote there.
fn docDefault(init: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, init, "true")) return "1";
    if (std.mem.eql(u8, init, "false")) return "0";
    if (std.mem.eql(u8, init, "undefined")) return null;
    if (std.mem.startsWith(u8, init, "rgb(")) return null;
    return init;
}

fn gen(arena: Allocator, io: std.Io, facts: Facts, doc_path: []const u8, dry_run: bool, out: *std.Io.Writer) !bool {
    var doc = try Doc.load(arena, io, doc_path);
    var rep = Report{};
    try section1(&doc, facts, &rep, true);
    try section3(&doc, facts, &rep, true);

    const changed = rep.changed.items.len + rep.added.items.len;
    try out.print("[docs-gen] updated {d}, appended {d}, skipped {d}\n", .{ rep.changed.items.len, rep.added.items.len, rep.skipped.items.len });
    for (rep.changed.items) |c| try out.print("  ~ {s}\n", .{c});
    for (rep.added.items) |a| try out.print("  + {s}\n", .{a});
    for (rep.skipped.items) |s| try out.print("  ! {s}\n", .{s});
    if (changed == 0) {
        try out.print("[docs-gen] {s} unchanged\n", .{doc_path});
        return false;
    }
    if (dry_run) {
        try out.print("[docs-gen] dry run: {s} NOT written\n", .{doc_path});
        return true;
    }
    var bytes: std.ArrayList(u8) = .empty;
    try doc.render(&bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = doc_path, .data = bytes.items });
    try out.print("[docs-gen] wrote {s}\n", .{doc_path});
    return true;
}

// ---------------------------------------------------------------- check

const Checker = struct {
    arena: Allocator,
    facts: Facts,
    fails: std.ArrayList([]const u8) = .empty,
    checked: usize = 0,
    c_sec1: usize = 0,
    c_gaps: usize = 0,
    c_sec2: usize = 0,
    c_sec3: usize = 0,
    c_empty: usize = 0,
    c_stale: usize = 0,

    fn fail(self: *Checker, comptime f: []const u8, args: anytype) !void {
        try self.fails.append(self.arena, try std.fmt.allocPrint(self.arena, f, args));
    }
};

fn checkSection1(ch: *Checker, doc: *const Doc, sec1: usize) !void {
    const arena = ch.arena;
    var cursor = sec1 + 1; // skip the section heading itself
    while (nextBlockStart(doc, cursor)) |start| {
        const end = nextBlockStart(doc, start + 1) orelse doc.lineStartingWith("## 2. ").?;
        const mod = blockModule(doc, start);
        if (ch.facts.module(mod) == null) {
            try ch.fail("sec1: doc mentions module {s} but app/src/{s} does not exist", .{ mod, mod });
            cursor = end;
            continue;
        }
        for (start..end) |i| {
            const spans = try backtickedSpans(arena, doc.lines.items[i]);
            // (a stray CR at the end of a line is irrelevant: spans never include it)
            for (spans) |span| {
                const runs = try identRuns(arena, span, 3);
                for (runs) |id| {
                    if (isStop(id)) continue;
                    ch.checked += 1;
                    ch.c_sec1 += 1;
                    if (ch.facts.hasName(mod, id)) continue;
                    if (ch.facts.hasNameAnywhere(id)) continue;
                    try ch.fail("sec1: {s} mentions `{s}` but it does not exist in app/src (deleted or renamed?)", .{ mod, id });
                }
            }
        }
        cursor = end;
    }
}

fn checkReverseGaps(ch: *Checker, doc: Doc) !void {
    const words = try docWords(ch.arena, &doc);
    for (ch.facts.modules) |m| {
        // main.zig is intentionally partial (only key scheduling symbols); win32.zig is
        // covered by the extern table in §4
        if (std.mem.eql(u8, m.file, "main.zig") or std.mem.eql(u8, m.file, "win32.zig")) continue;
        for (m.decls) |d| {
            if (!isGapSymbol(d)) continue;
            ch.checked += 1; ch.c_gaps += 1;
            if (words.contains(d.name)) continue;
            try ch.fail("sec1: {s} has public symbol {s} that the doc never mentions (run zig build docs-gen)", .{ m.file, d.name });
        }
    }
}

fn checkSection2(ch: *Checker, doc: Doc, sec2: usize, sec3: usize) !void {
    const arena = ch.arena;
    const mihomo = ch.facts.module("mihomo.zig") orelse {
        try ch.fail("sec2: app/src/mihomo.zig is missing", .{});
        return;
    };
    for (doc.lines.items[sec2..sec3]) |line| {
        // | `method` | GET | `/path` | ...
        if (!std.mem.startsWith(u8, line, "|")) continue;
        const cells = try splitCells(arena, line);
        if (cells.len < 4) continue;
        const method = trim(cells[1]);
        const verb = trim(cells[2]);
        if (!std.mem.eql(u8, verb, "GET") and !std.mem.eql(u8, verb, "PUT") and
            !std.mem.eql(u8, verb, "PATCH") and !std.mem.eql(u8, verb, "POST")) continue;
        if (method.len < 2 or method[0] != '`' or method[method.len - 1] != '`') continue;
        const fn_name = method[1 .. method.len - 1];
        const path_spans = try backtickedSpans(arena, cells[3]);
        if (path_spans.len != 1) continue;
        ch.checked += 1; ch.c_sec2 += 1;

        var is_pub_fn = false;
        for (mihomo.decls) |d| {
            if (d.is_pub and std.mem.eql(u8, d.kind, "fn") and std.mem.eql(u8, d.name, fn_name)) is_pub_fn = true;
        }
        if (!is_pub_fn) try ch.fail("sec2: endpoint {s} is not a pub fn in mihomo.zig", .{fn_name});

        // `/proxies/{name}` and `/proxies/{group}` both address the literal `/proxies/{s}`,
        // and the query string is not part of the path column. Exact match, not substring:
        // the doc must not pass on `/version` while the literal says `/versionz`.
        const path_only = path_spans[0][0 .. std.mem.indexOfScalar(u8, path_spans[0], '?') orelse path_spans[0].len];
        const want = try normalizePathTemplate(arena, path_only);
        var found = false;
        for (mihomo.string_literals) |lit| {
            const body = if (lit.len >= 2 and lit[0] == '"') lit[1 .. lit.len - 1] else lit;
            if (body.len > 0 and body[0] == '{') continue; // JSON body templates, not paths
            const head = body[0 .. std.mem.indexOfScalar(u8, body, '?') orelse body.len];
            if (std.mem.eql(u8, try normalizePathTemplate(arena, head), want)) {
                found = true;
                break;
            }
        }
        if (!found) try ch.fail("sec2: endpoint {s} path literal {s} not found in mihomo.zig", .{ fn_name, want });
    }
}

/// `/proxies/{name}` -> `/proxies/{s}`: the placeholder mihomo.zig formats into.
fn normalizePathTemplate(arena: Allocator, path: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, path, i, '}') orelse {
                try buf.append(arena, path[i]);
                i += 1;
                continue;
            };
            try buf.appendSlice(arena, "{s}");
            i = close + 1;
            continue;
        }
        try buf.append(arena, path[i]);
        i += 1;
    }
    return buf.items;
}

fn checkSection3(ch: *Checker, doc: Doc, sec3: usize, sec4: usize) !void {
    const doc_keys = try docConfKeys(ch.arena, &doc, sec3, sec4);
    for (doc_keys.items) |k| {
        ch.checked += 1; ch.c_sec3 += 1;
        if (ch.facts.fieldOfKey(k) == null) {
            try ch.fail("sec3: conf key {s} has no branch in Config.load (key deleted or renamed?)", .{k});
        }
    }
    for (ch.facts.conf_keys) |k| {
        var listed = false;
        for (doc_keys.items) |dk| {
            if (std.mem.eql(u8, dk, k.key)) {
                listed = true;
                break;
            }
        }
        if (!listed) try ch.fail("sec3: Config.load parses key {s} but the doc does not list it (run zig build docs-gen)", .{k.key});
    }
}

fn checkEmptyDescriptions(ch: *Checker, doc: Doc, sec1: usize, sec2: usize, sec3: usize, sec4: usize) !void {
    const arena = ch.arena;
    for ([_]struct { from: usize, to: usize }{ .{ .from = sec1, .to = sec2 }, .{ .from = sec3, .to = sec4 } }) |range| {
        for (doc.lines.items[range.from..range.to]) |line| {
            if (!rowStartsWithBacktickedCell(line)) continue;
            const cells = try splitCells(arena, line);
            if (cells.len < 5) continue;
            if (std.mem.trim(u8, cells[cells.len - 2], " \t\r").len != 0) continue;
            ch.checked += 1; ch.c_empty += 1;
            try ch.fail("empty description cell: {s} - write one line for it", .{trim(cells[1])});
        }
    }
}

fn check(arena: Allocator, io: std.Io, facts: Facts, doc_path: []const u8, out: *std.Io.Writer) !bool {
    var doc = try Doc.load(arena, io, doc_path);
    var ch = Checker{ .arena = arena, .facts = facts };
    const sec1 = doc.lineStartingWith("## 1. ") orelse return error.MissingSection;
    const sec2 = doc.lineStartingWith("## 2. ") orelse return error.MissingSection;
    const sec3 = doc.lineStartingWith("## 3. ") orelse return error.MissingSection;
    const sec4 = doc.lineStartingWith("## 4. ") orelse return error.MissingSection;

    try checkSection1(&ch, &doc, sec1);
    try checkReverseGaps(&ch, doc);
    try checkSection2(&ch, doc, sec2, sec3);
    try checkSection3(&ch, doc, sec3, sec4);
    for (facts.modules) |m| {
        if (std.mem.indexOf(u8, doc.text(), m.file) == null) {
            try ch.fail("module {s} is not mentioned anywhere in the doc (add a section)", .{m.file});
        }
    }
    try checkEmptyDescriptions(&ch, doc, sec1, sec2, sec3, sec4);

    // Generated cells are drift too: run the generator's comparison here, report-only, so
    // a hand-edited loc / type / default cell cannot pass the gate. (Rows the generator
    // would *append* are already covered: new public symbols by the reverse-gap check,
    // new conf keys by section 3.)
    var rep = Report{};
    try section1(&doc, facts, &rep, false);
    try section3(&doc, facts, &rep, false);
    for (rep.changed.items) |c| {
        ch.checked += 1;
        ch.c_stale += 1;
        try ch.fail("stale generated cell: {s} (run zig build docs-gen)", .{c});
    }

    try out.print("[docs-check] checked {d} items (sec1 {d}, gaps {d}, sec2 {d}, sec3 {d}, empty {d}, stale {d}) ({s})\n", .{ ch.checked, ch.c_sec1, ch.c_gaps, ch.c_sec2, ch.c_sec3, ch.c_empty, ch.c_stale, doc_path });
    if (ch.fails.items.len == 0) {
        try out.print("[docs-check] OK: doc matches source\n", .{});
        return true;
    }
    try out.print("[docs-check] {d} mismatch(es):\n", .{ch.fails.items.len});
    for (ch.fails.items) |f| try out.print("  - {s}\n", .{f});
    return false;
}

// ---------------------------------------------------------------- main

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_file.interface;

    if (args.len < 4) {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    }
    const mode = args[1];
    const src_dir = args[2];
    const doc_path = args[3];

    const facts = collectFacts(arena, io, src_dir) catch |err| switch (err) {
        error.ParseFailed => {
            try out.flush();
            std.process.exit(1);
        },
        else => return err,
    };

    if (std.mem.eql(u8, mode, "gen")) {
        var dry_run = false;
        for (args[4..]) |a| {
            if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--dry-run")) dry_run = true;
        }
        _ = try gen(arena, io, facts, doc_path, dry_run, out);
        try out.flush();
        return;
    }
    if (std.mem.eql(u8, mode, "check")) {
        const ok = try check(arena, io, facts, doc_path, out);
        try out.flush();
        if (!ok) std.process.exit(1);
        return;
    }
    try out.print("docsgen: unknown mode '{s}'\n{s}", .{ mode, usage });
    try out.flush();
    std.process.exit(2);
}
