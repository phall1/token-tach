//! Project identity — which repository a working directory belongs to.
//!
//! Every collector hands us a `cwd` and nothing else, and until this module
//! existed the per-project dimension WAS that string: the ledger keyed its
//! PROJECTS rollup on it byte-for-byte, the durable store interned it as
//! `project_id`, and the roster row showed its basename. That is wrong in
//! three ways at once, and all three are the same mistake — treating the
//! directory an agent happened to sit in as the thing being worked on:
//!
//!   1. A git worktree is a different directory and the same project.
//!      `~/workspace/token-tach/.claude/worktrees/toasty-floating-marshmallow`
//!      showed up as a project called "toasty-floating-marshmallow", with
//!      its own cost total, unrelated to "token-tach".
//!   2. A subdirectory is not a project either. An agent started in
//!      `token-tach/src/core` was a project called "core".
//!   3. Two of those splits produce rows whose LABELS collide (the
//!      dashboard basenames its keys at paint time) while their totals stay
//!      separate — the worst of both, two identical-looking rows.
//!
//! So the project dimension is the repository ROOT, resolved once per
//! distinct cwd and memoized.
//!
//! ## Why two strategies, and why neither alone is enough
//!
//! Resolution is filesystem-first with a pure-string fallback, because the
//! two fail in exactly opposite directions and the failures are both real
//! on a working machine — this is measured, not hypothetical:
//!
//! - **Only the filesystem can resolve a worktree whose name says nothing.**
//!   `git worktree add` puts the tree wherever you point it, and people
//!   point it at siblings: `~/workspace/share-prompt` is a worktree of
//!   `intelobservatory`. No string rule can know that, and a plausible one
//!   ("strip the suffix") is worse than useless — it maps `phux-mobile-c`
//!   to `phux`, a DIFFERENT real repository next door, so spend lands on
//!   the wrong project instead of merely an odd-looking one.
//! - **Only a string rule can resolve a cwd that no longer exists.** A
//!   transcript outlives the worktree it was written in; most historical
//!   `.claude/worktrees` paths on this machine name deleted directories,
//!   and the cold-start replay walks months of them. `stat` has nothing to
//!   say about a path that is gone.
//!
//! The upward walk covers more of the second case than it looks: a deleted
//! `<repo>/.claude/worktrees/<name>` still has `<repo>` as an ancestor, so
//! the walk finds `<repo>/.git` and gets the right answer anyway. The
//! string rule is what remains for the case where the whole tree moved.
//!
//! ## What this module deliberately does not do
//!
//! It never fails and it never allocates on the answer path. `rootFor`
//! returns a slice on every input — memo hit, disk truth, string rollup, or
//! the cwd unchanged — because it is called from `engine.ingest`, which
//! returns void and must not be able to drop an event over a directory it
//! could not classify. Out-of-memory degrades to the string rule; it does
//! not propagate.
//!
//! It also does not rewrite the stored `cwd`. `Session.cwd` keeps the true
//! working directory so the detail row can still tell you WHICH worktree an
//! agent is in; only the aggregation key and the label roll up.

const std = @import("std");

/// A `.git` file is one short line (`gitdir: <path>`). The cap is slack for
/// a long gitdir, not a guess at the format — anything larger is not a
/// worktree pointer and reading it is wasted I/O.
pub const max_git_file_bytes: usize = 4096;

/// How far up the tree to look for a repository root. A cwd twenty-four
/// levels below its repo does not happen; the bound is here so a
/// pathological path costs a bounded number of syscalls rather than one per
/// segment.
pub const max_walk_depth: usize = 24;

/// Distinct cwds remembered. Past this the resolver keeps working and stops
/// remembering — see `Resolver.rootFor`. Sized well above the number of
/// directories one machine's agents actually run in, so the degraded path
/// is a safety valve and not a regime anyone reaches.
pub const max_memo_entries: usize = 512;

/// The path segment that marks a worktree container, for the string rule.
/// Matches `<repo>/.claude/worktrees/<name>`, `<repo>/.worktrees/<name>`
/// and `<repo>/.phui/worktrees/<name>` — the shapes tools actually use —
/// and deliberately NOT a plain `worktrees/` directory, which is just as
/// likely to be a source folder a project owns.
///
/// The rule in one sentence: a segment named `worktrees` counts only when
/// it is itself hidden or sits inside a hidden directory.
/// A container with nothing after it is the container itself, not a
/// worktree, so the cut only counts when a name follows it.
fn worktreeContainerCut(path: []const u8) ?usize {
    var i: usize = 0;
    var seg_start: usize = 0;
    var prev_start: usize = 0;
    var prev_len: usize = 0;
    while (i <= path.len) : (i += 1) {
        const at_end = i == path.len;
        if (!at_end and path[i] != '/') continue;
        const seg = path[seg_start..i];
        if (seg.len > 0) {
            const hidden_self = std.mem.eql(u8, seg, ".worktrees");
            const hidden_parent = std.mem.eql(u8, seg, "worktrees") and
                prev_len > 0 and path[prev_start] == '.';
            if (hidden_self or hidden_parent) {
                // Require a named worktree after the container.
                if (at_end or i + 1 >= path.len) return null;
                // `<repo>/.claude/worktrees/...` — cut before `.claude`,
                // not before `worktrees`, or the "repo" becomes ".claude".
                return if (hidden_self) seg_start else prev_start;
            }
            prev_start = seg_start;
            prev_len = seg.len;
        }
        if (at_end) break;
        seg_start = i + 1;
    }
    return null;
}

/// Trailing-slash-tolerant, allocation-free worktree rollup. Returns a
/// prefix of `path` — the repository root if `path` is inside a recognized
/// worktree container, otherwise `path` with trailing slashes trimmed.
///
/// Pure and deterministic on purpose: this is the answer for paths that no
/// longer exist, and it is what the tests pin. The filesystem walk in
/// `Resolver` can only ever improve on it.
pub fn rollupWorktreePath(path: []const u8) []const u8 {
    const trimmed = trimTrailingSlashes(path);
    const cut = worktreeContainerCut(trimmed) orelse return trimmed;
    // `cut` indexes the container segment; the root is everything before
    // its separator. A container at position 0 means the path is nothing
    // but a container — no root to name, so keep the input.
    if (cut == 0) return trimmed;
    return trimTrailingSlashes(trimmed[0 .. cut - 1]);
}

/// Drop trailing '/' without touching a bare root.
fn trimTrailingSlashes(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

/// Lexically resolve `.` and `..` in a posix path into `out`, returning the
/// normalized slice. No filesystem access, so no symlink semantics — which
/// is what we want: the answer must be the same for a path that is gone.
///
/// `..` past the root is dropped rather than preserved; a gitdir pointer
/// that escapes the filesystem root is malformed and there is nothing
/// better to do with it than clamp.
fn normalizePosix(out: []u8, path: []const u8) ?[]const u8 {
    const absolute = path.len > 0 and path[0] == '/';
    var len: usize = 0;
    if (absolute) {
        if (out.len == 0) return null;
        out[0] = '/';
        len = 1;
    }
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            // Walk back over the previous segment, if there is one to walk
            // back over. For a relative path with nothing to pop, the
            // `..` has to be kept or the result means something else.
            if (len > (if (absolute) @as(usize, 1) else 0)) {
                var back = len;
                if (back > 0 and out[back - 1] == '/') back -= 1;
                while (back > 0 and out[back - 1] != '/') back -= 1;
                const floor: usize = if (absolute) 1 else 0;
                if (back >= floor) {
                    len = back;
                    continue;
                }
            }
            if (absolute) continue;
        }
        if (len > 0 and out[len - 1] != '/') {
            if (len == out.len) return null;
            out[len] = '/';
            len += 1;
        }
        if (len + seg.len > out.len) return null;
        @memcpy(out[len..][0..seg.len], seg);
        len += seg.len;
    }
    if (len == 0) return null;
    return trimTrailingSlashes(out[0..len]);
}

/// Turn a git admin directory into the working tree it belongs to, by
/// cutting at the FIRST `/.git/`.
///
/// Every admin path git hands out for a linked worktree or a submodule of
/// one is rooted at the main repository's `.git`:
///
///   /w/token-tach/.git/worktrees/toasty                        -> /w/token-tach
///   /w/token-tach/.git/worktrees/toasty/modules/vendor/native  -> /w/token-tach
///
/// The second line is why it is the first `/.git/` and not the last, and
/// why this beats following `commondir`: a submodule checked out inside a
/// worktree has a full repository as its admin dir with no `commondir` at
/// all, so the by-the-book walk dead-ends where this rule succeeds.
fn workTreeFromGitDir(git_dir: []const u8) ?[]const u8 {
    const marker = "/.git/";
    const at = std.mem.indexOf(u8, git_dir, marker) orelse return null;
    if (at == 0) return null;
    return git_dir[0..at];
}

/// Parse the `gitdir: <path>` line of a worktree's `.git` file. The path
/// may be relative — it is on this machine, for a submodule inside a
/// worktree — so it is resolved against `dir`, the directory that holds
/// the `.git` file. Treating it as absolute silently yields garbage.
fn gitDirFromFile(out: []u8, dir: []const u8, text: []const u8) ?[]const u8 {
    const prefix = "gitdir:";
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    const line = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const raw = std.mem.trim(u8, line[prefix.len..], " \t");
    if (raw.len == 0) return null;
    if (raw[0] == '/') return normalizePosix(out, raw);
    var join_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
    const joined = std.fmt.bufPrint(&join_buf, "{s}/{s}", .{ dir, raw }) catch return null;
    return normalizePosix(out, joined);
}

/// Memoizing cwd -> repository-root resolver. Lives on the Model for the
/// life of the process; one instance, one map.
///
/// Not part of the journaled Model state on purpose. The map is a cache of
/// a filesystem fact, and the value it produces is copied into the roster,
/// the ledger and the history store at ingest — so a replay reads the
/// recorded answers rather than re-deriving them on a machine where the
/// worktree has since been deleted.
pub const Resolver = struct {
    /// Null disables memoization, and with it the filesystem walk: every
    /// answer comes from the pure string rule.
    ///
    /// That is the DEFAULT, so a `Resolver` is safely default-constructible
    /// and a Model assembled without `engine.setup` — every unit test that
    /// builds one, and the journal replay harness — resolves projects
    /// deterministically instead of reading whatever tree the test happens
    /// to run inside. `setup` installs the real allocator.
    allocator: ?std.mem.Allocator = null,
    /// Where the upward walk stops, exclusive. A home directory under
    /// version control is a real setup, and without this guard every cwd
    /// under `~` that is not itself in a repo — `~/workspace/linear`, say —
    /// would resolve to the account name and every unrelated project would
    /// merge into one row called "phall". Empty disables the guard.
    home: []const u8 = "",
    /// cwd -> resolved root. Owns both sides of every entry.
    memo: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    /// The full resolver: memoized, filesystem-first.
    pub fn init(allocator: std.mem.Allocator, home: []const u8) Resolver {
        return .{ .allocator = allocator, .home = home };
    }

    pub fn deinit(self: *Resolver) void {
        const allocator = self.allocator orelse return;
        for (self.memo.keys(), self.memo.values()) |k, v| {
            allocator.free(k);
            allocator.free(v);
        }
        self.memo.deinit(allocator);
    }

    /// The repository root `cwd` belongs to. Never fails.
    ///
    /// The returned slice is either a subslice of `cwd` (string rule) or
    /// owned by the memo and valid until `deinit`. Callers copy it — the
    /// roster into a `Fixed`, the ledger and the dictionary into their own
    /// duped keys — so neither lifetime constrains them.
    ///
    /// Past `max_memo_entries` distinct cwds this degrades to the pure
    /// string rule rather than growing without bound or evicting entries
    /// that callers may still be holding. That trade is deliberate: the
    /// string rule is a correct-if-incomplete answer, and a resolver that
    /// could hand back a freed slice is not.
    pub fn rootFor(self: *Resolver, cwd: []const u8) []const u8 {
        if (cwd.len == 0) return cwd;
        // No allocator means no memo, and a disk answer would have nowhere
        // to live that outlives this call — so don't pay for the walk.
        const allocator = self.allocator orelse return rollupWorktreePath(cwd);
        if (self.memo.get(cwd)) |root| return root;

        const fallback = rollupWorktreePath(cwd);
        if (self.memo.count() >= max_memo_entries) return fallback;

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = self.resolveOnDisk(&buf, cwd) orelse fallback;
        return self.remember(allocator, cwd, resolved) orelse fallback;
    }

    /// Store an answer, returning the owned copy. Null on OOM — the caller
    /// falls back to the string rule, which needs no memory at all.
    fn remember(
        self: *Resolver,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        root: []const u8,
    ) ?[]const u8 {
        const key = allocator.dupe(u8, cwd) catch return null;
        const value = allocator.dupe(u8, root) catch {
            allocator.free(key);
            return null;
        };
        self.memo.put(allocator, key, value) catch {
            allocator.free(key);
            allocator.free(value);
            return null;
        };
        return value;
    }

    /// Walk up from `cwd` looking for a `.git` entry. A directory is a
    /// plain checkout and names its own root; a file is a linked worktree
    /// or a submodule and points at the admin dir that names the real one.
    ///
    /// Returns null when nothing on the way up is a repository — including
    /// when `cwd` itself is gone, which is the common case for historical
    /// transcripts and exactly what the string fallback is for.
    fn resolveOnDisk(self: *Resolver, out: []u8, cwd: []const u8) ?[]const u8 {
        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.io();
        var dir = std.Io.Dir.cwd();

        var candidate = trimTrailingSlashes(cwd);
        var depth: usize = 0;
        while (depth < max_walk_depth) : (depth += 1) {
            // A bare root is never a project, and neither is the empty
            // string. Stop before manufacturing "/" as a repo.
            if (candidate.len <= 1) return null;
            // Stop AT home without inspecting it: see `home`.
            if (self.home.len > 0 and std.mem.eql(u8, candidate, self.home)) return null;

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const git_path = std.fmt.bufPrint(&path_buf, "{s}/.git", .{candidate}) catch return null;
            if (dir.statFile(io, git_path, .{})) |stat| switch (stat.kind) {
                .directory => {
                    // The checkout that owns `.git` — copy it out, because
                    // `candidate` points into the caller's `cwd` and the
                    // contract says memo values are independently owned.
                    if (candidate.len > out.len) return null;
                    @memcpy(out[0..candidate.len], candidate);
                    return out[0..candidate.len];
                },
                .file => {
                    var text_buf: [max_git_file_bytes]u8 = undefined;
                    const text = dir.readFile(io, git_path, &text_buf) catch return null;
                    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
                    const git_dir = gitDirFromFile(&git_dir_buf, candidate, text) orelse return null;
                    const tree = workTreeFromGitDir(git_dir) orelse return null;
                    if (tree.len > out.len) return null;
                    @memcpy(out[0..tree.len], tree);
                    return out[0..tree.len];
                },
                else => return null,
            } else |_| {}

            candidate = std.fs.path.dirnamePosix(candidate) orelse return null;
        }
        return null;
    }
};

const testing = std.testing;

test "the string rule rolls a claude worktree up to its repository" {
    try testing.expectEqualStrings(
        "/Users/me/workspace/token-tach",
        rollupWorktreePath("/Users/me/workspace/token-tach/.claude/worktrees/toasty-floating-marshmallow"),
    );
    // A subdirectory inside the worktree rolls up the same way — the cut
    // is at the container, not at the leaf.
    try testing.expectEqualStrings(
        "/Users/me/workspace/token-tach",
        rollupWorktreePath("/Users/me/workspace/token-tach/.claude/worktrees/toasty/src/core"),
    );
    // Bare `.worktrees`, and a third-party tool's own hidden container.
    try testing.expectEqualStrings("/w/phux", rollupWorktreePath("/w/phux/.worktrees/pr-1"));
    try testing.expectEqualStrings("/w/phux-mobile", rollupWorktreePath("/w/phux-mobile/.phui/worktrees/pr-109"));
}

test "the string rule leaves ordinary paths alone" {
    // A project that owns a plain `worktrees/` source directory is NOT a
    // worktree container: the segment has to be hidden, or live in a
    // hidden directory, to count.
    try testing.expectEqualStrings(
        "/w/tool/worktrees/docs",
        rollupWorktreePath("/w/tool/worktrees/docs"),
    );
    try testing.expectEqualStrings("/w/token-tach", rollupWorktreePath("/w/token-tach"));
    try testing.expectEqualStrings("/w/token-tach", rollupWorktreePath("/w/token-tach/"));
    try testing.expectEqualStrings("/w/token-tach", rollupWorktreePath("/w/token-tach///"));
    try testing.expectEqualStrings("/", rollupWorktreePath("/"));
    try testing.expectEqualStrings("", rollupWorktreePath(""));
    try testing.expectEqualStrings("rel", rollupWorktreePath("rel"));
    // Nothing but a container: there is no root in the string to name, so
    // the input survives rather than becoming "".
    try testing.expectEqualStrings(".worktrees/x", rollupWorktreePath(".worktrees/x"));
    // The container with no worktree named after it is just a directory.
    try testing.expectEqualStrings("/w/phux/.worktrees", rollupWorktreePath("/w/phux/.worktrees"));
    try testing.expectEqualStrings("/w/phux/.worktrees", rollupWorktreePath("/w/phux/.worktrees/"));
    try testing.expectEqualStrings(
        "/w/phux/.claude/worktrees",
        rollupWorktreePath("/w/phux/.claude/worktrees"),
    );
}

test "a git admin path cuts at the first .git, so submodules resolve too" {
    try testing.expectEqualStrings(
        "/w/token-tach",
        workTreeFromGitDir("/w/token-tach/.git/worktrees/toasty").?,
    );
    // The case that rules out following `commondir`: a submodule inside a
    // worktree has a full repo as its admin dir and no commondir at all.
    try testing.expectEqualStrings(
        "/w/token-tach",
        workTreeFromGitDir("/w/token-tach/.git/worktrees/toasty/modules/vendor/native").?,
    );
    try testing.expectEqual(@as(?[]const u8, null), workTreeFromGitDir("/w/token-tach/.git"));
    try testing.expectEqual(@as(?[]const u8, null), workTreeFromGitDir("/.git/worktrees/x"));
}

test "a relative gitdir resolves against the file that holds it" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // Verbatim from this repo: vendor/native inside a worktree.
    const text = "gitdir: ../../../../../.git/worktrees/toasty/modules/vendor/native\n";
    const git_dir = gitDirFromFile(
        &buf,
        "/Users/me/workspace/token-tach/.claude/worktrees/toasty/vendor/native",
        text,
    ).?;
    try testing.expectEqualStrings(
        "/Users/me/workspace/token-tach/.git/worktrees/toasty/modules/vendor/native",
        git_dir,
    );
    try testing.expectEqualStrings("/Users/me/workspace/token-tach", workTreeFromGitDir(git_dir).?);
}

test "an absolute gitdir is taken as given" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const got = gitDirFromFile(&buf, "/anywhere", "gitdir: /w/token-tach/.git/worktrees/toasty\n").?;
    try testing.expectEqualStrings("/w/token-tach/.git/worktrees/toasty", got);
    // Not a gitdir pointer at all.
    try testing.expectEqual(@as(?[]const u8, null), gitDirFromFile(&buf, "/anywhere", "ref: refs/heads/main\n"));
    try testing.expectEqual(@as(?[]const u8, null), gitDirFromFile(&buf, "/anywhere", "gitdir:\n"));
}

test "lexical normalization resolves dots without touching the disk" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings("/a/b", normalizePosix(&buf, "/a/b/c/..").?);
    try testing.expectEqualStrings("/a", normalizePosix(&buf, "/a/./b/../").?);
    try testing.expectEqualStrings("/", normalizePosix(&buf, "/a/../..").?);
    try testing.expectEqualStrings("a/b", normalizePosix(&buf, "a/b/").?);
    try testing.expectEqual(@as(?[]const u8, null), normalizePosix(&buf, ""));
    // A relative path with nothing to pop keeps the `..`; dropping it
    // would change which directory the path names.
    try testing.expectEqualStrings("../a", normalizePosix(&buf, "../a").?);
}

test "the resolver finds the real repository root through a live worktree" {
    // Exercised against a real tree built in tmp, because the whole point
    // of the disk path is the answers a string cannot produce: the
    // worktree here is named nothing like its repository.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    try tmp.dir.createDirPath(io, "repo/.git/worktrees/wt");
    try tmp.dir.createDirPath(io, "repo/src");
    try tmp.dir.createDirPath(io, "elsewhere/unrelated-name/deep");

    var line_buf: [std.fs.max_path_bytes]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "gitdir: {s}/repo/.git/worktrees/wt\n", .{base});
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/unrelated-name/.git", .data = line });

    // HOME is pinned to the tmp root so the walk terminates there. Without
    // it these assertions depend on whether anything above /var/folders
    // happens to be a git repository.
    var resolver = Resolver.init(testing.allocator, base);
    defer resolver.deinit();

    var want_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo = try std.fmt.bufPrint(&want_buf, "{s}/repo", .{base});

    // A worktree whose basename shares nothing with the repository — the
    // sibling layout that defeats every string rule.
    var wt_buf: [std.fs.max_path_bytes]u8 = undefined;
    const wt = try std.fmt.bufPrint(&wt_buf, "{s}/elsewhere/unrelated-name", .{base});
    try testing.expectEqualStrings(repo, resolver.rootFor(wt));

    // A subdirectory of it walks up to the same answer.
    var deep_buf: [std.fs.max_path_bytes]u8 = undefined;
    const deep = try std.fmt.bufPrint(&deep_buf, "{s}/elsewhere/unrelated-name/deep", .{base});
    try testing.expectEqualStrings(repo, resolver.rootFor(deep));

    // And a plain subdirectory of the checkout itself resolves to the
    // checkout, not to "src".
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/repo/src", .{base});
    try testing.expectEqualStrings(repo, resolver.rootFor(src));
}

test "the walk stops at home, so unrelated projects under it stay distinct" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // A version-controlled home directory with an ordinary, non-repo
    // project inside it. Without the guard the project would resolve to
    // home and every sibling would merge into one row.
    try tmp.dir.createDirPath(io, "home/.git");
    try tmp.dir.createDirPath(io, "home/workspace/linear");

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buf, "{s}/home", .{base});
    var resolver = Resolver.init(testing.allocator, home);
    defer resolver.deinit();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fmt.bufPrint(&cwd_buf, "{s}/home/workspace/linear", .{base});

    // The assertion is "not home", not an exact path: the temp tree lives
    // under .zig-cache inside whatever checkout runs the suite, so when
    // that checkout is itself a worktree the string-rule fallback
    // legitimately answers with the outer repository. What must never
    // happen is the walk climbing INTO home and merging every unrelated
    // project under it into one row named after the account.
    try testing.expect(!std.mem.eql(u8, resolver.rootFor(cwd), home));
}

test "a cwd that no longer exists still rolls up, and memoizes once" {
    var resolver = Resolver.init(testing.allocator, "");
    defer resolver.deinit();

    // Nothing here is on disk. The string rule is the whole answer, which
    // is the case that dominates a cold-start replay of old transcripts.
    const dead = "/nonexistent-root-for-tests/phux/.claude/worktrees/drifting-frolicking-puppy";
    try testing.expectEqualStrings("/nonexistent-root-for-tests/phux", resolver.rootFor(dead));
    // Same answer on the second call, now off the memo.
    try testing.expectEqualStrings("/nonexistent-root-for-tests/phux", resolver.rootFor(dead));
    try testing.expectEqual(@as(usize, 1), resolver.memo.count());

    // An empty cwd has no project and must not become one.
    try testing.expectEqualStrings("", resolver.rootFor(""));
    try testing.expectEqual(@as(usize, 1), resolver.memo.count());
}
