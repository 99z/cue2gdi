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

test "writeFile" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_alloc = gpa.allocator();

    var tmp_in = testing.tmpDir(.{});
    defer tmp_in.cleanup();
    var tmp_file = try tmp_in.dir.createFile("input.bin", .{});
    defer tmp_file.close();

    try tmp_file.writer().print("Hello, world!\n", .{});

    var tmp_out = testing.tmpDir(.{});
    defer tmp_out.cleanup();

    const filename = "input.bin";
    const track_num = 1;
    const gap_offset = 0;
    const expected = "track1.bin";

    // Test 1: Check that the function correctly writes a data file
    var result_data = try writeFile(gpa_alloc, tmp_in.dir, tmp_out.dir, filename, track_num, false, gap_offset);
    try testing.expect(std.mem.eql(u8, result_data, expected));

    // Test 2: Check that the function correctly writes an audio file
    var result_audio = try writeFile(gpa_alloc, tmp_in.dir, tmp_out.dir, filename, track_num, true, gap_offset);
    try testing.expect(std.mem.eql(u8, result_audio, "track1.raw"));

    // Test 3: Check that the function correctly handles a gap offset
    var result_gap = try writeFile(gpa_alloc, tmp_in.dir, tmp_out.dir, filename, track_num, false, 10);
    try testing.expect(std.mem.eql(u8, result_gap, expected));

    // Test 4: Check that the function correctly handles a gap offset failure
    _ = writeFile(gpa_alloc, tmp_in.dir, tmp_out.dir, filename, track_num, false, 10) catch |err| {
        try testing.expect(err == error.BadBinFile);
    };
}

fn extractTrackData(line: []const u8) !CueTrack {
    var split_iter = std.mem.split(u8, line, " ");

    var cue_track = CueTrack{ .number = undefined, .mode = undefined, .indices = undefined };
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
    } else {
        // Only audio and data (mode1) tracks should be present in redump.org dumps
        return error.BadTrackType;
    }

    return cue_track;
}

test "extractTrackData" {
    // Test 1: Check that the function correctly extracts track data
    const line = "TRACK 01 MODE1/2352";
    var expected = CueTrack{
        .number = 1,
        .mode = .data,
        .indices = undefined,
    };
    var result = try extractTrackData(line);
    try testing.expect(result.number == expected.number);
    try testing.expect(result.mode == expected.mode);
    try testing.expect(result.indices.len == expected.indices.len);

    // Test 2: Check that the function correctly extracts audio track data
    const line_audio = "TRACK 01 AUDIO";
    expected = CueTrack{
        .number = 1,
        .mode = .audio,
        .indices = undefined,
    };
    result = try extractTrackData(line_audio);
    try testing.expect(result.number == expected.number);
    try testing.expect(result.mode == expected.mode);
    try testing.expect(result.indices.len == expected.indices.len);

    // Test 3: Check that the function correctly handles a bad track type
    const line_bad = "TRACK 01 MODE2/2352";
    _ = extractTrackData(line_bad) catch |err| {
        try testing.expect(err == error.BadTrackType);
    };
}

fn extractIndexData(line: []const u8) !?TrackOffset {
    var split_iter = std.mem.split(u8, line, " ");

    while (split_iter.next()) |item| {
        if (std.fmt.parseInt(u8, item, 10)) |_| {
            // Result of .next() here should be the MM:SS:FF timestamp string
            const track_time = split_iter.next();
            var track_split = std.mem.split(u8, track_time.?, ":");

            const time: [3]u8 = .{
                std.fmt.parseInt(u8, track_split.next() orelse "00", 10) catch 0,
                std.fmt.parseInt(u8, track_split.next() orelse "00", 10) catch 0,
                std.fmt.parseInt(u8, track_split.next() orelse "00", 10) catch 0,
            };

            return .{
                .minutes = time[0],
                .seconds = time[1],
                .frames = time[2],
            };
        } else |err| switch (err) {
            else => continue,
        }
    }

    return error.BadIndex;
}

test "extractIndexData" {
    // Test 1: Check that the function correctly extracts index data
    const line = "INDEX 01 01:02:03";
    var expected = TrackOffset{
        .minutes = 1,
        .seconds = 2,
        .frames = 3,
    };
    var result = try extractIndexData(line);
    try testing.expect(result.?.minutes == expected.minutes);
    try testing.expect(result.?.seconds == expected.seconds);
    try testing.expect(result.?.frames == expected.frames);

    // Test 2: Check that the function correctly handles a bad index
    const line_bad = "INDEX a 00:02:00";
    _ = extractIndexData(line_bad) catch |err| {
        try testing.expect(err == error.BadIndex);
    };
}

fn extractFileData(offset_list: std.MultiArrayList(TrackOffset), gpa_alloc: std.mem.Allocator, cue_track: CueTrack, current_rem: RemType, filename_buf: []const u8) !CueFile {
    var complete_cue_track = cue_track;
    complete_cue_track.indices = try offset_list.clone(gpa_alloc);

    return .{
        .rem_type = current_rem,
        // Causes a segfault if I simply do .file_name = filename_buf
        .file_name = try std.mem.Allocator.dupe(std.heap.page_allocator, u8, try getFileName(filename_buf)),
        .track = complete_cue_track,
    };
}

fn extractCueData(gpa_alloc: std.mem.Allocator, cue_reader: std.fs.File.Reader) anyerror!std.MultiArrayList(CueFile) {
    // Setup MultiArrayList of CueFile structs
    const CueFileList = std.MultiArrayList(CueFile);
    var cue_files = CueFileList{};

    defer cue_files.deinit(gpa_alloc);
    const TrackOffsetList = std.MultiArrayList(TrackOffset);
    var offset_list = TrackOffsetList{};
    defer offset_list.deinit(gpa_alloc);

    // Create allocator for reading file contents
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var cue_track: CueTrack = CueTrack{ .number = undefined, .mode = undefined, .indices = undefined };
    var current_rem = RemType.single_density;
    var filename_buf: []const u8 = &.{};
    var prev_line: []const u8 = &.{};
    var file_count: u8 = 0;

    var file_data: CueFile = undefined;

    while (true) {
        if (cue_reader.readUntilDelimiterAlloc(arena_alloc, '\n', 1024)) |line| {
            if (std.mem.indexOf(u8, line, "FILE") != null) {
                file_count += 1;
                if (file_count > 1) {
                    file_data = try extractFileData(offset_list, gpa_alloc, cue_track, current_rem, filename_buf);
                    try cue_files.append(gpa_alloc, file_data);
                }

                if (std.mem.indexOf(u8, prev_line, "HIGH-DENSITY") != null) {
                    current_rem = .high_density;
                } else if (std.mem.indexOf(u8, prev_line, "SINGLE-DENSITY") != null) {
                    current_rem = .single_density;
                }

                filename_buf = line;
                offset_list = TrackOffsetList{};
                cue_track = CueTrack{ .number = undefined, .mode = undefined, .indices = undefined };
            } else if (std.mem.indexOf(u8, line, "TRACK") != null) {
                cue_track = try extractTrackData(line);
            } else if (std.mem.indexOf(u8, line, "INDEX") != null) {
                if (try extractIndexData(line)) |offset| {
                    try offset_list.append(gpa_alloc, offset);
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
