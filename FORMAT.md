# Diskette container formats

Portable multi-file disc containers used by **Diskette**. **Not encryption.**

There are two on-disk packagings for the same logical volume model (paths, files, CRC-32, classic media capacity):

| Packaging | Magic | Default | Efficiency |
|-----------|--------|---------|------------|
| **FLOP/2 binary** | `FLP2` | **Yes** | Raw payloads; optional zlib |
| **FLOP/1 text** | `FLOP/1` | Legacy | UTF-8 + base64 (~33% larger) |

Logical **used** capacity counts uncompressed file bytes (the “disc is full” limit).  
**On-disk** `.Floppy` size depends on packaging.

---

## FLOP/2 binary (default)

### Layout

All multi-byte integers are **big-endian**.

```
"FLP2"                 4 bytes magic
version                u8   (= 1)
flags                  u8   (bit0 = compression may be used)
label_len              u8
label                  label_len bytes UTF-8
media_len              u8
media                  media_len bytes (e.g. "3.5-hd-1.44m")
capacity               u32  (informational)
sector                 u16  (512)
created                u64  unix seconds
modified               u64  unix seconds
entry_count            u32
volume_crc             u32  digest of paths/sizes/file CRCs

// entry_count times:
path_len               u16
path                   path_len bytes UTF-8 (absolute, e.g. "/a/b.txt")
kind                   u8   (0 = file, 1 = directory)
mtime                  u64  unix seconds
logical_size           u32  uncompressed payload size (0 if dir)
crc32                  u32  CRC of uncompressed payload (0 if dir)
stored_size            u32  bytes following (0 if dir)
store_flags            u8   bit0 = zlib-compressed stored blob
[stored_size bytes]    raw or zlib payload (files only)
```

### Compression

When writing with compress enabled, each file is zlib-compressed (Apple `NSData` zlib).  
If the compressed blob is **not smaller** than raw, the file is stored raw (`store_flags = 0`).

CRC-32 is always over the **logical** (uncompressed) payload.

### Efficiency vs FLOP/1

For the same logical payload of size *N*:

| Packaging | Typical container size |
|-----------|-------------------------|
| FLOP/1 text + base64 | ≈ 1.33×*N* + headers + line breaks |
| FLOP/2 raw | ≈ *N* + small directory |
| FLOP/2 + zlib (text-like data) | often ≪ *N* |

---

## FLOP/1 text (legacy)

Inspectable UTF-8 map. Still **read** by Diskette 1.2+; **Save** defaults to FLOP/2 binary.

### Magic

First line:

```
FLOP/1
```

### Header

Key/value lines until a blank line (or the first `DIR` / `FILE` record):

| Key | Meaning |
|-----|---------|
| `label=` | Volume label (max 32 chars recommended) |
| `media=` | Media id (see table) |
| `capacity=` | Byte capacity (informational; media id is authoritative) |
| `sector=` | Sector size (always `512`) |
| `created=` | ISO-8601 |
| `modified=` | ISO-8601 |
| `files=` | File count (informational) |
| `dirs=` | Directory count excluding root (informational) |
| `used=` | Sum of file payload sizes |
| `volume_crc=` | CRC-32 of a digest of paths/sizes/file CRCs |

### Media ids

| `media=` | Form | Capacity (bytes) |
|----------|------|------------------:|
| `5.25-dd-360k` | 5.25″ DD | 368 640 |
| `5.25-hd-1.2m` | 5.25″ HD | 1 228 800 |
| `3.5-dd-720k` | 3.5″ DD | 737 280 |
| `3.5-hd-1.44m` | 3.5″ HD | 1 474 560 |
| `3.5-ed-2.88m` | 3.5″ ED | 2 949 120 |

Capacities match classic formatted geometry: tracks × sectors/track × 512 × sides.

### Directory body

#### Directories

```
DIR /path/to/folder <unix_mtime>
```

Paths always start with `/`. Spaces in paths are escaped as `\ `.

#### Files

```
FILE /path/to/file <size> <crc32_hex> <unix_mtime>
<base64 lines, 76 columns>
END
```

- `size` is the decoded byte length  
- `crc32` is zlib CRC-32 of the payload (8 lowercase hex digits)  
- Base64 may span multiple lines; ends at `END`

Root `/` is implicit and not written.

### Example

```
FLOP/1
label=Notes
media=3.5-hd-1.44m
capacity=1474560
sector=512
created=2026-08-10T12:00:00Z
modified=2026-08-10T12:05:00Z
files=1
dirs=0
used=13
volume_crc=a1b2c3d4

FILE /hello.txt 13 321a2b44 1691667900
SGVsbG8sIGZsb3BweSE=
END
```

---

## Integrity

1. Each file’s CRC must match the uncompressed payload.  
2. Total file bytes must not exceed media capacity when loading.  
3. **`volume_crc` is verified on load** (FLOP/2 always; FLOP/1 when the header field is present). Digest is a stable CRC-32 over sorted declared entries: `D:<path>` or `F:<path>:<size>:<crc8hex>`.  
4. FLOP/2 parser rejects: unknown entry kinds, unknown store/header flag bits, duplicate paths, path `/`, trailing bytes, directory records with payload fields, and files nested under a path already declared as a file.  
5. **Paths** use `/`-separated components. `Volume.join` sanitizes each component but keeps nested segments (so `join("/Root", "Film Hiss/a.txt")` → `/Root/Film Hiss/a.txt`).  
6. **Layout repair (opt-in, 1.5.7+ behavior):** a short-lived join bug wrote `D-rest` beside directory `D` instead of `D/rest`. **`--repair-layout`** and the UI **Repair Layout…** command apply a heuristic that moves such siblings. Open and extract **do not** rewrite paths (1.5.7+): a filename pattern alone is not safe provenance — e.g. legitimate `Reports-summary.txt` next to `Reports/` would also match.

## Damage recovery

The app does not include a forensic carver. The notes below describe what the format makes possible if a container is partially damaged.

### Directory metadata still readable

If the FLOP/1 or FLOP/2 directory remains intact enough to parse:

- Extraction is straightforward (`--extract` / browser **Extract…**).
- Per-file **CRC-32** shows exactly which payloads match; mismatches mean that file’s bytes are corrupt even if the path still appears.

### Damaged header / unreadable directory

If the volume header or entry table is damaged so the container no longer loads:

- **Uncompressed** stored blobs may sometimes be **carved** from the raw file using recognizable signatures, e.g. `%PDF`, TIFF `II*\0` / `MM\0*`, MP4 `ftyp`, ZIP `PK`.
- **Compressed** (zlib) records are harder: boundaries depend on the path, stored length, and compression flag in the directory — without that metadata, carving is unreliable.
- CRC-32 **detects** corruption; it **cannot repair** it.

### Span sets

- A damaged or missing `/.diskette-span/manifest.json` blocks normal **Restore Set…** (the set depends on matching manifests across discs).
- Internal numbered part paths under `/.diskette-span/parts/<fileKey>/<NNNN>.part` may still provide clues for manual reassembly if those blobs survive.
- Without recovery discs, a **missing data disc** cannot be reconstructed from the remaining discs alone.
- With optional recovery discs (see below): **1× XOR** rebuilds any one loss; **N× Reed–Solomon** rebuilds up to N losses.

### Not on individual data discs

Data discs do **not** embed parity inside themselves. Redundancy is only in the separate optional recovery volumes created at span time.

## Opening files from the disc (app)

Payload bytes are written to a read-only temp path under the system temporary directory (`DisketteOpen/<volume-id>/…`), then:

- **Open** → `NSWorkspace.shared.open` (default app for the type)
- **Quick Look** → `QLPreviewPanel` on the same temp URL(s)

Edits in external apps do **not** update the volume unless the user re-adds. Temp tree is removed on **Eject**.

## CLI mapping

| Command | Effect |
|---------|--------|
| `--create` | Empty volume → serialize (`--format binary\|text`, `--no-compress`) |
| `--add` | Load → insert host file/folder → save (keeps volume packaging prefs) |
| `--list` | Load → print paths |
| `--extract` | Load → write host file/tree |
| `--info` | Load → volume summary + on-disk / estimate sizes |
| `--repack` | Load → rewrite with chosen packaging |
| `--span … --with-recovery` / `--recovery-discs N` | Pack set + 1 XOR or N Reed–Solomon recovery discs |
| `--recover-disc` | Rebuild missing data disc(s) from recovery + survivors |

## Multi-disc span

Each member of a set is a normal `.Floppy` plus:

```
/.diskette-span/manifest.json
```

### DISKETTE-SPAN/2 (current — phase 2 chunking)

| Field | Meaning |
|-------|---------|
| `magic` | `DISKETTE-SPAN/2` |
| `setId` | UUID shared by all discs in the set |
| `setLabel` | Human label |
| `media` | Media id (same for all discs) |
| `index` / `count` | 1-based disc number / total discs |
| `rootName` | Top-level folder name on restore |
| `filesOnThisDisc` | Stored paths on this disc (files and/or chunk blobs) |
| `parts` | Array of part records (see below) |
| `totalFilesInSet` / `totalBytesInSet` | Logical inventory |
| `chunkedFileCount` | How many logical files were split |
| `created` | ISO-8601 |

#### `parts[]` entry

| Field | Meaning |
|-------|---------|
| `logicalPath` | Restored path, e.g. `/Root/video.mov` |
| `storedPath` | Path of this piece **on this disc** |
| `byteOffset` / `byteLength` | Slice within the original file |
| `totalSize` | Full original size |
| `partIndex` / `partCount` | 0-based index / total parts (`1` = whole file) |
| `fileCrc32` | CRC-32 of the complete original file |
| `partCrc32` | CRC-32 of this part’s bytes |

**Storage rules**

- Whole file (`partCount == 1`): stored at `logicalPath` (e.g. `/Root/a.txt`)  
- Chunked file: stored under `/.diskette-span/parts/<fileKey>/<NNNN>.part`  

**Packing:** sequential by path order. Fill remaining free space with the next file or a chunk; open a new disc when full. Usable capacity = media capacity − base manifest reserve − **per-part JSON estimate** (paths + fields). A fixed headroom alone is not enough when one disc holds hundreds of small files — the planner leaves room for a large `manifest.json`. Tiny leftover free space is skipped before starting a multi-disc file so chunks stay reasonable. **Streaming:** host files are CRC’d and sliced via `FileHandle` (not fully buffered as a set). A failed span deletes any discs already written in that run.

**Empty directories:** listed in `emptyDirectories` (every disc) and recreated on restore.

**Hidden files:** enumeration uses `.skipsHiddenFiles` — host dotfiles are not spanned. The span system folder `/.diskette-span` **is** part of the disc image and is **listed in the in-app browser**. The left panel shows a warning on span discs: do not delete or rename `.diskette-span` or Restore Set will fail.

**Restore:** load manifests first; reassemble each logical file by streaming parts (one disc cached) into a temp file; verify length + `fileCrc32`; atomically move into place. Sort parts by `partIndex`, then `byteOffset`. Requires a complete set (indices 1…count, same `setId`) and matching `rootName`, `media`, `setLabel`, `totalFilesInSet`, `totalBytesInSet` on every disc. **Duplicate disc indices are rejected.** Destination root: default **fail** if it already exists; CLI `--force` / `--skip-existing`. Host extract/unspan refuse paths that escape the chosen output directory (zip-slip guard).

### DISKETTE-SPAN/1 (legacy)

Whole files only; no `parts` array. Restore synthesizes a single part per `filesOnThisDisc` entry. Still readable.

Filenames: `Label-01of03.Floppy` (zero-padded).

### Optional recovery discs

Opt-in at span time (UI: recovery count; CLI `--with-recovery` / `--recovery-discs N`). Not created by default.

#### One recovery disc — XOR (`DISKETTE-SPAN-RECOVERY/1`)

```
Label-01of33.Floppy … Label-33of33.Floppy
Label-Recovery-01of01.Floppy
```

XOR of equal-sized blocks of the **raw on-disk** data `.Floppy` files (zero-padded to the longest):

\[
P = D_1 \oplus D_2 \oplus \cdots \oplus D_n
\]

Any **one** missing data disc: \(D_k = P \oplus \bigoplus_{i \neq k} D_i\).

#### N recovery discs — Cauchy Reed–Solomon (`DISKETTE-SPAN-RECOVERY/2`)

```
Label-01of33.Floppy … Label-33of33.Floppy
Label-Recovery-01of03.Floppy
Label-Recovery-02of03.Floppy
Label-Recovery-03of03.Floppy
```

For each byte offset, the n data symbols and m parity symbols form a systematic Cauchy RS codeword over **GF(256)** (AES polynomial 0x11d):

\[
P_j = \bigoplus_{i=1}^{n} C_{j,i}\cdot D_i
\quad\text{where}\quad
C_{j,i} = \frac{1}{x_i \oplus y_j}
\]

- Rebuilds **any m** missing data discs when the other data discs and enough recovery discs remain.
- Which discs were lost does not matter (up to m losses).
- More than m losses cannot be recovered this way.

**Paths on each recovery volume**

| Path | Content |
|------|---------|
| `/.diskette-span/recovery/manifest.json` | Recovery metadata |
| `/.diskette-span/recovery/parity.bin` | Parity block (length = max data-disc file size) |

**Manifest fields:** `magic`, `scheme` (`xor` \| `reed-solomon`), `setId`, `setLabel`, `media`, `discCount`, `recoveryCount`, `recoveryIndex`, `recoveryDiscFilenames[]`, `parityByteLength`, `dataDiscFilenames[]`, `dataDiscByteLengths[]`, `dataDiscCrc32[]`, `parityCrc32`, `allParityCrc32[]`, `created`.

Media for each recovery volume is the **smallest** classic capacity that fits parity + manifest. Parity is stored **without** zlib.

CLI: `--recover-disc ~/Discs -o ~/Discs` (folder of survivors + recovery discs).

## App version

| App | Notes |
|-----|--------|
| 1.0.0 | FLOP/1 text only |
| 1.1.0 | Open in default app + Quick Look |
| 1.2.0 | FLOP/2 binary default + zlib; FLOP/1 still readable |
| 1.2.1 | Save-result gating; volume_crc enforced; stricter FLP2 parser |
| 1.2.2 | Drive browser List selection fix (no cell tap gestures) |
| 1.3.0 | Whole-file multi-disc span + restore |
| 1.4.0 | Span phase 2: chunk oversized files across discs |
| 1.5.0 | Streaming span/restore; empty dirs; collision policy; set hardening |
| 1.5.1 | Drag and drop (window drop + drag-out handle) |
| 1.5.2 | Audit hardening: quit dirty prompt, zip-slip, UI performance |
| 1.5.3 | Show `/.diskette-span` in browser; left-panel span warning |
| 1.5.4 | Nested folder join fix; extract tree; repair-layout for flattened imports |
| 1.5.5 | Restore compressOnWrite from FLP2 header; avoid false dirty on open |
| 1.5.6 | Truncated Span complete disc list for large multi-disc sets |
| 1.5.7 | Layout repair opt-in only (no auto on open/extract); UI Repair Layout… |
| 1.5.8 | Span planner reserves per-part manifest space (dense small-file trees) |
| 1.5.9 | Optional XOR recovery disc; recover any one missing span data disc |
| 1.6.0 | Reed–Solomon recovery discs (multi-loss); recovery count UI/CLI |
