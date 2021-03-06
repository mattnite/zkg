const std = @import("std");
const version = @import("version");
const zfetch = @import("zfetch");
const http = @import("hzzp");
const tar = @import("tar");
const zzz = @import("zzz");
const uri = @import("uri");
const Dependency = @import("Dependency.zig");
usingnamespace @import("common.zig");

const Allocator = std.mem.Allocator;
pub const default_repo = "astrolabe.pm";

// TODO: clean up duplicated code in this file

pub fn getLatest(
    allocator: *Allocator,
    repository: []const u8,
    user: []const u8,
    package: []const u8,
    range: ?version.Range,
) !version.Semver {
    const url = if (range) |r|
        try std.fmt.allocPrint(allocator, "https://{s}/pkgs/{s}/{s}/latest?v={}", .{
            repository,
            user,
            package,
            r,
        })
    else
        try std.fmt.allocPrint(allocator, "https://{s}/pkgs/{s}/{s}/latest", .{
            repository,
            user,
            package,
        });
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    const link = try uri.parse(url);
    var ip_buf: [80]u8 = undefined;
    var stream = std.io.fixedBufferStream(&ip_buf);

    try headers.set("Accept", "*/*");
    try headers.set("User-Agent", "gyro");
    try headers.set("Host", link.host orelse return error.NoHost);

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try req.commit(.GET, headers, null);
    try req.fulfill();

    switch (req.status.code) {
        200 => {},
        404 => {
            if (range) |r| {
                std.log.err("failed to find {} for {s}/{s} on {s}", .{
                    r,
                    user,
                    package,
                    repository,
                });
            } else {
                std.log.err("failed to find latest for {s}/{s} on {s}", .{
                    user,
                    package,
                    repository,
                });
            }

            return error.Explained;
        },
        else => |code| {
            std.log.err("got http status code {} for {s}", .{ code, url });
            return error.FailedRequest;
        },
    }

    var buf: [10]u8 = undefined;
    return version.Semver.parse(buf[0..try req.reader().readAll(&buf)]);
}

pub fn getHeadCommit(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
    ref: []const u8,
) ![]const u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        // TODO: fix api call once Http redirects are handled
        //"https://api.github.com/repos/{s}/{s}/tarball/{s}",
        "https://codeload.github.com/{s}/{s}/legacy.tar.gz/{s}",
        .{
            user,
            repo,
            ref,
        },
    );
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try headers.set("Host", "codeload.github.com");
    try headers.set("Accept", "*/*");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code for {s}: {}", .{ url, req.status.code });
        return error.FailedRequest;
    }

    var gzip = try std.compress.gzip.gzipStream(allocator, req.reader());
    defer gzip.deinit();

    var pax_header = try tar.PaxHeaderMap.init(allocator, gzip.reader());
    defer pax_header.deinit();

    return allocator.dupe(u8, pax_header.get("comment") orelse return error.MissingCommitKey);
}

pub fn getPkg(
    allocator: *Allocator,
    repository: []const u8,
    user: []const u8,
    package: []const u8,
    semver: version.Semver,
    dir: std.fs.Dir,
) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://{s}/archive/{s}/{s}/{}",
        .{
            repository,
            user,
            package,
            semver,
        },
    );
    defer allocator.free(url);

    try getTarGz(allocator, url, dir);
}

fn getTarGzImpl(
    allocator: *Allocator,
    url: []const u8,
    dir: std.fs.Dir,
    skip_depth: usize,
) !void {
    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    std.log.info("fetching tarball: {s}", .{url});
    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    const link = try uri.parse(url);
    try headers.set("Host", link.host orelse return error.NoHost);
    try headers.set("Accept", "*/*");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code for {s}: {}", .{ url, req.status.code });
        return error.FailedRequest;
    }

    var gzip = try std.compress.gzip.gzipStream(allocator, req.reader());
    defer gzip.deinit();

    try tar.instantiate(allocator, dir, gzip.reader(), skip_depth);
}

pub fn getTarGz(
    allocator: *Allocator,
    url: []const u8,
    dir: std.fs.Dir,
) !void {
    try getTarGzImpl(allocator, url, dir, 0);
}

pub fn getGithubTarGz(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
    commit: []const u8,
    dir: std.fs.Dir,
) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        // TODO: fix api call once Http redirects are handled
        //"https://api.github.com/repos/{s}/{s}/tarball/{s}",
        "https://codeload.github.com/{s}/{s}/legacy.tar.gz/{s}",
        .{
            user,
            repo,
            commit,
        },
    );
    defer allocator.free(url);

    try getTarGzImpl(allocator, url, dir, 1);
}

pub fn getGithubRepo(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
) !std.json.ValueTree {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}",
        .{ user, repo },
    );
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try headers.set("Host", "api.github.com");
    try headers.set("Accept", "application/vnd.github.v3+json");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    var text = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(text);

    if (req.status.code != 200) {
        std.log.err("got http status code: {}\n{s}", .{ req.status.code, text });
        return error.Explained;
    }

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    return try parser.parse(text);
}

pub fn getGithubTopics(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
) !std.json.ValueTree {
    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/topics", .{ user, repo });
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try headers.set("Host", "api.github.com");
    try headers.set("Accept", "application/vnd.github.mercy-preview+json");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code {s}: {}", .{ url, req.status.code });
        return error.Explained;
    }

    var text = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(text);

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    return try parser.parse(text);
}

pub fn getGithubGyroFile(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
    commit: []const u8,
) !?[]const u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        // TODO: fix api call once Http redirects are handled
        //"https://api.github.com/repos/{s}/{s}/tarball/{s}",
        "https://codeload.github.com/{s}/{s}/legacy.tar.gz/{s}",
        .{
            user,
            repo,
            commit,
        },
    );
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    std.log.info("fetching tarball: {s}", .{url});
    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    const link = try uri.parse(url);
    try headers.set("Host", link.host orelse return error.NoHost);
    try headers.set("Accept", "*/*");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code for {s}: {}", .{ url, req.status.code });
        return error.FailedRequest;
    }

    const subpath = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}/gyro.zzz", .{user, repo, commit[0..7]});
    defer allocator.free(subpath);

    var gzip = try std.compress.gzip.gzipStream(allocator, req.reader());
    defer gzip.deinit();

    var extractor = tar.fileExtractor(subpath, gzip.reader());
    return extractor.reader().readAllAlloc(allocator, std.math.maxInt(usize)) catch |err|
        return if (err == error.FileNotFound) null else err;
}
