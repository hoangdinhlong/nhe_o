#!/usr/bin/env python3
"""
nhe_o.py — Python ctypes SDK for the Formally Verified Nhé O Engine

Wraps the 100% SPARK 2014 C ABI (`Nhe_O.C_API` / `include/nhe_o.h`) so Python
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
MAX_VECTOR_DIM = 4096
MAX_COMPONENT = 1.0e6

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
        if "\x00" in db_path or "\x00" in wal_path:
            raise ValueError("Paths must not contain embedded NUL bytes")
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
        if not found.value:
            return None
        chan = bytes(c_buf[: c_len.value]).decode("utf-8")
        payload = bytes(p_buf[: p_len.value]).decode("utf-8")
        return chan, payload

    def rag_ingest_3d(
        self,
        doc_id: int,
        summary: str,
        vec: tuple[float, float, float],
        related_doc_id: int = 0,
    ) -> None:
        vx, vy, vz = _validate_float(vec[0]), _validate_float(vec[1]), _validate_float(vec[2])
        s_buf, s_len = _make_text_buf(summary)
        status = c_int(0)
        self._lib.nhe_o_rag_ingest_3d(
            c_int(doc_id),
            s_buf,
            s_len,
            c_float(vx),
            c_float(vy),
            c_float(vz),
            c_int(related_doc_id),
            byref(status),
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_rag_ingest_3d failed: {status.value}")

    def rag_ingest_nd(
        self,
        doc_id: int,
        summary: str,
        vec: Sequence[float],
        related_doc_id: int = 0,
    ) -> None:
        s_buf, s_len = _make_text_buf(summary)
        v_buf, dim = _make_vec_buf(vec)
        status = c_int(0)
        self._lib.nhe_o_rag_ingest_nd(
            c_int(doc_id),
            s_buf,
            s_len,
            v_buf,
            c_int(dim),
            c_int(related_doc_id),
            byref(status),
        )
        if status.value != STATUS_OK:
            raise RuntimeError(f"nhe_o_rag_ingest_nd failed: {status.value}")

    def rag_query_3d(
        self,
        query_vec: tuple[float, float, float],
        encoding_mode: int = ENCODING_FLOAT32,
        keyword: str = "",
        top_k: int = 3,
    ) -> dict[str, Any]:
        return self.rag_query_nd(
            query_vec, encoding_mode=encoding_mode, keyword=keyword, top_k=top_k
        )

    def rag_query_nd(
        self,
        query_vec: Sequence[float],
        encoding_mode: int = ENCODING_FLOAT32,
        keyword: str = "",
        top_k: int = 3,
    ) -> dict[str, Any]:
        q_buf, dim = _make_vec_buf(query_vec)
        k_buf, k_len = _make_text_buf(keyword)
        hit_count = c_int(0)
        top_doc_id = c_int(0)
        top_dist = c_float(0.0)
        parent_buf = TextBuffer()
        parent_bytes = c_int(0)
        graph_hit = c_int(0)
        status = c_int(0)
        self._lib.nhe_o_rag_query_nd(
            q_buf,
            c_int(dim),
            c_int(encoding_mode),
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
            raise RuntimeError(f"nhe_o_rag_query_nd failed: {status.value}")
        copy_len = min(MAX_TEXT_LEN, int(parent_bytes.value))
        parent_text = bytes(parent_buf[:copy_len]).decode("utf-8", errors="replace")
        return {
            "hit_count": int(hit_count.value),
            "top_doc_id": int(top_doc_id.value),
            "top_distance": float(top_dist.value),
            "top_parent_bytes": int(parent_bytes.value),
            "top_parent_text": parent_text,
            "graph_neighbor_hit": bool(graph_hit.value),
        }


def run_self_test() -> None:
    engine = NheOEngine()
    assert engine.version() == (0, 3), f"Unexpected version: {engine.version()}"

    sql_info = engine.analyze_sql(
        "SELECT id FROM docs WHERE meta @> $1::jsonb ORDER BY emb <-> $2;"
    )
    assert sql_info["status"] == STATUS_OK
    assert sql_info["has_vector_op"] is True
    assert sql_info["has_jsonb_op"] is True

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
    engine.rag_ingest_3d(1, "Ada SPARK formal verification guide", (1.0, 0.0, 0.0), related_doc_id=2)
    engine.rag_ingest_3d(2, "PostgreSQL TOAST overflow storage", (0.8, 0.2, 0.0), related_doc_id=1)

    polled = engine.pubsub_poll(sub_id)
    assert polled is not None and polled[0] == "rag.indexed"
    engine.pubsub_unsubscribe(sub_id)

    rag_res = engine.rag_query_3d((1.0, 0.0, 0.0), encoding_mode=ENCODING_FLOAT32, keyword="SPARK", top_k=2)
    assert rag_res["hit_count"] == 2
    assert rag_res["top_doc_id"] == 1
    assert rag_res["top_parent_text"] == "Ada SPARK formal verification guide"
    assert rag_res["graph_neighbor_hit"] is True

    # Verify N-D (4096-D) RAG with custom paths & Stage-2 TOAST Exact Re-Ranking
    engine.init_with_paths("/tmp/nhe_o_py_4096.db", "/tmp/nhe_o_py_4096.wal", dim=4096)
    engine.rag_ingest_nd(1, "Qwen3 4096-D embedding chunk A", vec_4096_a, related_doc_id=2)
    engine.rag_ingest_nd(2, "Qwen3 4096-D embedding chunk B", vec_4096_b, related_doc_id=1)
    rag_4096 = engine.rag_query_nd(vec_4096_b, encoding_mode=ENCODING_FLOAT32, top_k=2)
    assert rag_4096["hit_count"] == 2
    assert rag_4096["top_doc_id"] == 2
    assert rag_4096["top_parent_text"] == "Qwen3 4096-D embedding chunk B"

    print("[PASS] Python ctypes SDK (`bindings/python/nhe_o.py`) verified against `libnhe_o.so`!")


if __name__ == "__main__":
    run_self_test()
