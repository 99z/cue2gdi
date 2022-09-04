const std = @import("std");

const BLOCK_SIZE = 2352;
const FOUR_GiB = 4294967296;

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

fn getFileName(cue_line: []const u8) []const u8 {
    // Get index of first instance of "
    const index = std.mem.indexOfScalar(u8, cue_line, '"') orelse @panic("no name");

    // If we only have a single " at the end of the file line, it's invalid
    if (index + 1 >= cue_line.len) @panic("no closing quote");

    const rest = cue_line[index + 1 ..];
    const stop = std.mem.indexOfScalar(u8, rest, '"') orelse @panic("no stop");
    return rest[0..stop];
}

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

fn countIndexFrames(offset: TrackOffset) u32 {
    var total = offset.frames;
    total += (offset.seconds * 75);
    total += (offset.minutes * 60) * 75;

    return total;
}

fn writeFile(gpa: std.mem.Allocator, filename: []const u8, track_num: u8, is_audio: bool, gap_offset: u32) ![]const u8 {
    const out_dir = "gdi";
    const bin_file = try std.fs.cwd().openFile(filename, .{});
    defer bin_file.close();

    var filename_with_ext: []const u8 = try std.fmt.allocPrint(gpa, "track{any}.bin", .{track_num});

    if (gap_offset > 0) {
        bin_file.seekTo(gap_offset * BLOCK_SIZE) catch @panic("could not seek bin file");
    }

    std.fs.cwd().makeDir(out_dir) catch std.debug.print("{s} already exists; continuing\n", .{out_dir});
    const dir = try std.fs.cwd().openDir(out_dir, .{});

    if (is_audio) {
        filename_with_ext = try std.fmt.allocPrint(gpa, "track{any}.raw", .{track_num});
        try dir.writeFile(filename_with_ext, try bin_file.readToEndAlloc(gpa, FOUR_GiB));
    } else {
        try dir.writeFile(filename_with_ext, try bin_file.readToEndAlloc(gpa, FOUR_GiB));
    }

    return filename_with_ext;
}

// TODO: Break this up
fn extractCueData(gpa_alloc: std.mem.Allocator, cue_reader: std.fs.File.Reader) anyerror!std.MultiArrayList(CueFile) {
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
                        .file_name = try std.mem.Allocator.dupe(std.heap.page_allocator, u8, getFileName(filename_buf)),
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

                        const time: [3]u8 = .{
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
                    .file_name = try std.mem.Allocator.dupe(std.heap.page_allocator, u8, getFileName(filename_buf)),
                    .track = cue_track,
                });

                break;
            },
        }
    }

    return try cue_files.clone(gpa_alloc);
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();

    const cue_file = try std.fs.cwd().openFile("./Tokyo Xtreme Racer 2 (USA).cue", .{});
    defer cue_file.close();

    const gdi_file = try std.fs.cwd().createFile("test.gdi", .{});
    defer gdi_file.close();

    const cue_reader = cue_file.reader();

    var cue_files = try extractCueData(gpa_alloc, cue_reader);
    defer cue_files.deinit(gpa_alloc);

    try gdi_file.writer().print("{}\n", .{cue_files.len});

    var sector_total: usize = 0;
    var idx: u8 = 0;
    while (cue_files.len > idx) : (idx += 1) {
        const cue_data = cue_files.get(idx);
        if (cue_data.rem_type == .high_density and sector_total < 45000) {
            sector_total = 45000;
        }

        var file = try std.fs.cwd().openFile(cue_data.file_name, .{});
        const file_size = (try file.stat()).size;

        var sector_size: usize = 0;
        var gap_offset: u32 = 0;
        if (cue_data.track.indices.len == 1) {
            sector_size = file_size / BLOCK_SIZE;
        } else {
            gap_offset = countIndexFrames(cue_data.track.indices.get(1));
            sector_size = (file_size - (gap_offset * BLOCK_SIZE)) / BLOCK_SIZE;
            sector_total += gap_offset;
        }

        const filename_with_ext = try writeFile(gpa_alloc, cue_data.file_name, cue_data.track.number, if (cue_data.track.mode == .audio) true else false, gap_offset);

        const track_mode: u8 = if (cue_data.track.mode == .audio) 0 else 4;
        try gdi_file.writer().print("{} {} {} {} {s} 0\n", .{ idx + 1, sector_total, track_mode, BLOCK_SIZE, filename_with_ext });
        sector_total += sector_size;
    }
}
