# Binary Page, WAL Frame, TOAST Overflow & Index Format Specification

This domain specification defines the exact on-disk and in-memory binary layouts implemented by **`Nhe_O.Transaction`**, **`Nhe_O.BTree`**, **`Nhe_O.Vector`**, and **`Nhe_O.KV`** (`BR-002`, `BR-004`, `BR-006`, `ADR-003`, `ADR-006`, `ADR-007`).

All multi-byte integer fields are encoded in deterministic **Big-Endian (network byte order)** and verified with **IEEE 802.3 CRC-32** (`Polynomial = 16#EDB8_8320#`) in 100% `pragma SPARK_Mode (On);`.

---

## 1. Write-Ahead Log Frame (`WAL_Frame_Buffer` — 4,120 Bytes)

Defined in `src/nhe_o-io.ads` (`WAL_Header_Size = 24`, `WAL_Frame_Size = 4120`, `Max_WAL_Frames = 4096`) and `src/nhe_o-transaction.ad[sb]`.

| Byte Offset (1-indexed) | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"NHEO"` (`16#4E#, 16#48#, 16#45#, 16#4F#`) |
| `5 .. 8` | 4 B | `Tx_Id` | `Valid_Tx_Id` (`1 .. 8192`, `Max_Tx_Id = Max_CLOG_Entries`) |
| `9 .. 12` | 4 B | `Page_Id` | Target 4KB page index (`Valid_Page_Id`, `0 .. 1_048_575`) |
| `13 .. 16` | 4 B | `CRC32` | IEEE 802.3 CRC-32 (`Compute_WAL_CRC32`) over `Tx_Id (4B)`, `Page_Id (4B)`, `Frame_Kind (1B)`, and `Page_Payload (4096B)` |
| `17` | 1 B | `Frame_Kind` | `0 = WAL_Frame_Data`, `1 = WAL_Frame_Commit`, `2 = WAL_Frame_KV` (`ADR-006`, `ADR-007`) |
| `18 .. 24` | 7 B | `Reserved` | Zero-filled (`0`, verified by `Verify_WAL_Frame`) |
| `25 .. 4120` | 4096 B | `Page_Payload` | Complete 4096-byte page image |

- **File-Size Alignment & `Max_WAL_Frames = 4096` Rule (`Read_Page`, `Write_Page`, `Append_WAL_Frame`, `Read_WAL_Frame`)**:
  - Every `.db` page read/write verifies via `Posix_Lseek (Fd, 0, SEEK_END)` that the file size is an exact multiple of `Page_Size` (`4096` bytes), and every `.wal` frame read/append verifies that the `.wal` file size is an exact multiple of `WAL_Frame_Size` (`4120` bytes) and holds at most `Max_WAL_Frames = 4096` frames. An unaligned or over-full file fails closed; only crash recovery (`Repair_WAL_Tail` / `Repair_DB_Tail`, below) may shorten a file.
  - `Append_WAL_Frame` writes at the frame-aligned end with positional `pwrite` + `fsync` (plus a directory `fsync` when the WAL was empty) and reports success only when the frame is durable. On failure it truncates the WAL back and `fsync`s again; that rollback is best effort, so a failed append means "decided by the next recovery". `Write_Page` likewise truncates a failed file extension back and `fsync`s the directory on the first page of an empty file.
- **NO-STEAL Staging & Commit Point Rule (`Write_TOAST_Chain`, `Ingest_Document`, `Delete_Document`, `Commit_Tx`, `ADR-006`, `ADR-009`)**:
  - Active transactions (`Tx_Active`) append `WAL_Frame_Data` frames to `.wal` without mutating `.db` in place.
  - `Commit_Tx` pre-scans the `.wal` (up to `Max_WAL_Scan_Frames = 4096`, every frame CRC32 + `"NHEO"` verified, duplicate or post-commit frames for `Ctx.Id` rejected) and appends the `WAL_Frame_Commit` barrier. **The durable barrier append is the commit point**: from then on `Commit_Tx` returns `Status_Ok` even if materializing the staged pages into `.db` fails, reporting `Flush_Pending = True` so the caller re-runs `Redo_WAL_Recovery` (`Nhe_O.RAG.Commit_RAG_Tx` does this in place).
- **Crash Repair Rule (`Repair_WAL_Tail`, `Repair_DB_Tail`, run first by every recovery)**:
  - Appends are sequential and durable, so a crash can only tear the **last** frame. `Repair_WAL_Tail` classifies the whole file before truncating anything: every complete frame must verify, except a final complete frame with nothing after it; a partial trailing frame is allowed after verified frames. A torn frame with no valid frame before it (a lone partial frame, or a lone bad complete frame) is accepted only when it can be a torn first append (`Is_Torn_First_Frame`): it starts with a whole 24-byte header that a valid frame could carry (`"NHEO"`, `Tx_Id` in `1 .. 8192`, `Page_Id <= 1_048_575`, kind `<= 2`, zero reserved bytes), or it is shorter than 24 bytes and a prefix of such a header, or it holds zero bytes up to the end of its first 4096-byte block (so a file of at most 4120 bytes whose first 4096 bytes are zero is emptied). `Append_WAL_Frame` writes the first frame of an empty WAL in two synced steps (its first 512-byte sector, then the whole frame), so a crash can tear a first frame only to a prefix of that sector or after its whole header, and these rules recognize every such tear, also in an interrupted checkpoint's `"<wal>.ckpt"`. The torn frame (partial, or bad final) is truncated away. Anything else (an invalid frame before the last, a bad frame followed by a partial one, foreign bytes, more than `4096` frames) fails closed with `Status_IO_Error` and leaves the file untouched. A missing WAL is not an error.
  - `Repair_DB_Tail` truncates a partial trailing `.db` page (a crash while extending the file); the following redo rebuilds it, because every page of `.db` is materialized from a committed WAL frame. It does not classify the file, so it must only see a database of this engine: `nhe_o_init_with_paths` first refuses (`NHE_O_STATUS_INVALID_ARG`, file untouched) an existing non-empty database file whose first `min (size, 4096)` bytes are not all zero, since page `0` is never written.
- **Commit-Order Recovery Rule (`Redo_WAL_Recovery`, `BR-002`, `ADR-009`)**:
  - **Pass 1 (Analysis)**: scans frames `0 .. Max_Frames - 1`, verifies `Verify_WAL_Frame`, and records each `WAL_Frame_Commit` (a second commit frame for the same transaction is corruption).
  - **Pass 2 (Redo, in commit order)**: for each commit frame in WAL order, replays the `WAL_Frame_Data` frames that transaction staged **before** its barrier, then the barrier's own page — exactly the order in which `Commit_Tx` materialized them. Data frames of uncommitted transactions and data frames appearing after their transaction's barrier (a reused id) are never replayed; `WAL_Frame_KV` frames are left to `Recover_KV_From_WAL`.
  - `Max_Seen_Tx` is the largest transaction id of any data or commit frame, committed or not: callers seed their next id above it so a crashed transaction's staged frames can never be committed by a reused id.
- **Checkpoint Rule (`Nhe_O.C_API.C_Checkpoint`, `ADR-011`)**: the WAL is compacted by writing `"<wal>.ckpt"` (created with `O_EXCL`) holding one slot-hinted `"KVMG"` SET frame per occupied KV slot (sequence numbers `1 ..`) followed by one `WAL_Frame_Commit` of transaction `1` carrying the frozen Page 1 (`Freeze_RAG_Engine`), then `rename(2)` over the live WAL and `fsync` of its directory. The rename is the commit point: a crash before it keeps the old WAL, a crash after it recovers from the new one, and both describe the same logical database. Transaction ids restart at `2` and KV sequence numbers after the snapshot.
- **TOAST Page Allocation Rule (`Find_TOAST_Range`, `ADR-019`)**: TOAST chains start at page `10` (page `0` is never written by the RAG engine and page `1` is the primary slotted page). Each chain of a new version takes the lowest run of free pages; reserved are the current and prior chains of every document, the chains the updated document keeps as its prior, the chains already chosen for the new version, and every page another still-active transaction staged (per-slot hull `Staged_First .. Staged_End - 1` of `Staged_Tx`, superseded versions included, because `Commit_Tx` and redo materialize every data frame a transaction staged). A transaction may reuse pages it staged itself, since its later frames overwrite them in WAL order.

---

## 2. Primary 4096-Byte Slotted Page (`Slotted_Page` — `"SLOT"`, 4,096 Bytes)

Defined in `src/nhe_o-transaction.ad[sb]` (`Encode_Slotted_Page` / `Decode_Slotted_Page`, `BR-006`, `ADR-006`).

| Byte Offset (1-indexed) | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"SLOT"` (`16#53#, 16#4C#, 16#4F#, 16#54#`) |
| `5 .. 8` | 4 B | `Page_Id` | `Valid_Page_Id` (`0 .. 1_048_575`) |
| `9 .. 12` | 4 B | `Slot_Count` | Active occupied tuple slots (`0 .. 16`, verified equal to count of `Occupied` slots by `Decode_Slotted_Page`) |
| `13 .. 14` | 2 B | `Free_Lower` | End of line pointer directory (`152 = 24 + 16 * 8`, verified on decode) |
| `15 .. 16` | 2 B | `Free_Upper` | `153 + Slot_Count * 240` (verified on decode; slots are indexed by document id, so occupied cells need not be contiguous and this is not where the last occupied cell ends) |
| `17 .. 20` | 4 B | `Page_LSN_Tx` | Last committing `Valid_Tx_Id` |
| `21 .. 24` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over the 4096-byte page with bytes `21 .. 24` zeroed |
| `25 .. 152` | 128 B | `Slot_Dir (1..16)` | Sixteen 8-byte line pointers (`Tuple_Offset: U32 = 153 + (Slot-1)*240`, `Occupied: U8`, `Inline_Len: U8`, `Reserved: U16 = 0`; an unoccupied slot has `Inline_Len = 0` and the canonical empty cell `Row_Id = 1`, `Xmin = 1`, `Xmax = 0`, `Related_Id = 0`, zero TOAST pointer and zero inline bytes; any other content, and `Row_Id = 0` in any slot, fails decoding) |
| `153 .. 3992` | 3840 B | `Tuples (1..16)` | Sixteen 240-byte tuple cells (`Row_Id: 4B`, `Xmin: 4B`, `Xmax: 4B`, `Related_Id: 4B`, `TOAST_Pointer: 16B`, `Inline_Data: 208B`) |
| `3993 .. 4096` | 104 B | `Reserved_Tail` | Zero-padded free space (`0`, verified by `Decode_Slotted_Page`) |

### 2.1 RAG Tuple `Inline_Data (1 .. 208)` Layout (`Build_RAG_Slotted_Page`, `BR-006`)
| Inline Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 16` | 16 B | `Vec_Toast_Ptr` | Inline 16-byte `TOAST_Pointer` to the `"VTS2"` (legacy `"VTST"`) up to 4096-D `Float32` vector TOAST chain |
| `17` | 1 B | `Summary_Len` | Inline byte length of `Summary_Text` (`0 .. 63`) |
| `18 .. 80` | 63 B | `Summary_Text` | Up to 63 inline fast-path bytes of document summary text (`17 + 1 .. 17 + Summary_Len`) |
| `81 .. 96` | 16 B | `Meta_Toast_Ptr` | Inline 16-byte `TOAST_Pointer` to the `"RMET"` extended summary (`> 63 B`) & JSONB metadata TOAST chain (zeroed when inline-only) |
| `97` | 1 B | `Meta_Count` | `0 .. 16` inline fast-path `JSONB_Document` fields |
| `98 .. 208` | 111 B | `Packed_JSONB` | Sequential `[Key_Len: 1B (1..64), Val_Len: 1B (0..108), Kind_Code: 1B, Key_Bytes, Val_Bytes]` inline fast-path entries |

---

## 3. Inline 16-Byte TOAST Pointer, 4096-Byte `"TOAS"` Page, `"VTS2"` Vector & `"RMET"` Metadata Payloads

Defined in `src/nhe_o-transaction.ad[sb]` (`Encode_TOAST_Pointer`, `Decode_TOAST_Pointer`, `Write_TOAST_Chain`, `Read_TOAST_Chain`, `BR-006`), `src/nhe_o-vector.ad[sb]` (`Encode_Vector_TOAST`, `Decode_Vector_TOAST`, `ADR-006`), and `src/nhe_o-rag.adb` (`Encode_Meta_TOAST`, `Decode_Meta_TOAST`, `ADR-006`).

### 3.1 16-Byte Inline `TOAST_Pointer`
| Byte Offset | Size | Field | Invariant |
|---|---|---|---|
| `1 .. 4` | 4 B | `Root_Overflow_Page` | `Valid_Page_Id` (`<= Max_Page_Id - Chunk_Count + 1`) |
| `5 .. 8` | 4 B | `Total_Byte_Length` | `1 .. 16_392` (`Max_TOAST_Payload_Bytes`, accommodating `8B` `"VTS2"` header + `4096 * 4B`) |
| `9 .. 12` | 4 B | `Chunk_Count` | `((Total_Byte_Length - 1) / 4080) + 1` (`1 .. 5`) |
| `13 .. 16` | 4 B | `Payload_CRC32` | IEEE 802.3 CRC-32 across all `1 .. Total_Byte_Length` bytes |

### 3.2 4096-Byte TOAST Overflow Page (`"TOAS"`)
| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"TOAS"` (`16#54#, 16#4F#, 16#41#, 16#53#`) |
| `5 .. 8` | 4 B | `Next_Page_Id` | Next contiguous overflow page ID (`Cur_Page_Id + 1` on non-terminal chunks, `0` on terminal chunk, verified by `Read_TOAST_Chain`) |
| `9 .. 12` | 4 B | `Chunk_Bytes` | Active payload bytes in this page (`4080` on non-terminal chunks, `1 .. 4080` on terminal chunk) |
| `13 .. 16` | 4 B | `Chunk_CRC32` | IEEE 802.3 CRC-32 over payload bytes `17 .. 16 + Chunk_Bytes` |
| `17 .. 4096` | 4080 B | `Chunk_Data` | Raw slice of oversized parent chunk, `"VTS2"` (legacy `"VTST"`) `Float32` vector, or `"RMET"` extended summary/JSONB metadata (trailing unused bytes `17 + Chunk_Bytes .. 4096` verified zeroed) |

### 3.3 Vector TOAST Payload (`"VTS2"`, legacy `"VTST"`; `Encode_Vector_TOAST`, `ADR-018`)
| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"VTS2"` (`16#56#, 16#54#, 16#53#, 16#32#`), written since `0.4`; legacy `"VTST"` (`16#56#, 16#54#, 16#53#, 16#54#`) is still decoded |
| `5 .. 8` | 4 B | `Dim` | Embedding dimension (`1 .. 4096`, 32-bit Big-Endian), must equal the engine dimension |
| `9 .. 8 + Dim*4` | `Dim * 4` B | `Elements (1..Dim)` | One 32-bit Big-Endian word per component (layout below) |

The payload length must be exactly `8 + 4 * Dim`; bytes past the length are not inspected. Every document's full embedding is stored this way at every dimension, and Stage-2 re-ranking reads it for every visible candidate.

- **`"VTS2"` words** are the IEEE 754 binary32 bit pattern of the component (`Bit 31 = Sign`, `Bits 23..30 = biased exponent`, `Bits 0..22 = fraction`), computed arithmetically by `Float_Bits` (zero is written as `+0.0`). Decoding (`Bits_Float`) is exact, subnormals included, and rejects infinities, NaNs and magnitudes above `1.0e6` (`Max_Component`).
- **Legacy `"VTST"` words** (written before `0.4`) are scaled decimals: `Bit 31 = Sign`, `Bits 27..30 = Exp_Code (0..15)`, `Bits 0..26 = Mantissa M (0 .. 10^8)`; decoding rejects `M > 10^8` and a code-0 word with the sign bit or a mantissa set, and caps magnitudes at `1.0e6`:

| `Exp_Code` | Encoded `|x|` range | Decoded value |
|---|---|---|
| `0` | `x = 0.0` | `0.0` |
| `1` | `(0, 1e-20]` | `M * 1e-28` |
| `2 .. 13` | `(10^(2c-24), 10^(2c-22)]` (e.g. `11`: `(1e-2, 1]`) | `M * 10^(2c-30)` |
| `14` | `(1e4, 1e5]` | `M * 1e-3` |
| `15` | `(1e5, 1e6]` | `M * 1e-2` |

A legacy word keeps about 7 significant digits (worst relative error about `5.9e-7` for `|x|` in `(1e-22, 1e6]`, degrading below `1e-22`; values below `5e-29` were stored as zero).

### 3.4 `"RMET"` Extended Summary & JSONB Metadata TOAST Payload (`Encode_Meta_TOAST`, `ADR-006`)
| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"RMET"` (`16#52#, 16#4D#, 16#45#, 16#54#`) |
| `5 .. 6` | 2 B | `Summary_Length` | Exact byte length of full `Summary_Text` (`0 .. 512`, 16-bit Big-Endian) |
| `7 .. 6 + Summary_Length` | `0 .. 512` B | `Summary_Bytes` | Full `Summary_Text` (`Bounded_Text.Data (1 .. Summary_Length)`) |
| `7 + Summary_Length` | 1 B | `Meta_Count` | Number of active `JSONB_Document` fields (`0 .. 16`) |
| `8 + Summary_Length .. Total` | Variable | `JSONB_Entries` | `Meta_Count` sequential entries: `[Key_Len: 1B (1..64), Val_Len_Hi: 1B, Val_Len_Lo: 1B (0..512), Kind_Code: 1B, Key_Bytes (1..Key_Len), Val_Bytes (1..Val_Len)]` |

---

## 4. B+Tree 4096-Byte Node Page (`"BTRE"`)

Defined in `src/nhe_o-btree.ad[sb]` (`Encode_Node_Page` / `Decode_Node_Page`).

| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"BTRE"` (`16#42#, 16#54#, 16#52#, 16#45#`) |
| `5` | 1 B | `Node_Kind` | `1 = Node_Leaf`, `2 = Node_Internal` |
| `6` | 1 B | `Num_Keys` | `0 .. 4` (`Max_Keys_Per_Node`; `>= 1` for `Node_Internal` and `>= 2` for non-root leaves `Page_Id > 1`) |
| `7` | 1 B | `Next_Leaf` | `0 .. 32` (`0` for internal nodes) |
| `8` | 1 B | `Reserved_Hdr` | Zero (`0`) |
| `9 .. 12` | 4 B | `Page_Id` | `Valid_Page_Id` |
| `13 .. 16` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over the 4096-byte page with bytes `13 .. 16` zeroed |
| `17 .. 96` | 80 B | `Key_Slots (1..4)` | Four 20-byte slots at `17 + 20 * (s - 1)` (`Key_Hi: 4B`, `Key_Lo: 4B`, `Target_Page: 4B`, `Target_Slot: 4B`, `TOAST_Root: 4B`). The 64-bit key `K` is stored as `U = K + 2^63 (mod 2^64)` (sign bit flipped), `Key_Hi = U >> 32`, `Key_Lo = U and 16#FFFF_FFFF#`, so byte order equals signed key order (`Integer_64'First` → `00000000 00000000`, `0` → `80000000 00000000`). Unused slots are encoded as key `0` with pointer `(0, 1, 0)`. |
| `97 .. 116` | 20 B | `Children (1..5)` | Five 4-byte `BTree_Node_Id` child links (`1 .. 32`) |
| `117 .. 4096` | 3980 B | `Reserved` | Zero-filled |

---

## 5. Durable KV 4096-Byte WAL Page (`"KVMG"`, `Q-004`, `BR-004`, `ADR-007`)

Defined in `src/nhe_o-kv.ad[sb]` (`Encode_KV_Wal_Page` / `Decode_KV_Wal_Page`).

| Byte Offset | Size | Field | Description |
|---|---|---|---|
| `1 .. 4` | 4 B | `Magic` | ASCII `"KVMG"` (`16#4B#, 16#56#, 16#4D#, 16#47#`) |
| `5` | 1 B | `Op_Code` | `1 = KV_Op_Set`, `2 = KV_Op_Del` |
| `6` | 1 B | `Has_TTL` | `1 = True`, `0 = False` (`0` required when `Op_Code = KV_Op_Del`) |
| `7` | 1 B | `Key_Length` | `1 .. 64` (`Max_Ident_Len`) |
| `8` | 1 B | `Slot_Hint` | `KV_Op_Set`: the store slot (`1 .. 64`) the SET landed in, so replay reproduces the run-time slot layout including silent LRU / expired-slot evictions; `0` = no hint (legacy frames, replayed by slot selection). `KV_Op_Del`: must be `0`. Values above `64` are rejected |
| `9 .. 12` | 4 B | `Val_Length` | `0 .. 512` (`Max_Text_Len`; `0` required when `Op_Code = KV_Op_Del`) |
| `13 .. 20` | 8 B | `Expires_At` | 64-bit `Epoch_Seconds` (`Hi: 4B`, `Lo: 4B`; `0` required when `Has_TTL = 0` and when `Op_Code = KV_Op_Del`) |
| `21 .. 28` | 8 B | `Last_Access` | 64-bit `Epoch_Seconds` (`Hi: 4B`, `Lo: 4B`; `0` required when `Op_Code = KV_Op_Del`) |
| `29 .. 32` | 4 B | `Page_CRC32` | IEEE 802.3 CRC-32 over the 4096-byte page with bytes `29 .. 32` zeroed |
| `33 .. 96` | 64 B | `Key_Data` | Raw `Bounded_Ident` bytes (`1 .. Key_Length`) |
| `97 .. 608` | 512 B | `Val_Data` | Raw `Bounded_Text` bytes (`1 .. Val_Length`) |
| `609 .. 4096` | 3488 B | `Reserved` | Zero-filled |
