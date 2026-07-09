//! This build belongs to your app, written once by `native eject`:
//! the `native` CLI stops generating a build graph and
//! drives this file through `zig build` instead, and it will
//! never rewrite it. `addApp` wires the complete standard app
//! build — executable, `zig build run`, `zig build test`, and
//! the -Dplatform/-Dweb-engine/-Dautomation/-Doptimize flags —
//! from the framework's build/app.zig, so a framework upgrade
//! still upgrades your build. Extend from here with
//! `addAppArtifacts` when you need extra sources or steps.

const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "token-tach" });

    // src/core/keychain.zig calls Security/CoreFoundation directly; the SDK
    // links those into the app module but not the test module.
    if (artifacts.tests.rootModuleTarget().os.tag == .macos) {
        if (b.sysroot) |sysroot| {
            artifacts.tests.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
        artifacts.tests.root_module.linkFramework("Security", .{});
        artifacts.tests.root_module.linkFramework("CoreFoundation", .{});
    }
}
