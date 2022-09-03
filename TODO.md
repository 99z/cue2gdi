## General notes

* .bin files in Redump backups are identical to those in GDI backups.

* GDI files have the format:
```
    totalTracks
    track_idx | sector_amt | if MODE1 then 4, if AUDIO then 0 | block_size | filename | always 0(?)
    ...
```

* Handling `HIGH-DENSITY` areas:
```
    totalTracks
    track_idx | sector_amt | if MODE1 then 4, if AUDIO then 0 | block_size | filename | always 0(?)
    ...
```

## Implementation notes

* First track can simply be renamed track01.bin in all cases
* Multiple track sector offset handling:
```
    offset = (frame_amt + (seconds * 75) + (min * 60 * 75))
    e.g. 00:02:00 would result in a sector offset of 150
```
* sector_amt = filesize of current track / block size (always 2352 for DC games) or, if multiple tracks, sector_amt = (track size - (offset * block size)) / block size and add offset to current sector