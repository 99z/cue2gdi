const std = @import("std");

const RemType = enum { single_density, high_density };
const TrackMode = enum { data, audio };

const TrackOffset = struct { minutes: u8, seconds: u8, frames: u8 };

const CueTrack = struct {
    number: u8,
    mode: TrackMode,
    indices: std.MultiArrayList(TrackOffset),
};

const CueFile = struct {
    rem_type: RemType,
    file_name: []const u8,
    track: CueTrack,
};

inline fn getUTF8Size(char: u8) u3 {
    return std.unicode.utf8ByteSequenceLength(char) catch {
        return 1;
    };
}

fn getIndex(unicode: []const u8, index: usize) ?usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < unicode.len) {
        if (i == index) return j;
        i += getUTF8Size(unicode[i]);
        j += 1;
    }

    return null;
}

fn find(string: []const u8, literal: []const u8) ?usize {
    const index = std.mem.indexOf(u8, string[0..string.len], literal);
    if (index) |i| {
        return getIndex(string, i);
    }

    return null;
}

// TODO: Break this up
fn extractCueData(gpa_alloc: std.mem.Allocator, cue_reader: std.fs.File.Reader) anyerror!std.MultiArrayList(CueFile).Slice {
    // Setup MultiArrayList of CueFile structs
    const CueFileList = std.MultiArrayList(CueFile);
    var cue_files = CueFileList{};
    const TrackOffsetList = std.MultiArrayList(TrackOffset);
    var offset_list = TrackOffsetList{};
    defer cue_files.deinit(gpa_alloc);
    defer offset_list.deinit(gpa_alloc);

    // Create allocator for reading file contents
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // TODO: Remove undefined initialization
    var cue_track: CueTrack = undefined;
    var current_rem = RemType.single_density;
    var filename_buf: []const u8 = &.{};
    var prev_line: []const u8 = &.{};
    var file_count: u8 = 0;

    // Previously I was using `readUntilDelimeterOrEof`. I ran into a weird problem where the value of
    // prev_line was not what I expected. This reddit post helped: https://www.reddit.com/r/Zig/comments/r6b84d/i_implement_a_code_to_read_file_line_by_line_but/
    // Specifically: "You are reading into the beginning of buf in every iteration of the loop, and then add a slice of buf into your array list."
    while (true) {
        if (cue_reader.readUntilDelimiterAlloc(arena_alloc, '\n', 1024)) |line| {
            // Handle FILE information and REM information
            if (find(line, "FILE") != null) {
                file_count += 1;

                if (file_count > 1) {
                    cue_track.indices = try offset_list.clone(gpa_alloc);
                    try cue_files.append(gpa_alloc, .{
                        .rem_type = current_rem,
                        // Causes a segfault if I simply do .file_name = filename_buf
                        .file_name = try std.mem.Allocator.dupe(std.heap.page_allocator, u8, filename_buf),
                        .track = cue_track,
                    });

                    filename_buf = &.{};
                    offset_list = TrackOffsetList{};
                    // TODO: Removed undefined assignment
                    cue_track = undefined;
                }

                if (find(prev_line, "HIGH-DENSITY") != null) {
                    current_rem = .high_density;
                } else if (find(prev_line, "SINGLE-DENSITY") != null) {
                    current_rem = .single_density;
                }

                filename_buf = line;
            } else if (find(line, "TRACK") != null) {
                // Handle TRACK information
                var split_iter = std.mem.split(u8, line, " ");

                while (split_iter.next()) |item| {
                    if (std.fmt.parseInt(u8, item, 10)) |number| {
                        cue_track.number = number;
                    } else |err| switch (err) {
                        else => continue,
                    }
                }

                if (find(line, "AUDIO") != null) {
                    cue_track.mode = .audio;
                } else if (find(line, "MODE1") != null) {
                    cue_track.mode = .data;
                }
            } else if (find(line, "INDEX") != null) {
                var split_iter = std.mem.split(u8, line, " ");
                while (split_iter.next()) |item| {
                    if (std.fmt.parseInt(u8, item, 10)) {
                        // Result of .next() here should be the MM:SS:FF timestamp string
                        const track_time = split_iter.next();
                        var track_split = std.mem.split(u8, track_time.?, ":");

                        var time: [3]u8 = .{
                            std.fmt.parseInt(u8, track_split.next() orelse "00", 10) catch 0,
                            std.fmt.parseInt(u8, track_split.next() orelse "00", 10) catch 0,
                            std.fmt.parseInt(u8, track_split.next() orelse "00", 10) catch 0,
                        };

                        try offset_list.append(gpa_alloc, .{
                            .minutes = time[0],
                            .seconds = time[1],
                            .frames = time[2],
                        });
                    } else |err| switch (err) {
                        else => continue,
                    }
                }
            }

            prev_line = line;
        } else |err| switch (err) {
            else => {
                cue_track.indices = try offset_list.clone(gpa_alloc);

                try cue_files.append(gpa_alloc, .{
                    .rem_type = current_rem,
                    // Causes a segfault if I simply do .file_name = filename_buf
                    .file_name = try std.mem.Allocator.dupe(std.heap.page_allocator, u8, filename_buf),
                    .track = cue_track,
                });

                break;
            },
        }
    }

    return cue_files.toOwnedSlice();
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();

    const cue_file = try std.fs.cwd().openFile("./re2.cue", .{});
    defer cue_file.close();

    const cue_reader = cue_file.reader();

    var cue_files = try extractCueData(gpa_alloc, cue_reader);
    defer cue_files.deinit(gpa_alloc);

    for (cue_files.items(.track)) |track| {
        std.debug.print("{any}\n", .{track.indices});
    }
}
