//! macOS Keychain read via SecItemCopyMatching — used to borrow the
//! Claude Code OAuth credentials (service "Claude Code-credentials")
//! with the user's consent. No `security` shell-outs: the SDK already
//! links the Security framework, so we declare the handful of C symbols
//! we need directly.
//!
//! First read from a new binary triggers macOS's one-time consent prompt
//! for the item ("token-tach wants to access ..."), which is the honest
//! UX for borrowing another app's credential — document, don't hide.

const std = @import("std");
const builtin = @import("builtin");

pub const claude_service = "Claude Code-credentials";

const CFTypeRef = ?*const anyopaque;
const CFStringRef = ?*const anyopaque;
const CFDictionaryRef = ?*const anyopaque;
const CFDataRef = ?*const anyopaque;
const CFAllocatorRef = ?*const anyopaque;
const CFIndex = isize;
const OSStatus = i32;

const errSecItemNotFound: OSStatus = -25300;
const kCFStringEncodingUTF8: u32 = 0x0800_0100;

extern "c" fn CFStringCreateWithBytes(
    alloc: CFAllocatorRef,
    bytes: [*]const u8,
    numBytes: CFIndex,
    encoding: u32,
    isExternalRepresentation: u8,
) CFStringRef;
extern "c" fn CFDictionaryCreate(
    allocator: CFAllocatorRef,
    keys: [*]const CFTypeRef,
    values: [*]const CFTypeRef,
    numValues: CFIndex,
    keyCallBacks: ?*const anyopaque,
    valueCallBacks: ?*const anyopaque,
) CFDictionaryRef;
extern "c" fn CFDataGetBytePtr(data: CFDataRef) [*]const u8;
extern "c" fn CFDataGetLength(data: CFDataRef) CFIndex;
extern "c" fn CFRelease(cf: CFTypeRef) void;

extern "c" var kCFTypeDictionaryKeyCallBacks: anyopaque;
extern "c" var kCFTypeDictionaryValueCallBacks: anyopaque;
extern "c" var kCFBooleanTrue: CFTypeRef;

extern "c" var kSecClass: CFStringRef;
extern "c" var kSecClassGenericPassword: CFStringRef;
extern "c" var kSecAttrService: CFStringRef;
extern "c" var kSecMatchLimit: CFStringRef;
extern "c" var kSecMatchLimitOne: CFStringRef;
extern "c" var kSecReturnData: CFStringRef;

extern "c" fn SecItemCopyMatching(query: CFDictionaryRef, result: *CFTypeRef) OSStatus;

pub const Error = error{ Unsupported, Keychain, OutOfMemory };

/// Read a generic password by service name. Returns null when the item
/// does not exist; the caller owns the returned bytes.
pub fn readGenericPassword(allocator: std.mem.Allocator, service: []const u8) Error!?[]u8 {
    if (builtin.os.tag != .macos) return Error.Unsupported;

    const cf_service = CFStringCreateWithBytes(null, service.ptr, @intCast(service.len), kCFStringEncodingUTF8, 0) orelse
        return Error.Keychain;
    defer CFRelease(cf_service);

    const keys = [_]CFTypeRef{ kSecClass, kSecAttrService, kSecReturnData, kSecMatchLimit };
    const values = [_]CFTypeRef{ kSecClassGenericPassword, cf_service, kCFBooleanTrue, kSecMatchLimitOne };
    const query = CFDictionaryCreate(
        null,
        &keys,
        &values,
        keys.len,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    ) orelse return Error.Keychain;
    defer CFRelease(query);

    var result: CFTypeRef = null;
    const status = SecItemCopyMatching(query, &result);
    if (status == errSecItemNotFound) return null;
    if (status != 0) {
        std.log.warn("keychain read failed for service '{s}': OSStatus {d}", .{ service, status });
        return Error.Keychain;
    }
    const data: CFDataRef = result;
    defer CFRelease(data);

    const len: usize = @intCast(CFDataGetLength(data));
    const bytes = CFDataGetBytePtr(data);
    const out = try allocator.alloc(u8, len);
    @memcpy(out, bytes[0..len]);
    return out;
}

test "missing service returns null, not an error" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const got = try readGenericPassword(std.testing.allocator, "token-tach-test-nonexistent-service-xyz");
    try std.testing.expectEqual(@as(?[]u8, null), got);
}
