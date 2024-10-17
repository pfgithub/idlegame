const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const fmt = b.addFmt(.{ .paths = &.{ "build.zig", "src" } });
    b.getInstallStep().dependOn(&fmt.step);

    const exe = b.addExecutable(.{
        .name = "idlegame",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run");
    run_step.dependOn(&run.step);
}
