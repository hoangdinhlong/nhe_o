#!/usr/bin/env python3
"""
nhe_o.py — Python ctypes SDK for the Formally Verified Nhé O Engine

Wraps the 100% SPARK 2022 C ABI (`Nhe_O.C_API` / `include/nhe_o.h`) so Python
local LLM pipelines (e.g., Qwen 3.8 RAG agents, llama-cpp-python, LangChain)
can invoke PostgreSQL SQL analysis, pgvector distance & quantization (up to
4096-D), Redis KV cache with TTL/LRU, Durable WAL Pub/Sub, and Universal
Hybrid RAG directly.

Runtime model: `libnhe_o.so` drives ONE process-wide engine. This module
therefore allows a single open `NheOEngine` per process (close() it, or use it
as a context manager, before opening another) and serializes every call
through a process-wide lock, so the engine is safe to share between threads.
Each call needs about 256 KiB of thread stack; call it from threads with at least
1 MiB (the default on Linux and for the main thread; see include/nhe_o.h).

One process per database: the library locks the database and WAL files it opens, so
opening files that another process holds fails with NheOError (STATUS_IO_ERROR). A
forked child does not inherit the parent's engine: this module closes the child's
copy right after fork() (os.register_at_fork) without touching the parent's files,
and the child may then open a database of its own.

KV methods take `now_sec`, the Unix time of the operation (the engine has no clock of
its own); when it is omitted the current time is used. Timestamps should never
decrease. Integer arguments outside their C range raise ValueError instead of
wrapping silently.

Text is UTF-8. Bytes that are not valid UTF-8 (a value stored by a C client, say)
come back as surrogate escapes (PEP 383, errors="surrogateescape") and are written
back unchanged, so binary KV values and Pub/Sub payloads round-trip.
"""

from __future__ import annotations

import ctypes
import math
import os
import shutil
import tempfile
import threading
import time
from ctypes import POINTER, byref, c_char, c_float, c_int, c_int64
from pathlib import Path
from typing import Any, Sequence

MAX_IDENT_LEN = 64
MAX_TEXT_LEN = 512
MAX_TOAST_BYTES = 16392
MAX_VECTOR_DIM = 4096
MAX_COMPONENT = 1.0e6
MIN_DOC_ID = 1
MAX_DOC_ID = 16
MAX_RAG_DOCS = 16
MAX_TX_ID = 8192
MAX_CLOG_ENTRIES = 8192
MAX_WAL_FRAMES = 4096
MAX_KV_KEYS = 64
MAX_SUBSCRIBERS = 16
MIN_TOP_K = 1
MAX_TOP_K = 8
MAX_PATH_LEN = 512
MAX_WAL_PATH_LEN = 507
CHECKPOINT_WAL_FRAMES = 512
CHECKPOINT_TX_ID = 4096
WAL_FRAME_SIZE = 4120

STATUS_OK = 0
STATUS_NOT_FOUND = 1
STATUS_EXPIRED = 2
STATUS_INVALID_SYNTAX = 3
STATUS_TYPE_MISMATCH = 4
STATUS_DIMENSION_MISMATCH = 5
STATUS_CAPACITY_EXCEEDED = 6
STATUS_TX_ABORTED = 7
STATUS_IO_ERROR = 8
STATUS_INVALID_ARG = 9
STATUS_NOT_INITIALIZED = 10

# SQL statement kinds reported by analyze_sql()["stmt_kind"] (Nhe_O.SQL.SQL_Statement_Kind)
STMT_UNKNOWN = 0
STMT_CREATE_TABLE = 1
STMT_INSERT = 2
STMT_SELECT = 3
STMT_UPDATE = 4
STMT_DELETE = 5
STMT_BEGIN = 6
STMT_COMMIT = 7
STMT_ROLLBACK = 8
STMT_LISTEN = 9
STMT_NOTIFY = 10

ENCODING_FLOAT32 = 0
ENCODING_INT8_SQ8 = 1
ENCODING_BINARY_1BIT = 2

IdentBuffer = c_char * MAX_IDENT_LEN
TextBuffer = c_char * MAX_TEXT_LEN
ToastBuffer = c_char * MAX_TOAST_BYTES
VectorBuffer = c_float * MAX_VECTOR_DIM

# Serializes every call into the library: its C runtime state is process-wide
_ENGINE_LOCK = threading.RLock()
_open_engine: NheOEngine | None = None


# Signals whose handlers the GNAT run time replaces when the library is initialized
_RUNTIME_SIGNALS = ("SIGSEGV", "SIGBUS", "SIGFPE", "SIGILL", "SIGABRT")


def _load_library(lib_path: str) -> ctypes.CDLL:
    """Load libnhe_o, keeping the interpreter's handlers for _RUNTIME_SIGNALS.

    Initializing the library installs GNAT run-time handlers for these signals (see
    include/nhe_o.h), which would replace the interpreter's own, faulthandler's for
    instance. Their previous dispositions are saved and restored with sigaction(2),
    the struct being treated as an opaque buffer.
    """
    import signal

    try:
        sigaction = ctypes.CDLL(None).sigaction
    except (OSError, AttributeError):
        return ctypes.CDLL(lib_path)
    saved = []
    for name in _RUNTIME_SIGNALS:
        signum = getattr(signal, name, None)
        if signum is None:
            continue
        old_action = ctypes.create_string_buffer(512)  # larger than any struct sigaction
        if sigaction(int(signum), None, old_action) == 0:
            saved.append((int(signum), old_action))
    lib = ctypes.CDLL(lib_path)
    for signum, old_action in saved:
        sigaction(signum, old_action, None)
    return lib


def _after_fork_in_child() -> None:
    """Drop the engine a forked child inherited, without touching the parent's files.

    The child inherits the library state and the descriptors that hold the parent's
    file locks. nhe_o_close in the child only releases those copies (the library sees
    that another process opened the engine: no checkpoint, no file removed), so the
    parent can still reopen its database while the child runs.
    """
    global _ENGINE_LOCK, _open_engine
    # Another thread of the parent may have held the lock at fork() time
    _ENGINE_LOCK = threading.RLock()
    engine = _open_engine
    _open_engine = None
    if engine is not None:
        engine._scratch_dir = None  # the parent's directory: never removed by the child
        if not engine._closed:
            engine._closed = True
            status = c_int(0)
            engine._lib.nhe_o_close(byref(status))


if hasattr(os, "register_at_fork"):
    os.register_at_fork(after_in_child=_after_fork_in_child)


class NheOError(RuntimeError):
    """A C ABI call returned a non-OK status (`status` holds the NHE_O_STATUS_* code)."""

    def __init__(self, call: str, status: int) -> None:
        super().__init__(f"{call} failed with status {status}")
        self.call = call
        self.status = status


def _make_ident_buf(text: str) -> tuple[IdentBuffer, int]:
    raw = text.encode("utf-8", "surrogateescape")
    if len(raw) == 0 or len(raw) > MAX_IDENT_LEN:
        raise ValueError(f"Identifier length must be in 1..{MAX_IDENT_LEN} bytes")
    buf = IdentBuffer()
    buf[: len(raw)] = raw
    return buf, len(raw)


def _make_text_buf(text: str) -> tuple[TextBuffer, int]:
    raw = text.encode("utf-8", "surrogateescape")
    if len(raw) > MAX_TEXT_LEN:
        raise ValueError(f"Text exceeds {MAX_TEXT_LEN} bytes")
    buf = TextBuffer()
    buf[: len(raw)] = raw
    return buf, len(raw)


def _make_toast_buf(text: str) -> tuple[ToastBuffer, int]:
    raw = text.encode("utf-8", "surrogateescape")
    if len(raw) > MAX_TOAST_BYTES:
        raise ValueError(f"TOAST payload exceeds {MAX_TOAST_BYTES} bytes")
    buf = ToastBuffer()
    buf[: len(raw)] = raw
    return buf, len(raw)


_INT64_MIN = -(2**63)
_INT64_MAX = 2**63 - 1
_INT32_MIN = -(2**31)
_INT32_MAX = 2**31 - 1


def _i64(val: int, name: str) -> c_int64:
    """Range-checked int64 argument (ctypes would silently wrap out-of-range ints)."""
    if isinstance(val, bool) or not isinstance(val, int):
        raise TypeError(f"{name} must be an int")
    if not _INT64_MIN <= val <= _INT64_MAX:
        raise ValueError(f"{name} {val} is outside the int64 range")
    return c_int64(val)


def _i32(val: int, name: str) -> c_int:
    """Range-checked C int argument (ctypes would silently wrap out-of-range ints)."""
    if isinstance(val, bool) or not isinstance(val, int):
        raise TypeError(f"{name} must be an int")
    if not _INT32_MIN <= val <= _INT32_MAX:
        raise ValueError(f"{name} {val} is outside the C int range")
    return c_int(val)


def _now(now_sec: int | None) -> c_int64:
    """The KV clock: the caller's timestamp, or the current Unix time when None."""
    return _i64(int(time.time()) if now_sec is None else now_sec, "now_sec")


def _validate_float(val: float) -> float:
    fval = float(val)
    if not math.isfinite(fval) or abs(fval) > MAX_COMPONENT:
        raise ValueError(f"Vector component {val} must be finite and within [-1e6, 1e6]")
    return fval


def _make_vec_buf(vec: Sequence[float]) -> tuple[VectorBuffer, int]:
    dim = len(vec)
    if dim < 1 or dim > MAX_VECTOR_DIM:
        raise ValueError(f"Vector dimension {dim} must be in 1..{MAX_VECTOR_DIM}")
    buf = VectorBuffer()
    for i, x in enumerate(vec):
        buf[i] = _validate_float(x)
    return buf, dim


class NheOEngine:
    """Python ctypes binding to `libnhe_o.so` (`Nhe_O.C_API`).

    Only one engine may be open per process (the library state is global);
    every method is serialized through a process-wide lock.
    """

    def __init__(
        self,
        lib_path: str | Path | None = None,
        db_path: str | None = None,
        wal_path: str | None = None,
        dim: int = 3,
    ) -> None:
        global _open_engine
        if (db_path is None) != (wal_path is None):
            raise ValueError("Both db_path and wal_path must be provided together")
        if db_path is not None and wal_path is not None:
            if not db_path.strip() or not wal_path.strip():
                raise ValueError("db_path and wal_path must not be empty or whitespace")
            if db_path == wal_path:
                raise ValueError("db_path and wal_path must be distinct")

        if lib_path is None:
            repo_root = Path(__file__).resolve().parents[2]
            lib_path = repo_root / "lib" / "libnhe_o.so"

        with _ENGINE_LOCK:
            if _open_engine is not None:
                raise RuntimeError(
                    "libnhe_o drives one process-wide engine: close() the open NheOEngine first"
                )
            self._closed = True
            self._scratch_dir: str | None = None
            self._lib = _load_library(str(lib_path))
            self._bind_signatures()
            self._closed = False
            _open_engine = self
            try:
                if db_path is not None and wal_path is not None:
                    self.init_with_paths(db_path, wal_path, dim=dim)
                elif dim != 3:
                    # A private directory instead of predictable /tmp paths
                    self._scratch_dir = tempfile.mkdtemp(prefix="nhe_o_")
                    self.init_with_paths(
                        str(Path(self._scratch_dir) / "scratch.db"),
                        str(Path(self._scratch_dir) / "scratch.wal"),
                        dim=dim,
                    )
                else:
                    self.init()
            except BaseException:
                self.close()
                raise

    def __enter__(self) -> NheOEngine:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def close(self) -> None:
        """Release the process-wide engine (scratch files are removed). Idempotent."""
        global _open_engine
        with _ENGINE_LOCK:
            if self._closed:
                return
            status = c_int(0)
            self._lib.nhe_o_close(byref(status))
            self._closed = True
            if _open_engine is self:
                _open_engine = None
            if self._scratch_dir is not None:
                shutil.rmtree(self._scratch_dir, ignore_errors=True)
                self._scratch_dir = None
            if status.value != STATUS_OK:
                raise NheOError("nhe_o_close", status.value)

    def _require_open(self) -> None:
        if self._closed:
            raise RuntimeError("NheOEngine is closed")

    def _bind_signatures(self) -> None:
        char_p = POINTER(c_char)
        float_p = POINTER(c_float)
        int_p = POINTER(c_int)
        int64_p = POINTER(c_int64)

        signatures: dict[str, list[Any]] = {
            "nhe_o_init": [int_p],
            "nhe_o_init_with_paths": [char_p, c_int, char_p, c_int, c_int, int_p],
            "nhe_o_close": [int_p],
            "nhe_o_checkpoint": [int_p],
            "nhe_o_analyze_sql": [char_p, c_int, int_p, int_p, int_p, int_p],
            "nhe_o_vector_distance_3d": [
                c_float, c_float, c_float, c_float, c_float, c_float,
                float_p, float_p, int_p, int_p,
            ],
            "nhe_o_vector_distance_nd": [float_p, float_p, c_int, float_p, float_p, int_p, int_p],
            "nhe_o_kv_set": [char_p, c_int, char_p, c_int, c_int64, c_int64, int_p],
            "nhe_o_kv_get": [char_p, c_int, c_int64, char_p, int_p, int_p],
            "nhe_o_kv_del": [char_p, c_int, c_int64, int_p, int_p],
            "nhe_o_kv_exists": [char_p, c_int, c_int64, int_p, int_p],
            "nhe_o_kv_expire": [char_p, c_int, c_int64, c_int64, int_p, int_p],
            "nhe_o_kv_ttl": [char_p, c_int, c_int64, int64_p, int_p],
            "nhe_o_kv_incr_by": [char_p, c_int, c_int64, c_int64, int64_p, int_p],
            "nhe_o_pubsub_subscribe": [char_p, c_int, int_p, int_p],
            "nhe_o_pubsub_unsubscribe": [c_int, int_p],
            "nhe_o_pubsub_publish": [char_p, c_int, char_p, c_int, int_p, int_p],
            "nhe_o_pubsub_poll": [c_int, char_p, int_p, char_p, int_p, int_p, int_p],
            "nhe_o_rag_ingest_3d": [c_int, char_p, c_int, c_float, c_float, c_float, c_int, int_p],
            "nhe_o_rag_ingest_nd": [c_int, char_p, c_int, float_p, c_int, c_int, int_p],
            "nhe_o_rag_ingest_full_nd": [
                c_int, char_p, c_int, char_p, c_int, char_p, c_int,
                float_p, c_int, c_int, int_p,
            ],
            "nhe_o_rag_delete": [c_int, int_p],
            "nhe_o_rag_query_3d": [
                c_float, c_float, c_float, c_int, char_p, c_int, c_int,
                int_p, int_p, float_p, int_p, int_p, int_p,
            ],
            "nhe_o_rag_query_nd": [
                float_p, c_int, c_int, char_p, c_int, c_int,
                int_p, int_p, float_p, char_p, int_p, int_p, int_p,
            ],
            "nhe_o_rag_query_full_nd": [
                float_p, c_int, c_int, char_p, c_int, char_p, c_int, c_int,
                int_p, int_p, float_p, char_p, int_p, int_p, int_p,
            ],
        }
        for name, argtypes in signatures.items():
            func = getattr(self._lib, name)
            func.argtypes = argtypes
            func.restype = None
        for name in ("nhe_o_version_major", "nhe_o_version_minor"):
            func = getattr(self._lib, name)
            func.argtypes = []
            func.restype = c_int

    def version(self) -> tuple[int, int]:
        with _ENGINE_LOCK:
            return (
                int(self._lib.nhe_o_version_major()),
                int(self._lib.nhe_o_version_minor()),
            )

    def init(self) -> None:
        """Reset to a scratch 3-D database on per-process /tmp files."""
        with _ENGINE_LOCK:
            self._require_open()
            status = c_int(0)
            self._lib.nhe_o_init(byref(status))
            if status.value != STATUS_OK:
                raise NheOError("nhe_o_init", status.value)

    def init_with_paths(self, db_path: str, wal_path: str, dim: int = 3) -> None:
        """Open (and recover) the database at db_path / wal_path."""
        if not db_path.strip() or not wal_path.strip():
            raise ValueError("Paths must not be empty or whitespace")
        if "\x00" in db_path or "\x00" in wal_path:
            raise ValueError("Paths must not contain embedded NUL bytes")
        if db_path == wal_path:
            raise ValueError("db_path and wal_path must be distinct")
        db_buf, db_len = _make_text_buf(db_path)
        wal_buf, wal_len = _make_text_buf(wal_path)
        with _ENGINE_LOCK:
            self._require_open()
            status = c_int(0)
            self._lib.nhe_o_init_with_paths(
                db_buf, db_len, wal_buf, wal_len, _i32(dim, "dim"), byref(status)
            )
            if status.value != STATUS_OK:
                raise NheOError("nhe_o_init_with_paths", status.value)

    def checkpoint(self) -> None:
        """Compact the WAL now (it also runs automatically after durable writes)."""
        with _ENGINE_LOCK:
            self._require_open()
            status = c_int(0)
            self._lib.nhe_o_checkpoint(byref(status))
            if status.value != STATUS_OK:
                raise NheOError("nhe_o_checkpoint", status.value)

    def analyze_sql(self, query: str) -> dict[str, Any]:
        q_buf, q_len = _make_text_buf(query)
        stmt_kind = c_int(0)
        has_vec = c_int(0)
        has_jsonb = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_analyze_sql(
                q_buf,
                q_len,
                byref(stmt_kind),
                byref(has_vec),
                byref(has_jsonb),
                byref(status),
            )
        return {
            "status": status.value,
            "stmt_kind": stmt_kind.value,
            "has_vector_op": bool(has_vec.value),
            "has_jsonb_op": bool(has_jsonb.value),
        }

    def vector_distance_3d(
        self,
        a: tuple[float, float, float],
        b: tuple[float, float, float],
    ) -> dict[str, float | int]:
        ax, ay, az = _validate_float(a[0]), _validate_float(a[1]), _validate_float(a[2])
        bx, by, bz = _validate_float(b[0]), _validate_float(b[1]), _validate_float(b[2])
        l2_dist = c_float(0.0)
        cos_dist = c_float(0.0)
        hamming = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_vector_distance_3d(
                c_float(ax),
                c_float(ay),
                c_float(az),
                c_float(bx),
                c_float(by),
                c_float(bz),
                byref(l2_dist),
                byref(cos_dist),
                byref(hamming),
                byref(status),
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_vector_distance_3d", status.value)
        return {
            "l2_distance": float(l2_dist.value),
            "cosine_distance": float(cos_dist.value),
            "hamming_distance": int(hamming.value),
        }

    def vector_distance_nd(
        self, a: Sequence[float], b: Sequence[float]
    ) -> dict[str, float | int]:
        if len(a) != len(b):
            raise ValueError("Vectors must have equal dimensions")
        a_buf, dim = _make_vec_buf(a)
        b_buf, _ = _make_vec_buf(b)
        l2_dist = c_float(0.0)
        cos_dist = c_float(0.0)
        hamming = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_vector_distance_nd(
                a_buf,
                b_buf,
                _i32(dim, "dim"),
                byref(l2_dist),
                byref(cos_dist),
                byref(hamming),
                byref(status),
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_vector_distance_nd", status.value)
        return {
            "l2_distance": float(l2_dist.value),
            "cosine_distance": float(cos_dist.value),
            "hamming_distance": int(hamming.value),
        }

    def kv_set(
        self, key: str, val: str, now_sec: int | None = None, ttl_sec: int = 0
    ) -> None:
        k_buf, k_len = _make_ident_buf(key)
        v_buf, v_len = _make_text_buf(val)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_kv_set(
                k_buf,
                k_len,
                v_buf,
                v_len,
                _now(now_sec),
                _i64(ttl_sec, "ttl_sec"),
                byref(status),
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_kv_set", status.value)

    def kv_get(self, key: str, now_sec: int | None = None) -> str | None:
        k_buf, k_len = _make_ident_buf(key)
        out_buf = TextBuffer()
        out_len = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_kv_get(
                k_buf,
                k_len,
                _now(now_sec),
                out_buf,
                byref(out_len),
                byref(status),
            )
        if status.value in (STATUS_NOT_FOUND, STATUS_EXPIRED):
            return None
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_kv_get", status.value)
        return bytes(out_buf[: out_len.value]).decode("utf-8", "surrogateescape")

    def kv_del(self, key: str, now_sec: int | None = None) -> bool:
        """Redis DEL at now_sec: True iff the key was live (present and not expired)."""
        k_buf, k_len = _make_ident_buf(key)
        removed = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_kv_del(
                k_buf, k_len, _now(now_sec), byref(removed), byref(status)
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_kv_del", status.value)
        return bool(removed.value)

    def kv_exists(self, key: str, now_sec: int | None = None) -> bool:
        k_buf, k_len = _make_ident_buf(key)
        exists = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_kv_exists(
                k_buf, k_len, _now(now_sec), byref(exists), byref(status)
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_kv_exists", status.value)
        return bool(exists.value)

    def kv_expire(self, key: str, ttl_sec: int, now_sec: int | None = None) -> bool:
        k_buf, k_len = _make_ident_buf(key)
        updated = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_kv_expire(
                k_buf,
                k_len,
                _now(now_sec),
                _i64(ttl_sec, "ttl_sec"),
                byref(updated),
                byref(status),
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_kv_expire", status.value)
        return bool(updated.value)

    def kv_ttl(self, key: str, now_sec: int | None = None) -> int:
        k_buf, k_len = _make_ident_buf(key)
        ttl_val = c_int64(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_kv_ttl(
                k_buf, k_len, _now(now_sec), byref(ttl_val), byref(status)
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_kv_ttl", status.value)
        return int(ttl_val.value)

    def kv_incr_by(self, key: str, delta: int, now_sec: int | None = None) -> int:
        k_buf, k_len = _make_ident_buf(key)
        new_val = c_int64(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_kv_incr_by(
                k_buf,
                k_len,
                _i64(delta, "delta"),
                _now(now_sec),
                byref(new_val),
                byref(status),
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_kv_incr_by", status.value)
        return int(new_val.value)

    def pubsub_subscribe(self, pattern: str) -> int:
        p_buf, p_len = _make_ident_buf(pattern)
        sub_id = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_pubsub_subscribe(p_buf, p_len, byref(sub_id), byref(status))
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_pubsub_subscribe", status.value)
        return int(sub_id.value)

    def pubsub_unsubscribe(self, sub_id: int) -> None:
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_pubsub_unsubscribe(_i32(sub_id, "sub_id"), byref(status))
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_pubsub_unsubscribe", status.value)

    def pubsub_publish(self, channel: str, payload: str) -> int:
        c_buf, c_len = _make_ident_buf(channel)
        p_buf, p_len = _make_text_buf(payload)
        delivered = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_pubsub_publish(
                c_buf, c_len, p_buf, p_len, byref(delivered), byref(status)
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_pubsub_publish", status.value)
        return int(delivered.value)

    def pubsub_poll(self, sub_id: int) -> tuple[str, str] | None:
        c_buf = IdentBuffer()
        c_len = c_int(0)
        p_buf = TextBuffer()
        p_len = c_int(0)
        found = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_pubsub_poll(
                _i32(sub_id, "sub_id"),
                c_buf,
                byref(c_len),
                p_buf,
                byref(p_len),
                byref(found),
                byref(status),
            )
        if status.value == STATUS_NOT_FOUND or not found.value:
            if status.value not in (STATUS_OK, STATUS_NOT_FOUND):
                raise NheOError("nhe_o_pubsub_poll", status.value)
            return None
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_pubsub_poll", status.value)
        chan = bytes(c_buf[: c_len.value]).decode("utf-8", "surrogateescape")
        payload = bytes(p_buf[: p_len.value]).decode("utf-8", "surrogateescape")
        return chan, payload

    def rag_ingest_3d(
        self,
        doc_id: int,
        summary: str,
        vec: tuple[float, float, float],
        related_doc_id: int = 0,
        metadata_json: str = "",
        parent_text: str | None = None,
    ) -> None:
        self.rag_ingest_nd(
            doc_id,
            summary,
            vec,
            related_doc_id=related_doc_id,
            metadata_json=metadata_json,
            parent_text=parent_text,
        )

    def rag_ingest_nd(
        self,
        doc_id: int,
        summary: str,
        vec: Sequence[float],
        related_doc_id: int = 0,
        metadata_json: str = "",
        parent_text: str | None = None,
    ) -> None:
        """Ingest (or update) one document as one durable transaction.

        parent_text defaults to the summary; at least one of them must be non-empty.
        An empty metadata_json stores an empty object, matched only by the filter "{}".
        """
        m_buf, m_len = _make_text_buf(metadata_json)
        s_buf, s_len = _make_text_buf(summary)
        p_buf, p_len = _make_toast_buf(parent_text if parent_text is not None else summary)
        v_buf, dim = _make_vec_buf(vec)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_rag_ingest_full_nd(
                _i32(doc_id, "doc_id"),
                m_buf,
                m_len,
                s_buf,
                s_len,
                p_buf,
                p_len,
                v_buf,
                _i32(dim, "dim"),
                _i32(related_doc_id, "related_doc_id"),
                byref(status),
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_rag_ingest_full_nd", status.value)

    def rag_ingest_full_nd(
        self,
        doc_id: int,
        summary: str,
        vec: Sequence[float],
        related_doc_id: int = 0,
        metadata_json: str = "",
        parent_text: str | None = None,
    ) -> None:
        self.rag_ingest_nd(
            doc_id,
            summary,
            vec,
            related_doc_id=related_doc_id,
            metadata_json=metadata_json,
            parent_text=parent_text,
        )

    def rag_delete(self, doc_id: int) -> None:
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_rag_delete(_i32(doc_id, "doc_id"), byref(status))
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_rag_delete", status.value)

    def rag_query_3d(
        self,
        query_vec: tuple[float, float, float],
        encoding_mode: int = ENCODING_FLOAT32,
        keyword: str = "",
        top_k: int = 3,
        filter_json: str = "",
    ) -> dict[str, Any]:
        return self.rag_query_nd(
            query_vec,
            encoding_mode=encoding_mode,
            keyword=keyword,
            top_k=top_k,
            filter_json=filter_json,
        )

    def rag_query_nd(
        self,
        query_vec: Sequence[float],
        encoding_mode: int = ENCODING_FLOAT32,
        keyword: str = "",
        top_k: int = 3,
        filter_json: str = "",
    ) -> dict[str, Any]:
        q_buf, dim = _make_vec_buf(query_vec)
        f_buf, f_len = _make_text_buf(filter_json)
        k_buf, k_len = _make_text_buf(keyword)
        hit_count = c_int(0)
        top_doc_id = c_int(0)
        top_dist = c_float(0.0)
        parent_buf = ToastBuffer()
        parent_bytes = c_int(0)
        graph_hit = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_rag_query_full_nd(
                q_buf,
                _i32(dim, "dim"),
                _i32(encoding_mode, "encoding_mode"),
                f_buf,
                f_len,
                k_buf,
                k_len,
                _i32(top_k, "top_k"),
                byref(hit_count),
                byref(top_doc_id),
                byref(top_dist),
                parent_buf,
                byref(parent_bytes),
                byref(graph_hit),
                byref(status),
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_rag_query_full_nd", status.value)
        copy_len = min(MAX_TOAST_BYTES, int(parent_bytes.value))
        parent_text = bytes(parent_buf[:copy_len]).decode("utf-8", errors="replace")
        return {
            "hit_count": int(hit_count.value),
            "top_doc_id": int(top_doc_id.value),
            "top_distance": float(top_dist.value),
            "top_parent_bytes": int(parent_bytes.value),
            "top_parent_text": parent_text,
            "graph_neighbor_hit": bool(graph_hit.value),
        }

    def rag_query_full_nd(
        self,
        query_vec: Sequence[float],
        encoding_mode: int = ENCODING_FLOAT32,
        keyword: str = "",
        top_k: int = 3,
        filter_json: str = "",
    ) -> dict[str, Any]:
        return self.rag_query_nd(
            query_vec,
            encoding_mode=encoding_mode,
            keyword=keyword,
            top_k=top_k,
            filter_json=filter_json,
        )

    def rag_query_nd_prefix(
        self,
        query_vec: Sequence[float],
        encoding_mode: int = ENCODING_FLOAT32,
        keyword: str = "",
        top_k: int = 3,
    ) -> dict[str, Any]:
        """nhe_o_rag_query_nd: only the first 512 bytes of the top parent chunk."""
        q_buf, dim = _make_vec_buf(query_vec)
        k_buf, k_len = _make_text_buf(keyword)
        hit_count = c_int(0)
        top_doc_id = c_int(0)
        top_dist = c_float(0.0)
        parent_buf = TextBuffer()
        parent_len = c_int(0)
        graph_hit = c_int(0)
        status = c_int(0)
        with _ENGINE_LOCK:
            self._require_open()
            self._lib.nhe_o_rag_query_nd(
                q_buf,
                _i32(dim, "dim"),
                _i32(encoding_mode, "encoding_mode"),
                k_buf,
                k_len,
                _i32(top_k, "top_k"),
                byref(hit_count),
                byref(top_doc_id),
                byref(top_dist),
                parent_buf,
                byref(parent_len),
                byref(graph_hit),
                byref(status),
            )
        if status.value != STATUS_OK:
            raise NheOError("nhe_o_rag_query_nd", status.value)
        written = min(MAX_TEXT_LEN, int(parent_len.value))
        return {
            "hit_count": int(hit_count.value),
            "top_doc_id": int(top_doc_id.value),
            "top_parent_len": int(parent_len.value),
            "top_parent_prefix": bytes(parent_buf[:written]).decode("utf-8", errors="replace"),
            "graph_neighbor_hit": bool(graph_hit.value),
        }


def _check(cond: bool, msg: str) -> None:
    """Self-test assertion that also runs under `python -O`."""
    if not cond:
        raise AssertionError(msg)


def _expect_error(exc_type: type[BaseException], func: Any, msg: str) -> BaseException:
    try:
        func()
    except exc_type as exc:
        return exc
    raise AssertionError(msg)


def run_self_test() -> None:
    # Verify exported capacity constants match SPARK specs
    _check(MIN_DOC_ID == 1 and MAX_DOC_ID == 16, "doc id bounds")
    _check(MAX_RAG_DOCS == 16, "MAX_RAG_DOCS")
    _check(
        MAX_CLOG_ENTRIES == 8192 and MAX_KV_KEYS == 64 and MAX_SUBSCRIBERS == 16,
        "capacity constants",
    )

    # Verify single-path argument rejection
    _expect_error(
        ValueError,
        lambda: NheOEngine(db_path="/tmp/only_one.db"),
        "Expected ValueError when only db_path is provided",
    )

    engine = NheOEngine()
    _check(engine.version() == (0, 4), f"Unexpected version: {engine.version()}")

    # One process-wide engine: a second open instance is refused until close()
    _expect_error(RuntimeError, NheOEngine, "Expected RuntimeError for a second open engine")

    sql_info = engine.analyze_sql(
        "SELECT id FROM docs WHERE meta @> $1::jsonb ORDER BY emb <-> $2;"
    )
    _check(sql_info["status"] == STATUS_OK, "analyze_sql status")
    _check(sql_info["stmt_kind"] == STMT_SELECT, "analyze_sql statement kind")
    _check(sql_info["has_vector_op"] is True, "has_vector_op")
    _check(sql_info["has_jsonb_op"] is True, "has_jsonb_op")

    # Verify multi-statement SQL injection, duplicate clauses, and empty FROM rejection
    for invalid_sql in (
        "SELECT 1; DROP TABLE docs;",
        "SELECT id FROM docs WHERE x = 1 WHERE y = 2;",
        "SELECT id FROM docs WHERE x = 1 ORDER BY id WHERE y = 2;",
        "SELECT id FROM WHERE x = 1;",
    ):
        bad_sql = engine.analyze_sql(invalid_sql)
        _check(
            bad_sql["status"] == STATUS_INVALID_SYNTAX,
            f"Expected invalid syntax for: {invalid_sql}",
        )

    dist = engine.vector_distance_3d((1.0, 2.0, 2.0), (4.0, 6.0, 2.0))
    _check(abs(dist["l2_distance"] - 5.0) < 0.01, "3-D L2 distance")

    vec_4096_a = [1.0 if i == 0 else 0.0 for i in range(4096)]
    vec_4096_b = [0.0 if i == 0 else (1.0 if i == 4095 else 0.0) for i in range(4096)]
    dist_nd = engine.vector_distance_nd(vec_4096_a, vec_4096_b)
    _check(abs(dist_nd["l2_distance"] - math.sqrt(2.0)) < 0.01, "4096-D L2 distance")
    _check(dist_nd["hamming_distance"] == 2, "4096-D Hamming distance")

    engine.kv_set("llm:prompt:qwen", "Formally verified SPARK RAG", now_sec=100, ttl_sec=60)
    _check(engine.kv_exists("llm:prompt:qwen", now_sec=120) is True, "kv_exists")
    _check(engine.kv_ttl("llm:prompt:qwen", now_sec=120) == 40, "kv_ttl")
    _check(engine.kv_get("llm:prompt:qwen", now_sec=120) == "Formally verified SPARK RAG", "kv_get")
    _check(engine.kv_expire("llm:prompt:qwen", ttl_sec=10, now_sec=120) is True, "kv_expire")
    _check(engine.kv_ttl("llm:prompt:qwen", now_sec=125) == 5, "kv_ttl after expire")
    _check(engine.kv_get("llm:prompt:qwen", now_sec=200) is None, "kv_get expired")
    _check(engine.kv_exists("llm:prompt:qwen", now_sec=200) is False, "kv_exists expired")
    # DEL of an expired key frees it but does not count as a removal
    _check(engine.kv_del("llm:prompt:qwen", now_sec=200) is False, "kv_del expired")
    _check(engine.kv_incr_by("llm:tokens", 42, now_sec=200) == 42, "kv_incr_by")
    _check(engine.kv_del("llm:tokens", now_sec=200) is True, "kv_del live")
    # Out-of-range integers are rejected instead of wrapping inside ctypes
    _expect_error(ValueError, lambda: engine.kv_incr_by("llm:tokens", 2**64 + 1, now_sec=200),
                  "Expected ValueError for an int64 overflow")
    _expect_error(ValueError, lambda: engine.kv_set("k", "v", now_sec=2**64 + 100),
                  "Expected ValueError for an out-of-range timestamp")
    _expect_error(ValueError, lambda: engine.pubsub_poll(2**32 + 1),
                  "Expected ValueError for an out-of-range subscriber id")
    # Without now_sec the current time is used, so a TTL can elapse
    engine.kv_set("clock:key", "v", ttl_sec=1)
    _check(engine.kv_get("clock:key") == "v", "real-clock key is live")
    _check(engine.kv_get("clock:key", now_sec=int(time.time()) + 5) is None, "real-clock TTL elapses")
    # INCRBY follows Redis string2ll (no "+", no leading zeros)
    engine.kv_set("llm:plus", "+5", now_sec=200)
    exc = _expect_error(NheOError, lambda: engine.kv_incr_by("llm:plus", 1, now_sec=200),
                        "Expected NheOError for INCRBY on '+5'")
    _check(getattr(exc, "status", None) == STATUS_TYPE_MISMATCH, "INCRBY '+5' status")

    sub_id = engine.pubsub_subscribe("rag.*")
    large_parent = "Ada SPARK formal verification guide: " + ("X" * 5000)
    engine.rag_ingest_3d(
        1,
        "Ada SPARK formal verification guide",
        (1.0, 0.0, 0.0),
        related_doc_id=2,
        metadata_json='{"lang":"\\u0076\\u0069","domain":"spark","nested":{"sub":{"a":1.0,"b":2}}}',
        parent_text=large_parent,
    )
    engine.rag_ingest_3d(
        2,
        "PostgreSQL TOAST overflow storage",
        (0.8, 0.2, 0.0),
        related_doc_id=1,
        metadata_json='{"lang":"en","domain":"storage"}',
    )

    polled = engine.pubsub_poll(sub_id)
    _check(polled is not None and polled[0] == "rag.indexed", "durable notification")
    engine.pubsub_unsubscribe(sub_id)

    rag_res = engine.rag_query_3d(
        (1.0, 0.0, 0.0),
        encoding_mode=ENCODING_FLOAT32,
        keyword="SPARK",
        top_k=2,
        filter_json='{"lang":"vi","nested":{"sub":{"b":2,"a":1}}}',
    )
    _check(rag_res["hit_count"] == 1, "filtered hit count")
    _check(rag_res["top_doc_id"] == 1, "filtered top doc")
    _check(rag_res["top_parent_bytes"] == len(large_parent), "parent byte length")
    _check(rag_res["top_parent_text"] == large_parent, "parent text")
    _check(rag_res["graph_neighbor_hit"] is True, "graph neighbor hit")

    # nhe_o_rag_query_nd reports the bytes it wrote to its 512-byte buffer
    prefix = engine.rag_query_nd_prefix((1.0, 0.0, 0.0), top_k=1)
    _check(prefix["top_doc_id"] == 1, "prefix query top doc")
    _check(prefix["top_parent_len"] == MAX_TEXT_LEN, "prefix length is the bytes written")
    _check(prefix["top_parent_prefix"] == large_parent[:MAX_TEXT_LEN], "prefix text")

    # An empty summary with an empty parent chunk is rejected
    exc = _expect_error(NheOError, lambda: engine.rag_ingest_3d(3, "", (0.0, 1.0, 0.0)),
                        "Expected NheOError for an empty document")
    _check(getattr(exc, "status", None) == STATUS_INVALID_ARG, "empty document status")

    # Verify N-D (4096-D) RAG with custom paths, persistence across restart,
    # lossless "RMET" summary (>63B) + JSONB metadata recovery,
    # durable KV incr_by/expire recovery, and durable deletion
    # Private directory, so concurrent self-test runs never share these files
    work_dir = Path(tempfile.mkdtemp(prefix="nhe_o_py_"))
    db_4096 = work_dir / "nhe_o_py_4096.db"
    wal_4096 = work_dir / "nhe_o_py_4096.wal"
    db_4096.unlink(missing_ok=True)
    wal_4096.unlink(missing_ok=True)

    engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096)
    engine.kv_set("persist:key", "survived_restart", now_sec=100, ttl_sec=0)
    _check(engine.kv_expire("persist:key", ttl_sec=500, now_sec=100) is True, "durable expire")
    _check(engine.kv_incr_by("persist:counter", 99, now_sec=100) == 99, "durable incr_by")
    long_summary_a = (
        "Qwen3 4096-D embedding chunk A with extended summary exceeding 63 inline bytes "
        "to verify RMET TOAST overflow persistence [RMET_TAIL_TOKEN]"
    )
    engine.rag_ingest_full_nd(
        1,
        long_summary_a,
        vec_4096_a,
        related_doc_id=1,  # Self-loop must not count as 1-hop GraphRAG neighbor
        metadata_json='{"model":"qwen3-35b-a3b-long-metadata","tier":"prod","num":1.0}',
    )
    engine.rag_ingest_full_nd(
        2,
        "Qwen3 4096-D embedding chunk B",
        vec_4096_b,
        related_doc_id=1,
        metadata_json='{"model":"qwen3-35b-a3b-long-metadata","tier":"prod","num":1}',
    )

    # Re-open existing DB & WAL without deleting files
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096)
    _check(engine.kv_get("persist:key", now_sec=105) == "survived_restart", "KV recovery")
    _check(engine.kv_ttl("persist:key", now_sec=105) == 495, "KV TTL recovery")
    _check(engine.kv_get("persist:counter", now_sec=105) == "99", "KV counter recovery")
    _check(engine.kv_incr_by("persist:counter", 1, now_sec=105) == 100, "KV counter incr")
    rag_4096 = engine.rag_query_full_nd(
        vec_4096_b,
        encoding_mode=ENCODING_FLOAT32,
        top_k=2,
        filter_json='{"model":"qwen3-35b-a3b-long-metadata","tier":"prod","num":1}',
    )
    _check(rag_4096["hit_count"] == 2, "4096-D hit count")
    _check(rag_4096["top_doc_id"] == 2, "4096-D top doc")
    _check(rag_4096["top_parent_text"] == "Qwen3 4096-D embedding chunk B", "4096-D parent")
    _check(rag_4096["graph_neighbor_hit"] is True, "4096-D graph hit")

    # Verify tail keyword >63B matches after recovery, and self-loop is rejected
    rag_rmet = engine.rag_query_full_nd(
        vec_4096_a,
        encoding_mode=ENCODING_FLOAT32,
        keyword="RMET_TAIL_TOKEN",
        top_k=1,
        filter_json='{"model":"qwen3-35b-a3b-long-metadata","num":1}',
    )
    _check(rag_rmet["hit_count"] == 1, "RMET hit count")
    _check(rag_rmet["top_doc_id"] == 1, "RMET top doc")
    _check(rag_rmet["graph_neighbor_hit"] is False, "self-loop is not a neighbor")

    # Also verify Stage-2 TOAST re-ranking in INT8_SQ8 mode on 4096-D
    rag_4096_sq8 = engine.rag_query_full_nd(
        vec_4096_b,
        encoding_mode=ENCODING_INT8_SQ8,
        top_k=2,
        filter_json='{"model":"qwen3-35b-a3b-long-metadata","tier":"prod"}',
    )
    _check(rag_4096_sq8["hit_count"] == 2, "SQ8 hit count")
    _check(rag_4096_sq8["top_doc_id"] == 2, "SQ8 top doc")

    # Durable delete of doc 2 and verify survival across restart
    engine.rag_delete(2)
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096)
    rag_after_del = engine.rag_query_full_nd(
        vec_4096_b, encoding_mode=ENCODING_FLOAT32, top_k=2
    )
    _check(rag_after_del["hit_count"] == 1, "hit count after delete")
    _check(rag_after_del["top_doc_id"] == 1, "top doc after delete")

    # An explicit checkpoint compacts the WAL to one frame per KV key plus one commit
    engine.checkpoint()
    _check(wal_4096.stat().st_size == 3 * WAL_FRAME_SIZE, "checkpointed WAL size")
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096)
    _check(engine.kv_get("persist:counter", now_sec=105) == "100", "KV after checkpoint")
    rag_ckpt = engine.rag_query_full_nd(vec_4096_a, encoding_mode=ENCODING_FLOAT32, top_k=2)
    _check(rag_ckpt["hit_count"] == 1 and rag_ckpt["top_doc_id"] == 1, "RAG after checkpoint")

    # Verify corrupted VTST/RMET TOAST page in DB file is rejected on recovery
    wal_4096.unlink(missing_ok=True)
    db_bytes = bytearray(db_4096.read_bytes())
    # Corrupt Doc 1's VTST vector TOAST Page 11 (offset 11 * 4096 + 32; Next_TOAST_Pg starts at 10)
    db_bytes[11 * 4096 + 32] ^= 0xFF
    db_4096.write_bytes(bytes(db_bytes))
    _expect_error(
        NheOError,
        lambda: engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096),
        "Expected NheOError on corrupted TOAST page during recovery",
    )

    # A file that is not a WAL is refused and left untouched
    wal_4096.write_bytes(b"NOT_A_WAL_FILE")
    exc = _expect_error(
        NheOError,
        lambda: engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096),
        "Expected NheOError on a WAL path naming a foreign file",
    )
    _check(getattr(exc, "status", None) == STATUS_IO_ERROR, "foreign WAL status")
    _check(wal_4096.read_bytes() == b"NOT_A_WAL_FILE", "foreign WAL left untouched")

    # A torn first frame (a valid header, part of the payload) is repaired, but the
    # corrupted database page still fails recovery
    torn_header = b"NHEO" + (1).to_bytes(4, "big") + (1).to_bytes(4, "big") + bytes(16)
    wal_4096.write_bytes(torn_header + b"\x01" * 1000)
    _expect_error(
        NheOError,
        lambda: engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096),
        "Expected NheOError on the corrupted TOAST page behind a torn WAL",
    )
    _check(wal_4096.stat().st_size == 0, "torn WAL tail truncated")

    # Verify identical db_path and wal_path is rejected
    _expect_error(
        ValueError,
        lambda: engine.init_with_paths(str(db_4096), str(db_4096), dim=3),
        "Expected ValueError when db_path == wal_path",
    )
    # ... also when they only alias one file
    exc = _expect_error(
        NheOError,
        lambda: engine.init_with_paths(str(db_4096), f"{work_dir}/./nhe_o_py_4096.db", dim=3),
        "Expected NheOError when db_path and wal_path alias one file",
    )
    _check(getattr(exc, "status", None) == STATUS_INVALID_ARG, "alias status")

    # Verify truncated 1-page (4096 B) .db file is rejected by init_with_paths
    wal_4096.unlink(missing_ok=True)
    db_4096.write_bytes(b"\x00" * 4096)
    _expect_error(
        NheOError,
        lambda: engine.init_with_paths(str(db_4096), str(wal_4096), dim=3),
        "Expected NheOError on truncated 1-page .db file",
    )

    # Trailing garbage after the last valid WAL frame (a torn append) is repaired
    db_4096.unlink(missing_ok=True)
    wal_4096.unlink(missing_ok=True)
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
    engine.rag_ingest_3d(1, "Parent chunk integrity test", (1.0, 2.0, 3.0))
    valid_wal_size = wal_4096.stat().st_size
    wal_4096.write_bytes(wal_4096.read_bytes() + b"GARBAGE")
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
    _check(wal_4096.stat().st_size == valid_wal_size, "torn WAL tail repaired")
    repaired = engine.rag_query_3d((1.0, 2.0, 3.0), top_k=1)
    _check(repaired["top_doc_id"] == 1, "document survives WAL tail repair")

    # Remove WAL and corrupt parent chunk TOAST Page 10 in DB file
    wal_4096.unlink(missing_ok=True)
    db_bytes = bytearray(db_4096.read_bytes())
    db_bytes[10 * 4096 + 24] ^= 0xFF
    db_4096.write_bytes(bytes(db_bytes))
    _expect_error(
        NheOError,
        lambda: engine.init_with_paths(str(db_4096), str(wal_4096), dim=3),
        "Expected NheOError on corrupted parent chunk TOAST page during recovery",
    )

    # Verify SQL grammar hardening rejects malformed DDL/DML/NOTIFY/parameter tokens
    engine.init()
    for bad_sql in [
        "CREATE BOGUS TABLE docs (id INT)",
        "CREATE TABLE docs (a, b)",
        "CREATE TABLE docs (id FOOBAR_TYPE)",
        "CREATE TABLE docs (emb VECTOR(0))",
        "CREATE TABLE docs (emb VECTOR(9999))",
        "CREATE TABLE docs (score DOUBLE PRECISION(10))",
        "CREATE TABLE docs (id INT) DROP TABLE users",
        "SELECT id FROM docs RETURNING id",
        "SELECT id FROM docs ON CONFLICT DO NOTHING",
        "UPDATE docs SET a = 1 RETURNING",
        "DELETE FROM docs WHERE id = 1 RETURNING",
        "INSERT BOGUS INTO docs VALUES (1)",
        "INSERT INTO docs VALUES ;",
        "INSERT INTO docs VALUES ()",
        "INSERT INTO docs VALUES 123",
        "INSERT INTO docs BOGUS VALUES (1)",
        "INSERT INTO docs VALUES (1) BOGUS",
        "INSERT INTO docs VALUES (1), ()",
        "UPDATE BOGUS docs SET a = 1",
        "UPDATE docs SET a",
        "DELETE BOGUS FROM docs",
        "DELETE FROM docs BOGUS",
        "NOTIFY ch, 123",
        "NOTIFY ch, 'a' 'b'",
    ]:
        res_bad = engine.analyze_sql(bad_sql)
        _check(res_bad["status"] == STATUS_INVALID_SYNTAX, f"Expected syntax error for: {bad_sql}")
    res_param = engine.analyze_sql("SELECT col$1abc FROM docs")
    _check(res_param["status"] == STATUS_OK, "identifier with $ status")
    _check(res_param["has_vector_op"] is False, "identifier with $ has no vector op")

    # Verify pubsub_poll raises on out-of-range sub_id
    _expect_error(NheOError, lambda: engine.pubsub_poll(999), "Expected NheOError on invalid sub_id")

    # A database whose id space was exhausted by an older version (KV frame with
    # Tx_Id = Max_Tx_Id = 8192) is checkpointed at open instead of being refused
    import zlib

    db_4096.unlink(missing_ok=True)
    wal_4096.unlink(missing_ok=True)
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
    engine.kv_set("sat_key", "sat_val", now_sec=1000, ttl_sec=0)
    # Rewrite the KV WAL frame's Tx_Id (bytes 4..8 big-endian) to 8192 (Max_Tx_Id) and update CRC32
    wal_raw = bytearray(wal_4096.read_bytes())
    wal_raw[4:8] = (8192).to_bytes(4, "big")
    new_crc = zlib.crc32(bytes(wal_raw[4:12]) + bytes(wal_raw[16:17]) + bytes(wal_raw[24:4120])) & 0xFFFFFFFF
    wal_raw[12:16] = new_crc.to_bytes(4, "big")
    wal_4096.write_bytes(bytes(wal_raw))
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
    _check(engine.kv_get("sat_key", now_sec=1000) == "sat_val", "KV value survives open checkpoint")
    engine.kv_set("sat_key2", "after", now_sec=1000)
    _check(engine.kv_get("sat_key2", now_sec=1000) == "after", "writes resume after checkpoint")

    # The automatic checkpoint keeps the WAL bounded
    for i in range(600):
        engine.kv_set("auto:key", str(i), now_sec=2000 + i)
    _check(
        wal_4096.stat().st_size < CHECKPOINT_WAL_FRAMES * WAL_FRAME_SIZE,
        "automatic checkpoint bounds the WAL",
    )

    # Calls from several threads are serialized by the SDK lock
    errors: list[BaseException] = []

    def worker(tid: int) -> None:
        try:
            for j in range(25):
                engine.kv_incr_by("threads:counter", 1, now_sec=3000)
                engine.kv_set(f"threads:{tid}", str(j), now_sec=3000)
        except BaseException as err:  # noqa: BLE001 - reported below
            errors.append(err)

    threads = [threading.Thread(target=worker, args=(t,)) for t in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    _check(not errors, f"threaded calls failed: {errors!r}")
    _check(engine.kv_get("threads:counter", now_sec=3000) == "100", "no lost increments")

    # Bytes that are not UTF-8 round-trip as surrogate escapes
    engine.kv_set("bin:key", "caf\udce9", now_sec=3000)
    _check(engine.kv_get("bin:key", now_sec=3000) == "caf\udce9", "non-UTF-8 value round-trips")
    bin_sub = engine.pubsub_subscribe("bin.*")
    engine.pubsub_publish("bin.x", "Gr\udcf6\udcdfe")
    _check(engine.pubsub_poll(bin_sub) == ("bin.x", "Gr\udcf6\udcdfe"), "non-UTF-8 payload round-trips")
    engine.pubsub_unsubscribe(bin_sub)

    # One process per database: another process cannot open the files this one holds
    import subprocess
    import sys

    lib_file = str(engine._lib._name)
    probe = (
        "import sys\n"
        f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
        "import nhe_o\n"
        "try:\n"
        f"    nhe_o.NheOEngine(lib_path={lib_file!r}, db_path={str(db_4096)!r},"
        f" wal_path={str(wal_4096)!r})\n"
        "except nhe_o.NheOError as exc:\n"
        "    sys.exit(0 if exc.status == nhe_o.STATUS_IO_ERROR else 1)\n"
        "sys.exit(2)\n"
    )
    probe_rc = subprocess.run([sys.executable, "-I", "-c", probe], check=False).returncode
    _check(probe_rc == 0, f"a second process must be refused (rc {probe_rc})")

    # A forked child drops the inherited engine and cannot open the parent's files,
    # while the parent can reopen them as long as the child runs
    if hasattr(os, "fork"):
        to_parent_r, to_parent_w = os.pipe()
        to_child_r, to_child_w = os.pipe()
        pid = os.fork()
        if pid == 0:
            code = 1
            try:
                os.close(to_parent_r)
                os.close(to_child_w)
                if engine._closed:
                    try:
                        NheOEngine(lib_path=lib_file, db_path=str(db_4096), wal_path=str(wal_4096))
                        code = 2
                    except NheOError as err:
                        code = 0 if err.status == STATUS_IO_ERROR else 3
                os.write(to_parent_w, b"r")
                os.read(to_child_r, 1)
            finally:
                os._exit(code)
        os.close(to_parent_w)
        os.close(to_child_r)
        os.read(to_parent_r, 1)
        engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
        _check(engine.kv_get("threads:counter", now_sec=3000) == "100", "parent reopens")
        os.write(to_child_w, b"d")
        os.close(to_child_w)
        os.close(to_parent_r)
        _, wait_status = os.waitpid(pid, 0)
        _check(os.waitstatus_to_exitcode(wait_status) == 0, "forked child")

    # A database path naming a file that is not a database is refused untouched
    notes = work_dir / "notes.txt"
    notes.write_text("my notes\n" * 300)
    exc = _expect_error(
        NheOError,
        lambda: engine.init_with_paths(str(notes), str(work_dir / "notes.wal"), dim=3),
        "Expected NheOError for a database path naming another file",
    )
    _check(getattr(exc, "status", None) == STATUS_INVALID_ARG, "non-database status")
    _check(notes.read_text() == "my notes\n" * 300, "non-database file left untouched")
    _check(not (work_dir / "notes.wal").exists(), "no WAL created for a refused database")

    # Symbolic links are resolved once at open: the checkpoint renames over the real
    # WAL and the links stay links
    real_dir = work_dir / "real"
    link_dir = work_dir / "links"
    real_dir.mkdir()
    link_dir.mkdir()
    (link_dir / "s.db").symlink_to(real_dir / "s.db")
    (link_dir / "s.wal").symlink_to(real_dir / "s.wal")
    engine.init_with_paths(str(link_dir / "s.db"), str(link_dir / "s.wal"), dim=3)
    engine.kv_set("link:key", "v", now_sec=100)
    engine.rag_ingest_3d(1, "three dimensions", (1.0, 0.0, 0.0))
    engine.checkpoint()
    _check((link_dir / "s.wal").is_symlink(), "WAL link survives the checkpoint")
    _check((real_dir / "s.wal").stat().st_size == 2 * WAL_FRAME_SIZE, "checkpoint wrote the real WAL")
    _check(not list(work_dir.glob("**/*.ckpt")), "no checkpoint leftovers")
    engine.init_with_paths(str(link_dir / "s.db"), str(link_dir / "s.wal"), dim=3)
    _check(engine.kv_get("link:key", now_sec=100) == "v", "reopen through links")

    # Reopening a database with another dimension is a mismatch, not damage
    exc = _expect_error(
        NheOError,
        lambda: engine.init_with_paths(str(link_dir / "s.db"), str(link_dir / "s.wal"), dim=8),
        "Expected NheOError for a dimension mismatch",
    )
    _check(getattr(exc, "status", None) == STATUS_DIMENSION_MISMATCH, "dimension mismatch status")
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)

    db_4096.unlink(missing_ok=True)
    wal_4096.unlink(missing_ok=True)

    # close() releases the engine and its scratch files; a new engine can then open
    engine.close()
    shutil.rmtree(work_dir, ignore_errors=True)
    _expect_error(RuntimeError, lambda: engine.kv_get("x"), "Expected RuntimeError after close()")
    with NheOEngine(dim=8) as scratch:
        scratch.rag_ingest_nd(1, "eight dimensions", [1.0] * 8)
        _check(scratch.rag_query_nd([1.0] * 8, top_k=1)["top_doc_id"] == 1, "8-D scratch engine")
        scratch_dir = scratch._scratch_dir
    _check(scratch_dir is not None and not Path(scratch_dir).exists(), "scratch dir removed")

    print("[PASS] Python ctypes SDK (`bindings/python/nhe_o.py`) verified against `libnhe_o.so`!")


if __name__ == "__main__":
    run_self_test()
