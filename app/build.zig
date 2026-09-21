const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const exe = b.addExecutable(.{
        .name = "mihomo-widget",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("kernel32", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    exe.root_module.linkSystemLibrary("winhttp", .{});
    exe.root_module.linkSystemLibrary("psapi", .{});
    exe.subsystem = .windows;

    // TUN needs an elevated process to create the virtual NIC. Dev builds keep
    // the default (no UAC) so automation isn't blocked; ship with -Dadmin to
    // embed a requireAdministrator manifest.
    const admin = b.option(bool, "admin", "embed requireAdministrator manifest (UAC on launch)") orelse false;
    if (admin) exe.win32_manifest = b.path("app.manifest");

    // zigwin32: full typed Win32 bindings (metaprogrammed from win32metadata)
    const zw = b.dependency("win32", .{});
    exe.root_module.addImport("win32", zw.module("win32"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run mihomo-widget");
    run_step.dependOn(&run_cmd.step);

    // dev probe (console) exercising the mihomo client against a live controller
    const probe = b.addExecutable(.{
        .name = "probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dev_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    probe.root_module.linkSystemLibrary("winhttp", .{});
    probe.root_module.addImport("win32", zw.module("win32"));
    b.installArtifact(probe);
    const run_probe = b.addRunArtifact(probe);
    const probe_step = b.step("probe", "Run dev probe");
    probe_step.dependOn(&run_probe.step);

    // docs: docs/API-REFERENCE.md is generated where it is derived (facts from
    // std.zig.Ast) and verified against app/src by one tool - see tools/docsgen.zig.
    //   zig build docs-gen     rewrite the generated cells
    //   zig build docs-check   gate: fails when the doc drifted from the source
    // Built for the host on purpose: this is a build-time tool, and it must run even
    // when the widget itself is cross-compiled. `stdio = .inherit` makes the step
    // side-effecting (so it always runs - the sources it reads are not tracked inputs)
    // and keeps the tool's report on the console instead of in a captured buffer.
    const docsgen = b.addExecutable(.{
        .name = "docsgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docsgen.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const src_dir = b.pathFromRoot("src");
    // the doc sits at the repo root, one level above the build root (app/): resolve the
    // '..' away, the tool opens paths through the OS (which does not fold them)
    const doc_file = std.fs.path.resolve(b.allocator, &.{ b.pathFromRoot(".."), "docs", "API-REFERENCE.md" }) catch @panic("OOM");

    const run_gen = b.addRunArtifact(docsgen);
    run_gen.addArgs(&.{ "gen", src_dir, doc_file });
    if (b.args) |args| run_gen.addArgs(args); // `zig build docs-gen -- -n` for a dry run
    run_gen.stdio = .inherit;
    const docs_gen_step = b.step("docs-gen", "Rewrite the generated cells of docs/API-REFERENCE.md");
    docs_gen_step.dependOn(&run_gen.step);

    const run_check = b.addRunArtifact(docsgen);
    run_check.addArgs(&.{ "check", src_dir, doc_file });
    run_check.stdio = .inherit;
    const docs_check_step = b.step("docs-check", "Verify docs/API-REFERENCE.md against app/src");
    docs_check_step.dependOn(&run_check.step);
}
