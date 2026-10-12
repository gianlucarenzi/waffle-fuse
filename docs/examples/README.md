# Demo floppy images

Two small images to try waffle-fuse without a drive:

| Image | Disk | Contents |
|---|---|---|
| `WaffleDemo.adf` | Amiga 880K, FFS, volume *WaffleDemo* | `ReadMe.txt`, `Docs/`, `Pictures/`, `Data/`, `Music/` |
| `WAFFLEDOS.img` | PC 720K, FAT12, label *WAFFLEDOS* | the same files |

```bash
waffle-fuse --image docs/examples/WaffleDemo.adf --automount ~/Floppy   # Linux, macOS
waffle-fuse --image docs\examples\WaffleDemo.adf *                       # Windows
```

or open them with the tray app (double-click, *Open with*, or *Open image as virtual
disk…* on Windows). They are also used for the screenshots of the documentation.

`make-examples.sh` builds them with waffle-fuse itself: formatted, mounted, filled,
unmounted.

`Music/waffle.mod` is a 4-channel ProTracker module written from scratch by
`make-mod.py` (synthesized samples, no third-party music, GPL like the rest of the
project). Double-click it on the mounted floppy: there's a surprise.
