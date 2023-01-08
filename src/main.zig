const std = @import("std");
const testing = std.testing;
const clap = @import("clap");

const BLOCK_SIZE = 2352;
const FOUR_GiB = 4294967296;

const RemType = enum { single_density, high_density };
const TrackMode = enum { data, audio };

const TrackOffset = struct { minutes: u32, seconds: u32, frames: u32 };

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

fn getFileName(cue_line: []const u8) ![]const u8 {
    // Get index of first instance of "
    const index = std.mem.indexOfScalar(u8, cue_line, '"') orelse return error.NoDoubleQuote;

    // If we only have a single " at the end of the file line, it's invalid
    if (index + 1 >= cue_line.len) return error.NoClosingQuote;

    const rest = cue_line[index + 1 ..];
    const stop = std.mem.indexOfScalar(u8, rest, '"') orelse return error.NoClosingQuote;
    return rest[0..stop];
}

test "getFileName" {
    // FILE line is valid
    const valid_filename = try getFileName("FILE \"Resident Evil 2 (USA) (Disc 1) (Track 1).bin\" BINARY");
    try testing.expect(std.mem.eql(u8, valid_filename, "Resident Evil 2 (USA) (Disc 1) (Track 1).bin"));

    // FILE line does not have closing quote
    _ = getFileName("FILE Resident Evil 2 (USA) (Disc 1) (Track 1).bin\" BINARY") catch |err| {
        try testing.expect(err == error.NoClosingQuote);
    };

    // FILE line has single quote at end of line
    _ = getFileName("asdf.cue\"") catch |err| {
        try testing.expect(err == error.NoClosingQuote);
    };
}

fn countIndexFrames(offset: TrackOffset) u32 {
    var total = offset.frames;
    total += (offset.seconds * 75);
    total += (offset.minutes * 60) * 75;

    return total;
}

test "countIndexFrames" {
    // Test 2: Check that the function correctly handles multiple indices
    var offset = TrackOffset{
        .frames = 10,
        .seconds = 30,
        .minutes = 1,
    };
    const expected = (10 + (30 * 75) + (1 * 60 * 75));
    var result = countIndexFrames(offset);
    try testing.expect(result == expected);
}

fn writeFile(gpa: std.mem.Allocator, in_dir: std.fs.Dir, out_dir: std.fs.Dir, filename: []const u8, track_num: u8, is_audio: bool, gap_offset: u32) ![]const u8 {
    const bin_file = try in_dir.openFile(filename, .{});
    defer bin_file.close();

    var filename_with_ext: []const u8 = try std.fmt.allocPrint(gpa, "track{any}.bin", .{track_num});

    if (gap_offset > 0) {
        bin_file.seekTo(gap_offset * BLOCK_SIZE) catch return error.BadBinFile;
    }

    if (is_audio) {
        filename_with_ext = try std.fmt.allocPrint(gpa, "track{any}.raw", .{track_num});
        try out_dir.writeFile(filename_with_ext, try bin_file.readToEndAlloc(gpa, FOUR_GiB));
    } else {
        try out_dir.writeFile(filename_with_ext, try bin_file.readToEndAlloc(gpa, FOUR_GiB));
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
            if (std.mem.indexOf(u8, line, "FILE") != null) {
                file_count += 1;

                if (file_count > 1) {
                    cue_track.indices = try offset_list.clone(gpa_alloc);
                    try cue_files.append(gpa_alloc, .{
                        .rem_type = current_rem,
                        // Causes a segfault if I simply do .file_name = filename_buf
                        .file_name = try std.mem.Allocator.dupe(std.heap.page_allocator, u8, try getFileName(filename_buf)),
                        .track = cue_track,
                    });

                    filename_buf = &.{};
                    offset_list = TrackOffsetList{};
                    // TODO: Removed undefined assignment
                    cue_track = undefined;
                }

                if (std.mem.indexOf(u8, prev_line, "HIGH-DENSITY") != null) {
                    current_rem = .high_density;
                } else if (std.mem.indexOf(u8, prev_line, "SINGLE-DENSITY") != null) {
                    current_rem = .single_density;
                }

                filename_buf = line;
            } else if (std.mem.indexOf(u8, line, "TRACK") != null) {
                // Handle TRACK information
                var split_iter = std.mem.split(u8, line, " ");

                while (split_iter.next()) |item| {
                    if (std.fmt.parseInt(u8, item, 10)) |number| {
                        cue_track.number = number;
                    } else |err| switch (err) {
                        else => continue,
                    }
                }

                if (std.mem.indexOf(u8, line, "AUDIO") != null) {
                    cue_track.mode = .audio;
                } else if (std.mem.indexOf(u8, line, "MODE1") != null) {
                    cue_track.mode = .data;
                }
            } else if (std.mem.indexOf(u8, line, "INDEX") != null) {
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
                    .file_name = try std.mem.Allocator.dupe(std.heap.page_allocator, u8, try getFileName(filename_buf)),
                    .track = cue_track,
                });

                break;
            },
        }
    }

    return try cue_files.clone(gpa_alloc);
}

pub fn main() anyerror!void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help and exit.
        \\-i, --input <str>  Path to a Redump cue file. Must be in the same directory as the corresponding bin files.
        \\-o, --output <str>    Path to output directory. Defaults to a "gdi" folder in the path as input.
    );

    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{}) catch |err| {
        return err;
    };
    defer res.deinit();

    if (res.args.help)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    if (res.args.input == null)
        return clap.usage(std.io.getStdErr().writer(), clap.Help, &params);

    // Create allocator used throughout execution
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();

    // Open cue file and get containing folder
    const cue_file = try std.fs.openFileAbsolute(res.args.input.?, .{});
    defer cue_file.close();

    // Create output directory and open gdi file to write to
    const redump_dir = try std.fs.openDirAbsolute(std.fs.path.dirname(res.args.input.?).?, .{});
    const gdi_dir = try redump_dir.makeOpenPath(res.args.output orelse "gdi", .{});
    const gdi_file = try gdi_dir.createFile("disc.gdi", .{});
    defer gdi_file.close();

    const cue_reader = cue_file.reader();

    var cue_files = extractCueData(gpa_alloc, cue_reader) catch |err| {
        std.debug.print("Failed to extract data from cuesheet with error: {any}\nIs cuesheet malformed?\n", .{err});
        std.os.exit(1);
    };
    defer cue_files.deinit(gpa_alloc);

    try gdi_file.writer().print("{}\n", .{cue_files.len});

    var sector_total: usize = 0;
    var idx: u8 = 0;
    while (cue_files.len > idx) : (idx += 1) {
        const cue_data = cue_files.get(idx);
        if (cue_data.rem_type == .high_density and sector_total < 45000) {
            sector_total = 45000;
        }

        var file = try redump_dir.openFile(cue_data.file_name, .{});
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

        const filename_with_ext = writeFile(gpa_alloc, redump_dir, gdi_dir, cue_data.file_name, cue_data.track.number, if (cue_data.track.mode == .audio) true else false, gap_offset) catch |err| {
            std.debug.print("Failed to write file {s} with error: {any}\nIs bin/cue data corrupt?\n", .{ cue_data.file_name, err });
            std.os.exit(1);
        };

        const track_mode: u8 = if (cue_data.track.mode == .audio) 0 else 4;
        try gdi_file.writer().print("{} {} {} {} {s} 0\n", .{ idx + 1, sector_total, track_mode, BLOCK_SIZE, filename_with_ext });
        sector_total += sector_size;
    }
}
