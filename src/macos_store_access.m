#import <AppKit/AppKit.h>
#import <Security/SecTask.h>

#include <pwd.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

static NSMutableArray<NSURL *> *TokenTachScopedURLs;

static BOOL TokenTachCopyPath(NSURL *url, char *output, size_t capacity, size_t *length) {
    if (!url || !output || !length) return NO;
    const char *path = url.fileSystemRepresentation;
    if (!path) return NO;
    size_t count = strlen(path);
    if (count >= capacity) return NO;
    memcpy(output, path, count);
    *length = count;
    return YES;
}

static NSString *TokenTachRealHome(void) {
    struct passwd *entry = getpwuid(getuid());
    if (entry && entry->pw_dir) {
        return [NSString stringWithUTF8String:entry->pw_dir];
    }
    return NSHomeDirectory();
}

static void TokenTachRetainScope(NSURL *url) {
    if (!TokenTachScopedURLs) TokenTachScopedURLs = [NSMutableArray array];
    [TokenTachScopedURLs addObject:url];
}

static BOOL TokenTachSaveBookmark(NSString *key, NSURL *url) {
    NSError *error = nil;
    NSData *bookmark = [url bookmarkDataWithOptions:(NSURLBookmarkCreationWithSecurityScope |
                                                      NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess)
                     includingResourceValuesForKeys:nil
                                      relativeToURL:nil
                                              error:&error];
    if (!bookmark) {
        NSLog(@"Token Tach could not create %@ bookmark: %@", key, error);
        return NO;
    }
    [[NSUserDefaults standardUserDefaults] setObject:bookmark forKey:key];
    return YES;
}

static NSURL *TokenTachRestoreBookmark(NSString *key) {
    NSData *bookmark = [[NSUserDefaults standardUserDefaults] dataForKey:key];
    if (!bookmark) return nil;

    BOOL stale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                                          options:NSURLBookmarkResolutionWithSecurityScope
                                    relativeToURL:nil
                              bookmarkDataIsStale:&stale
                                            error:&error];
    if (!url || ![url startAccessingSecurityScopedResource]) {
        NSLog(@"Token Tach could not restore %@ bookmark: %@", key, error);
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:key];
        return nil;
    }
    TokenTachRetainScope(url);
    if (stale) (void)TokenTachSaveBookmark(key, url);
    return url;
}

static NSURL *TokenTachChooseFolder(NSString *key, NSString *agent, NSString *suggestedName) {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = [NSString stringWithFormat:@"Choose your %@ data folder", agent];
    panel.message = [NSString stringWithFormat:
        @"Token Tach reads usage logs locally. Select the %@ folder in your home directory. Nothing is uploaded.",
        suggestedName];
    panel.prompt = @"Allow Read Access";
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    panel.showsHiddenFiles = YES;

    NSString *suggested = [TokenTachRealHome() stringByAppendingPathComponent:suggestedName];
    if ([[NSFileManager defaultManager] fileExistsAtPath:suggested]) {
        panel.directoryURL = [NSURL fileURLWithPath:suggested isDirectory:YES];
    } else {
        panel.directoryURL = [NSURL fileURLWithPath:TokenTachRealHome() isDirectory:YES];
    }

    if ([panel runModal] != NSModalResponseOK) return nil;
    NSURL *url = panel.URL;
    if (!url) return nil;
    if (![url startAccessingSecurityScopedResource]) {
        NSLog(@"Token Tach did not receive security-scoped access for %@", url.path);
        return nil;
    }
    TokenTachRetainScope(url);
    if (!TokenTachSaveBookmark(key, url)) return nil;
    return url;
}

uint8_t token_tach_macos_is_sandboxed(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return 0;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.app-sandbox"), NULL);
    CFRelease(task);
    BOOL enabled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    return enabled ? 1 : 0;
}

int token_tach_macos_prepare_store_access(
    char *claude_out, size_t claude_capacity, size_t *claude_length,
    char *codex_out, size_t codex_capacity, size_t *codex_length,
    char *opencode_out, size_t opencode_capacity, size_t *opencode_length,
    char *home_out, size_t home_capacity, size_t *home_length
) {
    @autoreleasepool {
        *claude_length = 0;
        *codex_length = 0;
        *opencode_length = 0;
        *home_length = 0;
        if (!token_tach_macos_is_sandboxed()) return 0;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSURL *claude = TokenTachRestoreBookmark(@"ClaudeDataFolderBookmark");
        NSURL *codex = TokenTachRestoreBookmark(@"CodexDataFolderBookmark");
        NSURL *opencode = TokenTachRestoreBookmark(@"OpenCodeDataFolderBookmark");
        if (!claude || !codex || !opencode) {
            [NSApp activateIgnoringOtherApps:YES];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Connect Token Tach to your local usage logs";
            alert.informativeText = @"The Mac App Store sandbox requires you to choose the Claude, Codex, and OpenCode data folders once. Token Tach receives read-only access and keeps all processing on this Mac.";
            [alert addButtonWithTitle:@"Continue"];
            [alert runModal];
        }
        if (!claude) claude = TokenTachChooseFolder(@"ClaudeDataFolderBookmark", @"Claude Code", @".claude");
        if (!codex) codex = TokenTachChooseFolder(@"CodexDataFolderBookmark", @"Codex", @".codex");
        if (!opencode) opencode = TokenTachChooseFolder(@"OpenCodeDataFolderBookmark", @"OpenCode", @".local/share/opencode");

        if (claude) (void)TokenTachCopyPath(claude, claude_out, claude_capacity, claude_length);
        if (codex) (void)TokenTachCopyPath(codex, codex_out, codex_capacity, codex_length);
        if (opencode) {
            NSURL *database = [opencode URLByAppendingPathComponent:@"opencode.db" isDirectory:NO];
            (void)TokenTachCopyPath(database, opencode_out, opencode_capacity, opencode_length);
        }
        NSURL *containerHome = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
        (void)TokenTachCopyPath(containerHome, home_out, home_capacity, home_length);
        return (claude ? 1 : 0) | (codex ? 2 : 0) | (opencode ? 4 : 0);
    }
}
