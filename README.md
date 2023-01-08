## General notes

Redump cue files are in the format:

```
REM SINGLE-DENSITY AREA
FILE "Resident Evil 2 (USA) (Disc 1) (Track 1).bin" BINARY
TRACK 01 MODE1/2352
    INDEX 01 00:00:00
FILE "Resident Evil 2 (USA) (Disc 1) (Track 2).bin" BINARY
TRACK 02 AUDIO
    INDEX 00 00:00:00
    INDEX 01 00:02:00
REM HIGH-DENSITY AREA
FILE "Resident Evil 2 (USA) (Disc 1) (Track 3).bin" BINARY
TRACK 03 MODE1/2352
    INDEX 01 00:00:00
FILE "Resident Evil 2 (USA) (Disc 1) (Track 4).bin" BINARY
TRACK 04 AUDIO
    INDEX 00 00:00:00
    INDEX 01 00:02:00
FILE "Resident Evil 2 (USA) (Disc 1) (Track 5).bin" BINARY
TRACK 05 AUDIO
    INDEX 00 00:00:00
    INDEX 01 00:02:00
FILE "Resident Evil 2 (USA) (Disc 1) (Track 6).bin" BINARY
TRACK 06 MODE1/2352
    INDEX 00 00:00:00
    INDEX 01 00:03:00
```

GDI files are in the format:

```
6
1 0 4 2352 track1.bin 0
2 970 0 2352 track2.raw 0
3 45000 4 2352 track3.bin 0
4 166227 0 2352 track4.raw 0
5 166950 0 2352 track5.raw 0
6 171875 4 2352 track6.bin 0
```

This translates to:

```
total_tracks
track number | starting sector (bytes) | if MODE1 then 4, if AUDIO then 0 | bytes per sector | filename | always 0 (idk why)
...
```

* GDI .bin files
    * Track 3 is always a bin file containing a combination of filesystem layout information and game data.
    * The last track is always a bin file containing game data.
* GDI .raw files
    * Track 2 is always a raw file containing sound to be played at boot. Redump backups can have a padding of zeroes prior to any actual audio data.
    * All files between track 3 and track n-1 are raw files containing audio data.

## Implementation notes

* First track can simply be renamed track01.bin in all cases. Tracks 1 and 2 are normal CD format data. 
* bin/raw files must be named `trackXX.{bin,raw}`
* gdi file:
    * can be named anything for use with emulators
    * must be named `disc.gdi` for GDEMU. See https://gdemu.wordpress.com/details/gdemu-details/

## Resources

I found it difficult to obtain accurate information on the GD-ROM format.

* https://multimedia.cx/eggs/understanding-the-dreamcast-gd-rom-layout/ is best breakdown I could find.
* See `docs/gd-ws.pps` for Sega's presentation on the format.

## Thanks

* #zig-help on the Zig Discord
* Multimedia Mike from multimedia.cx
* @sirconan on github for his [JS gdi converter](https://github.com/sirconan/gdi-conversion)

## TODO

- [ ] Tests
    - [x] `getFileName`
    - [x] `countIndexFrames`
- [ ] CI running of tests
- [ ] CI building and releasing
- [ ] Verify the sector offset code is correct. I think games *work* without it being 100%, but I'd like it to be 100%
- [ ] Support for shrinking game size by removing padded zeroes