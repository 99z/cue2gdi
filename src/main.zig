const std = @import("std");

const RemType = enum { single_density, high_density };
const TrackMode = enum { data, audio };

const TrackOffset = struct { minutes: u8, seconds: u8, frames: u8 };

const CueTrack = struct {
    number: u8,
    mode: TrackMode,
    indices: []TrackOffset,
};

const CueFile = struct {
    rem_type: RemType,
    file_name: []const u8,
    // track: CueTrack,
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

fn extractCueData(gpa_alloc: std.mem.Allocator, cue_reader: std.fs.File.Reader) anyerror!std.MultiArrayList(CueFile).Slice {
    // Setup MultiArrayList of CueFile structs
    const CueFileList = std.MultiArrayList(CueFile);
    var cue_files = CueFileList{};
    defer cue_files.deinit(gpa_alloc);

    // Create allocator for reading file contents
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var new_file = false;
    var current_rem = RemType.single_density;
    var filename_buf: []const u8 = undefined;
    var prev_line: []const u8 = undefined;

    // Previously I was using `readUntilDelimeterOrEof`. I ran into a weird problem where the value of
    // prev_line was not what I expected. This reddit post helped: https://www.reddit.com/r/Zig/comments/r6b84d/i_implement_a_code_to_read_file_line_by_line_but/
    // Specifically: "You are reading into the beginning of buf in every iteration of the loop, and then add a slice of buf into your array list."
    while (try cue_reader.readUntilDelimiterOrEofAlloc(arena_alloc, '\n', 1024)) |line| {
        if (find(line, "FILE") != null) {
            if (find(prev_line, "HIGH-DENSITY") != null) {
                current_rem = .high_density;
            } else if (find(prev_line, "SINGLE-DENSITY") != null) {
                current_rem = .single_density;
            }

            new_file = true;
            filename_buf = line;
        }

        if (new_file == true) {
            try cue_files.append(gpa_alloc, .{
                .rem_type = current_rem,
                // Causes a segfault if I simply do .file_name = filename_buf
                .file_name = try std.mem.Allocator.dupe(std.heap.page_allocator, u8, filename_buf),
            });

            filename_buf = undefined;
            new_file = false;
        }

        prev_line = line;
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

    std.debug.print("{any}\n", .{cue_files});

    for (cue_files.items(.file_name)) |file, index| {
        std.debug.print("{any}\n", .{index});
        std.debug.print("{s}\n", .{file});
    }
}
