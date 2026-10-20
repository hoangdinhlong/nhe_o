#!/usr/bin/env python3
"""
nhe_o.py — Python ctypes SDK for the Formally Verified Nhé O Engine

Wraps the 100% SPARK 2022 C ABI (`Nhe_O.C_API` / `include/nhe_o.h`) so Python
local LLM pipelines (e.g., Qwen 3.8 RAG agents, llama-cpp-python, LangChain)
can invoke PostgreSQL SQL analysis, pgvector distance & quantization (up to
4096-D), Redis KV cache with TTL/LRU, Durable WAL Pub/Sub, and Universal
Hybrid RAG directly.
"""

from __future__ import annotations

import ctypes
import math
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

ENCODING_FLOAT32 = 0
ENCODING_INT8_SQ8 = 1
ENCODING_BINARY_1BIT = 2

IdentBuffer = c_char * MAX_IDENT_LEN
TextBuffer = c_char * MAX_TEXT_LEN
ToastBuffer = c_char * MAX_TOAST_BYTES
VectorBuffer = c_float * MAX_VECTOR_DIM


def _make_ident_buf(text: str) -> tuple[IdentBuffer, int]:
    raw = text.encode("utf-8")
    if len(raw) == 0 or len(raw) > MAX_IDENT_LEN:
        raise ValueError(f"Identifier length must be in 1..{MAX_IDENT_LEN} bytes")
    buf = IdentBuffer()
    buf[: len(raw)] = raw
    return buf, len(raw)


def _make_text_buf(text: str) -> tuple[TextBuffer, int]:
    raw = text.encode("utf-8")
    if len(raw) > MAX_TEXT_LEN:
        raise ValueError(f"Text exceeds {MAX_TEXT_LEN} bytes")
    buf = TextBuffer()
    buf[: len(raw)] = raw
    return buf, len(raw)


def _make_toast_buf(text: str) -> tuple[ToastBuffer, int]:
    raw = text.encode("utf-8")
    if len(raw) > MAX_TOAST_BYTES:
        raise ValueError(f"TOAST payload exceeds {MAX_TOAST_BYTES} bytes")
    buf = ToastBuffer()
    buf[: len(raw)] = raw
    return buf, len(raw)


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
    """Python ctypes binding to `libnhe_o.so` (`Nhe_O.C_API`)."""

    def __init__(
        self,
        lib_path: str | Path | None = None,
        db_path: str | None = None,
        wal_path: str | None = None,
        dim: int = 3,
    ) -> None:
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
        self._lib = ctypes.CDLL(str(lib_path))
        self._bind_signatures()
        if db_path is not None and wal_path is not None:
            self.init_with_paths(db_path, wal_path, dim=dim)
        elif dim != 3:
            self.init_with_paths("/tmp/nhe_o_c_api.db", "/tmp/nhe_o_c_api.wal", dim=dim)
        else:
            self.init()

    def _bind_signatures(self) -> None:
        char_p = POINTER(c_char)
        float_p = POINTER(c_float)
        int_p = POINTER(c_int)
        int64_p = POINTER(c_int64)

        self._lib.nhe_o_version_major.argtypes = []
        self._lib.nhe_o_version_major.restype = c_int

        self._lib.nhe_o_version_minor.argtypes = []
        self._lib.nhe_o_version_minor.restype = c_int

        self._lib.nhe_o_init.argtypes = [int_p]
        self._lib.nhe_o_init.restype = None

        self._lib.nhe_o_init_with_paths.argtypes = [
            char_p,
            c_int,
            char_p,
            c_int,
            c_int,
            int_p,
        ]
        self._lib.nhe_o_init_with_paths.restype = None

        self._lib.nhe_o_analyze_sql.argtypes = [
            char_p,
            c_int,
            int_p,
            int_p,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_analyze_sql.restype = None

        self._lib.nhe_o_vector_distance_3d.argtypes = [
            c_float,
            c_float,
            c_float,
            c_float,
            c_float,
            c_float,
            float_p,
            float_p,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_vector_distance_3d.restype = None

        self._lib.nhe_o_vector_distance_nd.argtypes = [
            float_p,
            float_p,
            c_int,
            float_p,
            float_p,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_vector_distance_nd.restype = None

        self._lib.nhe_o_kv_set.argtypes = [
            char_p,
            c_int,
            char_p,
            c_int,
            c_int64,
            c_int64,
            int_p,
        ]
        self._lib.nhe_o_kv_set.restype = None

        self._lib.nhe_o_kv_get.argtypes = [
            char_p,
            c_int,
            c_int64,
            char_p,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_kv_get.restype = None

        self._lib.nhe_o_kv_del.argtypes = [
            char_p,
            c_int,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_kv_del.restype = None

        self._lib.nhe_o_kv_exists.argtypes = [
            char_p,
            c_int,
            c_int64,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_kv_exists.restype = None

        self._lib.nhe_o_kv_expire.argtypes = [
            char_p,
            c_int,
            c_int64,
            c_int64,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_kv_expire.restype = None

        self._lib.nhe_o_kv_ttl.argtypes = [
            char_p,
            c_int,
            c_int64,
            int64_p,
            int_p,
        ]
        self._lib.nhe_o_kv_ttl.restype = None

        self._lib.nhe_o_kv_incr_by.argtypes = [
            char_p,
            c_int,
            c_int64,
            c_int64,
            int64_p,
            int_p,
        ]
        self._lib.nhe_o_kv_incr_by.restype = None

        self._lib.nhe_o_pubsub_subscribe.argtypes = [
            char_p,
            c_int,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_pubsub_subscribe.restype = None

        self._lib.nhe_o_pubsub_unsubscribe.argtypes = [
            c_int,
            int_p,
        ]
        self._lib.nhe_o_pubsub_unsubscribe.restype = None

        self._lib.nhe_o_pubsub_publish.argtypes = [
            char_p,
            c_int,
            char_p,
            c_int,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_pubsub_publish.restype = None

        self._lib.nhe_o_pubsub_poll.argtypes = [
            c_int,
            char_p,
            int_p,
            char_p,
            int_p,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_pubsub_poll.restype = None

        self._lib.nhe_o_rag_ingest_3d.argtypes = [
            c_int,
            char_p,
            c_int,
            c_float,
            c_float,
            c_float,
            c_int,
            int_p,
        ]
        self._lib.nhe_o_rag_ingest_3d.restype = None

        self._lib.nhe_o_rag_ingest_nd.argtypes = [
            c_int,
            char_p,
            c_int,
            float_p,
            c_int,
            c_int,
            int_p,
        ]
        self._lib.nhe_o_rag_ingest_nd.restype = None

        self._lib.nhe_o_rag_ingest_full_nd.argtypes = [
            c_int,
            char_p,
            c_int,
            char_p,
            c_int,
            char_p,
            c_int,
            float_p,
            c_int,
            c_int,
            int_p,
        ]
        self._lib.nhe_o_rag_ingest_full_nd.restype = None

        self._lib.nhe_o_rag_delete.argtypes = [
            c_int,
            int_p,
        ]
        self._lib.nhe_o_rag_delete.restype = None

        self._lib.nhe_o_rag_query_3d.argtypes = [
            c_float,
            c_float,
            c_float,
            c_int,
            char_p,
            c_int,
            c_int,
            int_p,
            int_p,
            float_p,
            int_p,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_rag_query_3d.restype = None

        self._lib.nhe_o_rag_query_nd.argtypes = [
            float_p,
            c_int,
            c_int,
            char_p,
            c_int,
            c_int,
            int_p,
            int_p,
            float_p,
            char_p,
            int_p,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_rag_query_nd.restype = None

        self._lib.nhe_o_rag_query_full_nd.argtypes = [
            float_p,
            c_int,
            c_int,
            char_p,
            c_int,
            char_p,
            c_int,
            c_int,
            int_p,
            int_p,
            float_p,
            char_p,
            int_p,
            int_p,
            int_p,
        ]
        self._lib.nhe_o_rag_query_full_nd.restype = None

    def version(self) -> tuple[int, int]:
        return (
            int(self._lib.nhe_o_version_major()),
            int(self._lib.nhe_o_version_minor()),
        )

    def init(self) -> None:
        status = c_int(0)
        self._lib.nhe_o_init(byref(status))
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_init failed with status {status.value}")

    def init_with_paths(self, db_path: str, wal_path: str, dim: int = 3) -> None:
        if not db_path.strip() or not wal_path.strip():
            raise ValueError("Paths must not be empty or whitespace")
        if "\x00" in db_path or "\x00" in wal_path:
            raise ValueError("Paths must not contain embedded NUL bytes")
        if db_path == wal_path:
            raise ValueError("db_path and wal_path must be distinct")
        db_buf, db_len = _make_text_buf(db_path)
        wal_buf, wal_len = _make_text_buf(wal_path)
        status = c_int(0)
        self._lib.nhe_o_init_with_paths(
            db_buf, db_len, wal_buf, wal_len, c_int(dim), byref(status)
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_init_with_paths failed: {status.value}")

    def analyze_sql(self, query: str) -> dict[str, Any]:
        q_buf, q_len = _make_text_buf(query)
        stmt_kind = c_int(0)
        has_vec = c_int(0)
        has_jsonb = c_int(0)
        status = c_int(0)
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
            raise RuntimeError(f"nhe_o_vector_distance_3d failed: {status.value}")
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
        self._lib.nhe_o_vector_distance_nd(
            a_buf,
            b_buf,
            c_int(dim),
            byref(l2_dist),
            byref(cos_dist),
            byref(hamming),
            byref(status),
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_vector_distance_nd failed: {status.value}")
        return {
            "l2_distance": float(l2_dist.value),
            "cosine_distance": float(cos_dist.value),
            "hamming_distance": int(hamming.value),
        }

    def kv_set(
        self, key: str, val: str, now_sec: int = 1000, ttl_sec: int = 0
    ) -> None:
        k_buf, k_len = _make_ident_buf(key)
        v_buf, v_len = _make_text_buf(val)
        status = c_int(0)
        self._lib.nhe_o_kv_set(
            k_buf,
            k_len,
            v_buf,
            v_len,
            c_int64(now_sec),
            c_int64(ttl_sec),
            byref(status),
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_kv_set failed: {status.value}")

    def kv_get(self, key: str, now_sec: int = 1000) -> str | None:
        k_buf, k_len = _make_ident_buf(key)
        out_buf = TextBuffer()
        out_len = c_int(0)
        status = c_int(0)
        self._lib.nhe_o_kv_get(
            k_buf,
            k_len,
            c_int64(now_sec),
            out_buf,
            byref(out_len),
            byref(status),
        )
        if status.value in (STATUS_NOT_FOUND, STATUS_EXPIRED):
            return None
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_kv_get failed: {status.value}")
        return bytes(out_buf[: out_len.value]).decode("utf-8")

    def kv_del(self, key: str) -> bool:
        k_buf, k_len = _make_ident_buf(key)
        removed = c_int(0)
        status = c_int(0)
        self._lib.nhe_o_kv_del(k_buf, k_len, byref(removed), byref(status))
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_kv_del failed: {status.value}")
        return bool(removed.value)

    def kv_exists(self, key: str, now_sec: int = 1000) -> bool:
        k_buf, k_len = _make_ident_buf(key)
        exists = c_int(0)
        status = c_int(0)
        self._lib.nhe_o_kv_exists(
            k_buf, k_len, c_int64(now_sec), byref(exists), byref(status)
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_kv_exists failed: {status.value}")
        return bool(exists.value)

    def kv_expire(self, key: str, ttl_sec: int, now_sec: int = 1000) -> bool:
        k_buf, k_len = _make_ident_buf(key)
        updated = c_int(0)
        status = c_int(0)
        self._lib.nhe_o_kv_expire(
            k_buf,
            k_len,
            c_int64(now_sec),
            c_int64(ttl_sec),
            byref(updated),
            byref(status),
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_kv_expire failed: {status.value}")
        return bool(updated.value)

    def kv_ttl(self, key: str, now_sec: int = 1000) -> int:
        k_buf, k_len = _make_ident_buf(key)
        ttl_val = c_int64(0)
        status = c_int(0)
        self._lib.nhe_o_kv_ttl(
            k_buf, k_len, c_int64(now_sec), byref(ttl_val), byref(status)
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_kv_ttl failed: {status.value}")
        return int(ttl_val.value)

    def kv_incr_by(self, key: str, delta: int, now_sec: int = 1000) -> int:
        k_buf, k_len = _make_ident_buf(key)
        new_val = c_int64(0)
        status = c_int(0)
        self._lib.nhe_o_kv_incr_by(
            k_buf,
            k_len,
            c_int64(delta),
            c_int64(now_sec),
            byref(new_val),
            byref(status),
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_kv_incr_by failed: {status.value}")
        return int(new_val.value)

    def pubsub_subscribe(self, pattern: str) -> int:
        p_buf, p_len = _make_ident_buf(pattern)
        sub_id = c_int(0)
        status = c_int(0)
        self._lib.nhe_o_pubsub_subscribe(p_buf, p_len, byref(sub_id), byref(status))
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_pubsub_subscribe failed: {status.value}")
        return int(sub_id.value)

    def pubsub_unsubscribe(self, sub_id: int) -> None:
        status = c_int(0)
        self._lib.nhe_o_pubsub_unsubscribe(c_int(sub_id), byref(status))
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_pubsub_unsubscribe failed: {status.value}")

    def pubsub_publish(self, channel: str, payload: str) -> int:
        c_buf, c_len = _make_ident_buf(channel)
        p_buf, p_len = _make_text_buf(payload)
        delivered = c_int(0)
        status = c_int(0)
        self._lib.nhe_o_pubsub_publish(
            c_buf, c_len, p_buf, p_len, byref(delivered), byref(status)
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_pubsub_publish failed: {status.value}")
        return int(delivered.value)

    def pubsub_poll(self, sub_id: int) -> tuple[str, str] | None:
        c_buf = IdentBuffer()
        c_len = c_int(0)
        p_buf = TextBuffer()
        p_len = c_int(0)
        found = c_int(0)
        status = c_int(0)
        self._lib.nhe_o_pubsub_poll(
            c_int(sub_id),
            c_buf,
            byref(c_len),
            p_buf,
            byref(p_len),
            byref(found),
            byref(status),
        )
        if status.value == STATUS_NOT_FOUND or not found.value:
            if status.value not in (STATUS_OK, STATUS_NOT_FOUND):
                raise RuntimeError(f"nhe_o_pubsub_poll failed: {status.value}")
            return None
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_pubsub_poll failed: {status.value}")
        chan = bytes(c_buf[: c_len.value]).decode("utf-8")
        payload = bytes(p_buf[: p_len.value]).decode("utf-8")
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
        m_buf, m_len = _make_text_buf(metadata_json)
        s_buf, s_len = _make_text_buf(summary)
        p_buf, p_len = _make_toast_buf(parent_text if parent_text is not None else summary)
        v_buf, dim = _make_vec_buf(vec)
        status = c_int(0)
        self._lib.nhe_o_rag_ingest_full_nd(
            c_int(doc_id),
            m_buf,
            m_len,
            s_buf,
            s_len,
            p_buf,
            p_len,
            v_buf,
            c_int(dim),
            c_int(related_doc_id),
            byref(status),
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_rag_ingest_full_nd failed: {status.value}")

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
        self._lib.nhe_o_rag_delete(c_int(doc_id), byref(status))
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_rag_delete failed: {status.value}")

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
        self._lib.nhe_o_rag_query_full_nd(
            q_buf,
            c_int(dim),
            c_int(encoding_mode),
            f_buf,
            f_len,
            k_buf,
            k_len,
            c_int(top_k),
            byref(hit_count),
            byref(top_doc_id),
            byref(top_dist),
            parent_buf,
            byref(parent_bytes),
            byref(graph_hit),
            byref(status),
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_rag_query_full_nd failed: {status.value}")
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


def run_self_test() -> None:
    # Verify exported capacity constants match SPARK specs
    assert MIN_DOC_ID == 1 and MAX_DOC_ID == 16
    assert MAX_RAG_DOCS == 16
    assert MAX_CLOG_ENTRIES == 8192 and MAX_KV_KEYS == 64 and MAX_SUBSCRIBERS == 16

    # Verify single-path argument rejection
    try:
        NheOEngine(db_path="/tmp/only_one.db")
        assert False, "Expected ValueError when only db_path is provided"
    except ValueError:
        pass

    engine = NheOEngine()
    assert engine.version() == (0, 3), f"Unexpected version: {engine.version()}"

    sql_info = engine.analyze_sql(
        "SELECT id FROM docs WHERE meta @> $1::jsonb ORDER BY emb <-> $2;"
    )
    assert sql_info["status"] == STATUS_OK
    assert sql_info["has_vector_op"] is True
    assert sql_info["has_jsonb_op"] is True

    # Verify multi-statement SQL injection, duplicate clauses, and empty FROM rejection
    for invalid_sql in (
        "SELECT 1; DROP TABLE docs;",
        "SELECT id FROM docs WHERE x = 1 WHERE y = 2;",
        "SELECT id FROM docs WHERE x = 1 ORDER BY id WHERE y = 2;",
        "SELECT id FROM WHERE x = 1;",
    ):
        bad_sql = engine.analyze_sql(invalid_sql)
        assert bad_sql["status"] == STATUS_INVALID_SYNTAX, f"Expected invalid syntax for: {invalid_sql}"

    dist = engine.vector_distance_3d((1.0, 2.0, 2.0), (4.0, 6.0, 2.0))
    assert abs(dist["l2_distance"] - 5.0) < 0.01

    vec_4096_a = [1.0 if i == 0 else 0.0 for i in range(4096)]
    vec_4096_b = [0.0 if i == 0 else (1.0 if i == 4095 else 0.0) for i in range(4096)]
    dist_nd = engine.vector_distance_nd(vec_4096_a, vec_4096_b)
    assert abs(dist_nd["l2_distance"] - math.sqrt(2.0)) < 0.01
    assert dist_nd["hamming_distance"] == 2

    engine.kv_set("llm:prompt:qwen", "Formally verified SPARK RAG", now_sec=100, ttl_sec=60)
    assert engine.kv_exists("llm:prompt:qwen", now_sec=120) is True
    assert engine.kv_ttl("llm:prompt:qwen", now_sec=120) == 40
    assert engine.kv_get("llm:prompt:qwen", now_sec=120) == "Formally verified SPARK RAG"
    assert engine.kv_expire("llm:prompt:qwen", ttl_sec=10, now_sec=120) is True
    assert engine.kv_ttl("llm:prompt:qwen", now_sec=125) == 5
    assert engine.kv_get("llm:prompt:qwen", now_sec=200) is None
    assert engine.kv_exists("llm:prompt:qwen", now_sec=200) is False
    assert engine.kv_incr_by("llm:tokens", 42, now_sec=200) == 42

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
    assert polled is not None and polled[0] == "rag.indexed"
    engine.pubsub_unsubscribe(sub_id)

    rag_res = engine.rag_query_3d(
        (1.0, 0.0, 0.0),
        encoding_mode=ENCODING_FLOAT32,
        keyword="SPARK",
        top_k=2,
        filter_json='{"lang":"vi","nested":{"sub":{"b":2,"a":1}}}',
    )
    assert rag_res["hit_count"] == 1
    assert rag_res["top_doc_id"] == 1
    assert rag_res["top_parent_bytes"] == len(large_parent)
    assert rag_res["top_parent_text"] == large_parent
    assert rag_res["graph_neighbor_hit"] is True

    # Verify N-D (4096-D) RAG with custom paths, persistence across restart,
    # lossless "RMET" summary (>63B) + JSONB metadata recovery,
    # durable KV incr_by/expire recovery, and durable deletion
    db_4096 = Path("/tmp/nhe_o_py_4096.db")
    wal_4096 = Path("/tmp/nhe_o_py_4096.wal")
    db_4096.unlink(missing_ok=True)
    wal_4096.unlink(missing_ok=True)

    engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096)
    engine.kv_set("persist:key", "survived_restart", now_sec=100, ttl_sec=0)
    assert engine.kv_expire("persist:key", ttl_sec=500, now_sec=100) is True
    assert engine.kv_incr_by("persist:counter", 99, now_sec=100) == 99
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
    assert engine.kv_get("persist:key", now_sec=105) == "survived_restart"
    assert engine.kv_ttl("persist:key", now_sec=105) == 495
    assert engine.kv_get("persist:counter", now_sec=105) == "99"
    assert engine.kv_incr_by("persist:counter", 1, now_sec=105) == 100
    rag_4096 = engine.rag_query_full_nd(
        vec_4096_b,
        encoding_mode=ENCODING_FLOAT32,
        top_k=2,
        filter_json='{"model":"qwen3-35b-a3b-long-metadata","tier":"prod","num":1}',
    )
    assert rag_4096["hit_count"] == 2
    assert rag_4096["top_doc_id"] == 2
    assert rag_4096["top_parent_text"] == "Qwen3 4096-D embedding chunk B"
    assert rag_4096["graph_neighbor_hit"] is True

    # Verify tail keyword >63B matches after recovery, and self-loop is rejected
    rag_rmet = engine.rag_query_full_nd(
        vec_4096_a,
        encoding_mode=ENCODING_FLOAT32,
        keyword="RMET_TAIL_TOKEN",
        top_k=1,
        filter_json='{"model":"qwen3-35b-a3b-long-metadata","num":1}',
    )
    assert rag_rmet["hit_count"] == 1
    assert rag_rmet["top_doc_id"] == 1
    assert rag_rmet["graph_neighbor_hit"] is False

    # Also verify Stage-2 TOAST re-ranking in INT8_SQ8 mode on 4096-D
    rag_4096_sq8 = engine.rag_query_full_nd(
        vec_4096_b,
        encoding_mode=ENCODING_INT8_SQ8,
        top_k=2,
        filter_json='{"model":"qwen3-35b-a3b-long-metadata","tier":"prod"}',
    )
    assert rag_4096_sq8["hit_count"] == 2
    assert rag_4096_sq8["top_doc_id"] == 2

    # Durable delete of doc 2 and verify survival across restart
    engine.rag_delete(2)
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096)
    rag_after_del = engine.rag_query_full_nd(
        vec_4096_b, encoding_mode=ENCODING_FLOAT32, top_k=2
    )
    assert rag_after_del["hit_count"] == 1
    assert rag_after_del["top_doc_id"] == 1

    # Verify corrupted VTST/RMET TOAST page in DB file is rejected on recovery
    wal_4096.unlink(missing_ok=True)
    db_bytes = bytearray(db_4096.read_bytes())
    # Corrupt Doc 1's VTST vector TOAST Page 11 (offset 11 * 4096 + 32; Next_TOAST_Pg starts at 10)
    db_bytes[11 * 4096 + 32] ^= 0xFF
    db_4096.write_bytes(bytes(db_bytes))
    try:
        engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096)
        assert False, "Expected RuntimeError on corrupted TOAST page during recovery"
    except RuntimeError:
        pass

    # Verify torn WAL file is rejected by init_with_paths
    wal_4096.write_bytes(b"TORN_WAL_FRAME")
    try:
        engine.init_with_paths(str(db_4096), str(wal_4096), dim=4096)
        assert False, "Expected RuntimeError on torn WAL file"
    except RuntimeError:
        pass

    # Verify identical db_path and wal_path is rejected
    assert MAX_KV_KEYS == 64
    try:
        engine.init_with_paths(str(db_4096), str(db_4096), dim=3)
        assert False, "Expected ValueError when db_path == wal_path"
    except ValueError:
        pass

    # Verify truncated 1-page (4096 B) .db file is rejected by init_with_paths
    wal_4096.unlink(missing_ok=True)
    db_4096.write_bytes(b"\x00" * 4096)
    try:
        engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
        assert False, "Expected RuntimeError on truncated 1-page .db file"
    except RuntimeError:
        pass

    # Verify trailing garbage bytes after a valid WAL frame or corrupted
    # parent chunk TOAST page (Page 10) on disk are rejected
    db_4096.unlink(missing_ok=True)
    wal_4096.unlink(missing_ok=True)
    engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
    engine.rag_ingest_3d(1, "Parent chunk integrity test", (1.0, 2.0, 3.0))
    # Append 7 trailing garbage bytes to the valid WAL file
    wal_4096.write_bytes(wal_4096.read_bytes() + b"GARBAGE")
    try:
        engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
        assert False, "Expected RuntimeError on WAL file with trailing torn bytes"
    except RuntimeError:
        pass

    # Remove WAL and corrupt parent chunk TOAST Page 10 in DB file
    wal_4096.unlink(missing_ok=True)
    db_bytes = bytearray(db_4096.read_bytes())
    db_bytes[10 * 4096 + 24] ^= 0xFF
    db_4096.write_bytes(bytes(db_bytes))
    try:
        engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
        assert False, "Expected RuntimeError on corrupted parent chunk TOAST page during recovery"
    except RuntimeError:
        pass

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
        assert res_bad["status"] == STATUS_INVALID_SYNTAX, f"Expected syntax error for: {bad_sql}"
    res_param = engine.analyze_sql("SELECT col$1abc FROM docs")
    assert res_param["status"] == STATUS_OK
    assert res_param["has_vector_op"] is False

    # Verify pubsub_poll raises RuntimeError on out-of-range sub_id
    try:
        engine.pubsub_poll(999)
        assert False, "Expected RuntimeError on invalid sub_id in pubsub_poll"
    except RuntimeError:
        pass

    # Verify init_with_paths rejects WAL/DB where Max_Seen_Tx == Max_Tx_Id (8192)
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
    try:
        engine.init_with_paths(str(db_4096), str(wal_4096), dim=3)
        assert False, "Expected RuntimeError (Capacity Exceeded) when WAL Tx_Id == Max_Tx_Id (8192)"
    except RuntimeError as exc:
        assert str(STATUS_CAPACITY_EXCEEDED) in str(exc)

    db_4096.unlink(missing_ok=True)
    wal_4096.unlink(missing_ok=True)

    print("[PASS] Python ctypes SDK (`bindings/python/nhe_o.py`) verified against `libnhe_o.so`!")


if __name__ == "__main__":
    run_self_test()


