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
const app_manifest = @import("app.zon");

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "token-tach" });
    const app_version = b.addOptions();
    app_version.addOption([]const u8, "version", app_manifest.version);
    artifacts.exe.root_module.addOptions("app_version", app_version);
    artifacts.exe.root_module.linkSystemLibrary("sqlite3", .{});
    if (artifacts.tests.root_module != artifacts.exe.root_module) {
        artifacts.tests.root_module.addOptions("app_version", app_version);
        artifacts.tests.root_module.linkSystemLibrary("sqlite3", .{});
    }
    const app_store = b.option(bool, "app-store", "Link macOS store binaries with Apple's ld") orelse false;
    const updater = b.option(bool, "updater", "Enable Sparkle in direct-download macOS builds") orelse false;
    const sparkle_dir = b.option([]const u8, "sparkle-dir", "Directory containing Sparkle.framework");

    if (app_store and updater) @panic("-Dapp-store and -Dupdater are mutually exclusive");
    if (updater and artifacts.exe.rootModuleTarget().os.tag != .macos) @panic("-Dupdater requires a macOS target");

    const updater_options = b.addOptions();
    updater_options.addOption(bool, "enabled", updater);
    artifacts.exe.root_module.addOptions("updater_options", updater_options);
    if (artifacts.tests.root_module != artifacts.exe.root_module) {
        artifacts.tests.root_module.addOptions("updater_options", updater_options);
    }

    // Reserve load-command space in store binaries so Apple's `vtool` can
    // replace Zig's private build-tool record with App Store-recognized Mach-O
    // metadata before signing. Development binaries need no post-link edit.
    if (app_store and artifacts.exe.rootModuleTarget().os.tag == .macos) {
        artifacts.exe.headerpad_size = 4096;
    }

    if (artifacts.exe.rootModuleTarget().os.tag == .macos) {
        if (b.sysroot) |sysroot| {
            _ = sysroot;
            artifacts.exe.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            if (artifacts.tests.root_module != artifacts.exe.root_module) {
                artifacts.tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            }
        }
        const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
        const objc_flags: []const []const u8 = if (b.sysroot) |sysroot|
            &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include }
        else
            &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-mmacosx-version-min=11.0" };
        artifacts.exe.root_module.addCSourceFile(.{ .file = b.path("src/macos_store_access.m"), .flags = objc_flags });
        // Release builds reuse the app module for tests; attach the shim only
        // once in that graph or the exported C symbols are duplicated.
        if (artifacts.tests.root_module != artifacts.exe.root_module) {
            artifacts.tests.root_module.addCSourceFile(.{ .file = b.path("src/macos_store_access.m"), .flags = objc_flags });
        }
        if (updater) {
            const framework_dir = sparkle_dir orelse @panic("-Dupdater requires -Dsparkle-dir=<distribution directory>");
            artifacts.exe.root_module.addCSourceFile(.{ .file = b.path("src/macos_updater.m"), .flags = objc_flags });
            artifacts.exe.root_module.addFrameworkPath(.{ .cwd_relative = framework_dir });
            artifacts.exe.root_module.linkFramework("Sparkle", .{});
            artifacts.exe.root_module.addRPathSpecial("@executable_path/../Frameworks");
        }
    }

    // src/core/keychain.zig calls Security/CoreFoundation directly; the SDK
    // links those into the app module but not the test module.
    if (artifacts.tests.rootModuleTarget().os.tag == .macos) {
        if (b.sysroot) |sysroot| {
            artifacts.tests.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
        artifacts.tests.root_module.linkFramework("Security", .{});
        artifacts.tests.root_module.linkFramework("CoreFoundation", .{});
        artifacts.tests.root_module.linkFramework("Foundation", .{});
        artifacts.tests.root_module.linkFramework("AppKit", .{});
    }
}
