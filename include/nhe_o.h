/*
 * nhe_o.h — C99 / C++17 Foreign Function Interface Header for Nhe_O (ABI 0.4)
 *
 * Formally verified embedded PostgreSQL + pgvector + Redis + Hybrid RAG engine
 * written in 100% Ada/SPARK 2022 (pragma SPARK_Mode (On);).
 *
 * Runtime model (read before use):
 *  - One process-wide engine. Every nhe_o_* call reads and writes the same global
 *    state, so the library is NOT thread-safe: serialize all calls (one mutex around
 *    every call). Two "handles" in one process are the same engine.
 *  - One process per database. An open database holds exclusive flock(2) locks on its
 *    database and WAL files; opening either file again, from any process or a second
 *    time in this one, fails with NHE_O_STATUS_IO_ERROR until nhe_o_close (or another
 *    open) releases them. The locks are advisory: tools that ignore flock can still
 *    change the files. The engine belongs to the process that opened it: in a forked
 *    child every stateful call returns NHE_O_STATUS_NOT_INITIALIZED, and nhe_o_close
 *    there only releases the child's inherited copies of the lock descriptors (no
 *    checkpoint, no file touched); call it in the child (or exec) if the parent is to
 *    reopen the database while the child runs.
 *  - Stack: the deepest calls (4096-D RAG ingest, recovery, checkpoint) need about
 *    256 KiB of thread stack (192 KiB overflows); call the library from a thread with
 *    at least 1 MiB of stack.
 *  - Loading the library elaborates the GNAT runtime, which installs handlers for
 *    SIGSEGV, SIGBUS, SIGFPE, SIGILL and SIGABRT; the library then resets SIGABRT to
 *    its default action, so abort() and a failed assert() still raise SIGABRT. Hosts
 *    that install their own handlers for these signals (JVM, Go, crash reporters,
 *    Python's faulthandler) must re-install them after loading; a SIGABRT handler
 *    installed before loading is replaced by the default action.
 *  - nhe_o_analyze_sql, the vector-distance calls and the version queries need no open
 *    engine; every other call returns NHE_O_STATUS_NOT_INITIALIZED without one.
 *  - Input buffers are read only up to the given length (no NUL terminator needed).
 *    Output text buffers must have the full capacity listed for each call: at most
 *    *out_*_len bytes are written, plus a trailing NUL only when the text is shorter
 *    than the capacity, so always use the returned length.
 *  - Durability: a write that returns NHE_O_STATUS_OK is durable in the WAL. After an
 *    I/O error on a durable write path the engine refuses every further write with
 *    NHE_O_STATUS_IO_ERROR (reads keep working) until nhe_o_init_with_paths reopens
 *    the database; recovery then decides from disk whether the failed write survived.
 */

#ifndef NHE_O_H
#define NHE_O_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Fixed buffer capacities and domain bounds matching Nhe_O.Types, Nhe_O.Transaction, Nhe_O.RAG, Nhe_O.KV, and Nhe_O.PubSub */
#define NHE_O_MAX_IDENT_LEN    64
#define NHE_O_MAX_TEXT_LEN     512
#define NHE_O_MAX_TOAST_BYTES  16392
#define NHE_O_MAX_VECTOR_DIM   4096
#define NHE_O_DOC_ID_MIN       1
#define NHE_O_DOC_ID_MAX       16
#define NHE_O_MIN_DOC_ID       1
#define NHE_O_MAX_DOC_ID       16
#define NHE_O_MAX_RAG_DOCS     16
#define NHE_O_SUB_ID_MIN       1
#define NHE_O_SUB_ID_MAX       16
#define NHE_O_MAX_SUBSCRIBERS  16
#define NHE_O_PUBSUB_QUEUE_CAPACITY 16  /* messages queued per subscriber */
#define NHE_O_TOP_K_MIN        1
#define NHE_O_TOP_K_MAX        8
#define NHE_O_MAX_TX_ID        8192
#define NHE_O_MAX_CLOG_ENTRIES 8192
#define NHE_O_MAX_WAL_FRAMES   4096
#define NHE_O_MAX_KV_KEYS      64
#define NHE_O_MAX_PATH_LEN     512  /* db_path_len / wal_path_len upper bound */
#define NHE_O_MAX_WAL_PATH_LEN 507  /* resolved WAL path (room for ".ckpt") */
#define NHE_O_CHECKPOINT_WAL_FRAMES 512  /* automatic checkpoint thresholds */
#define NHE_O_CHECKPOINT_TX_ID      4096

/* Status codes returned in *out_status */
typedef enum {
    NHE_O_STATUS_OK                 = 0,
    NHE_O_STATUS_NOT_FOUND          = 1,
    NHE_O_STATUS_EXPIRED            = 2,
    NHE_O_STATUS_INVALID_SYNTAX     = 3,
    NHE_O_STATUS_TYPE_MISMATCH      = 4,
    NHE_O_STATUS_DIMENSION_MISMATCH = 5,
    NHE_O_STATUS_CAPACITY_EXCEEDED  = 6,
    NHE_O_STATUS_TX_ABORTED         = 7,
    NHE_O_STATUS_IO_ERROR           = 8,
    NHE_O_STATUS_INVALID_ARG        = 9,
    NHE_O_STATUS_NOT_INITIALIZED    = 10
} nhe_o_status_t;

/* Vector quantization modes for HNSW / Hybrid RAG queries */
typedef enum {
    NHE_O_ENCODING_FLOAT32     = 0,
    NHE_O_ENCODING_INT8_SQ8    = 1,
    NHE_O_ENCODING_BINARY_1BIT = 2
} nhe_o_encoding_t;

/* Engine version queries */
int nhe_o_version_major(void);
int nhe_o_version_minor(void);

/* Initialize / reset the runtime as a scratch database (3-D vectors) on the per-process
 * files /tmp/nhe_o_c_api.<pid>.db and .wal: earlier contents are deleted and both files
 * are recreated with O_EXCL, so a link planted at these predictable names is refused,
 * and locked like any open database (NHE_O_STATUS_IO_ERROR if a file cannot be removed,
 * created or locked). A database opened before is released without a checkpoint. For
 * data that must persist, use nhe_o_init_with_paths with paths inside a private
 * directory. */
void nhe_o_init(int *out_status);

/* Initialize the runtime on caller-specified DB/WAL paths with dimension 1..4096,
 * recovering existing state (a torn WAL or database tail left by a crash is repaired).
 * A database opened before is released first (without a checkpoint).
 *  - Paths: relative paths are resolved against the current directory, and symbolic
 *    links are resolved, once, here: the engine then works on the real files (a
 *    checkpoint renames over the WAL itself, never over a link). Both lengths are
 *    1..512 bytes and the resolved WAL path at most 507 bytes (room for ".ckpt").
 *    Keep the files in a directory other users cannot write, and do not hard-link the
 *    WAL: a checkpoint replaces only the name in use, so other links keep the old WAL.
 *  - NHE_O_STATUS_INVALID_ARG, files untouched: the database, the WAL and "<wal>.ckpt"
 *    are not three different files (also through links); an existing database file
 *    is not empty and its first min(size, 4096) bytes are not all zero (the engine
 *    never writes page 0, so this refuses swapped arguments and any other file); or
 *    "<wal>.ckpt", a name reserved for the checkpoint, holds a file that is not a WAL
 *    (a leftover of an interrupted checkpoint is removed).
 *  - Missing files are created (directory fsynced) and both files are locked (see
 *    "One process per database"); a file created by a refused call is removed, except
 *    when the refusal is a lock held elsewhere.
 *  - A WAL path naming a file that is not a WAL fails with NHE_O_STATUS_IO_ERROR and
 *    is never truncated; only a file of at most 4120 bytes that starts with a frame
 *    header, or with zero bytes up to its first 4096, is taken as a torn first append.
 *  - A database written with another dimension fails with
 *    NHE_O_STATUS_DIMENSION_MISMATCH (an empty database takes the new dim). */
void nhe_o_init_with_paths(
    const char *db_path_buf,
    int         db_path_len,
    const char *wal_path_buf,
    int         wal_path_len,
    int         dim,
    int        *out_status
);

/* Release the runtime and its file locks (later stateful calls return
 * NHE_O_STATUS_NOT_INITIALIZED; closing twice is harmless). A database opened with
 * nhe_o_init_with_paths is checkpointed first (best effort) and its files are kept;
 * the scratch files of nhe_o_init are deleted. In a forked child it only drops the
 * inherited copy (no checkpoint, no file removed). */
void nhe_o_close(int *out_status);

/* Compact the WAL: write "<wal>.ckpt" with the KV entries and the frozen RAG page,
 * lock it, then rename it over the WAL and fsync the directory (a file at "<wal>.ckpt"
 * that is not a WAL makes the checkpoint fail with NHE_O_STATUS_IO_ERROR, untouched).
 * Transaction ids restart at 2.
 * Runs automatically after a durable write once the WAL holds 512 frames or an id
 * reaches 4096; an explicit call is only needed to compact earlier. */
void nhe_o_checkpoint(int *out_status);

/* Statement kinds reported in *out_stmt_kind by nhe_o_analyze_sql */
typedef enum {
    NHE_O_STMT_UNKNOWN      = 0,
    NHE_O_STMT_CREATE_TABLE = 1,
    NHE_O_STMT_INSERT       = 2,
    NHE_O_STMT_SELECT       = 3,
    NHE_O_STMT_UPDATE       = 4,
    NHE_O_STMT_DELETE       = 5,
    NHE_O_STMT_BEGIN        = 6,
    NHE_O_STMT_COMMIT       = 7,
    NHE_O_STMT_ROLLBACK     = 8,
    NHE_O_STMT_LISTEN       = 9,
    NHE_O_STMT_NOTIFY       = 10
} nhe_o_stmt_kind_t;

/* Analyze one PostgreSQL-dialect SQL statement (query_len 0..512) against the dialect
 * documented in src/nhe_o-sql.ads: NHE_O_STATUS_OK only for exactly one supported
 * statement, NHE_O_STATUS_INVALID_SYNTAX otherwise (including multi-statement input).
 * out_has_vector: <->, <=> or <#> outside literals; out_has_jsonb: ->, ->>, #>, #>>,
 * @>, <@, ?, ?|, ?&, @? or #- outside literals. */
void nhe_o_analyze_sql(
    const char *query_buf,
    int         query_len,
    int        *out_stmt_kind,
    int        *out_has_vector,
    int        *out_has_jsonb,
    int        *out_status
);

/* Compute 3D L2 distance (<->), Cosine distance (<=>), and 1-bit Hamming distance */
void nhe_o_vector_distance_3d(
    float  ax, float ay, float az,
    float  bx, float by, float bz,
    float *out_l2_dist,
    float *out_cos_dist,
    int   *out_hamming,
    int   *out_status
);

/* Compute N-D (1..4096) L2 distance (<->), Cosine distance (<=>), and 1-bit Hamming distance */
void nhe_o_vector_distance_nd(
    const float *a_buf,
    const float *b_buf,
    int          dim,
    float       *out_l2_dist,
    float       *out_cos_dist,
    int         *out_hamming,
    int         *out_status
);

/* Redis-compatible Key-Value Cache operations (keys 1..64 bytes, values 0..512 bytes,
 * at most NHE_O_MAX_KV_KEYS keys with LRU eviction). The engine has no clock: every call
 * takes the caller's now_sec (>= 0, never decreasing). A GET of an expired key returns
 * NHE_O_STATUS_EXPIRED (until a write reuses its slot). Read recency is saved only by
 * a checkpoint (nhe_o_close and the automatic checkpoint run one): after a reopen, LRU
 * order follows the recency saved by the last checkpoint, updated by later writes.
 * Deliberate Redis deviations: EXPIRE with ttl_sec <= 0 is NHE_O_STATUS_INVALID_ARG
 * (Redis deletes the key) and SET with ttl_sec = 0 stores the key without a TTL. */
void nhe_o_kv_set(
    const char *key_buf,
    int         key_len,
    const char *val_buf,
    int         val_len,
    int64_t     now_sec,
    int64_t     ttl_sec,
    int        *out_status
);

/* out_val_buf capacity: NHE_O_MAX_TEXT_LEN (512) bytes */
void nhe_o_kv_get(
    const char *key_buf,
    int         key_len,
    int64_t     now_sec,
    char       *out_val_buf,
    int        *out_val_len,
    int        *out_status
);

/* DEL at time now_sec: *out_removed = 1 iff the key was live (present, not expired) */
void nhe_o_kv_del(
    const char *key_buf,
    int         key_len,
    int64_t     now_sec,
    int        *out_removed,
    int        *out_status
);

void nhe_o_kv_exists(
    const char *key_buf,
    int         key_len,
    int64_t     now_sec,
    int        *out_exists,
    int        *out_status
);

void nhe_o_kv_expire(
    const char *key_buf,
    int         key_len,
    int64_t     now_sec,
    int64_t     ttl_sec,
    int        *out_updated,
    int        *out_status
);

void nhe_o_kv_ttl(
    const char *key_buf,
    int         key_len,
    int64_t     now_sec,
    int64_t    *out_ttl,
    int        *out_status
);

void nhe_o_kv_incr_by(
    const char *key_buf,
    int         key_len,
    int64_t     delta_val,
    int64_t     now_sec,
    int64_t    *out_new_val,
    int        *out_status
);

/* Dual-Mode Ring-Buffer & Durable WAL Pub/Sub Broker operations. Each subscriber
 * queues at most NHE_O_PUBSUB_QUEUE_CAPACITY (16) messages: a message published to a
 * subscriber whose queue is full is dropped for it (drop-newest) and not counted in
 * *out_delivered; the ABI does not report drops, so poll often enough. */
void nhe_o_pubsub_subscribe(
    const char *pattern_buf,
    int         pattern_len,
    int        *out_sub_id,
    int        *out_status
);

void nhe_o_pubsub_unsubscribe(
    int  sub_id,
    int *out_status
);

void nhe_o_pubsub_publish(
    const char *chan_buf,
    int         chan_len,
    const char *payload_buf,
    int         payload_len,
    int        *out_delivered,
    int        *out_status
);

/* out_chan_buf capacity: NHE_O_MAX_IDENT_LEN (64) bytes;
 * out_payload_buf capacity: NHE_O_MAX_TEXT_LEN (512) bytes */
void nhe_o_pubsub_poll(
    int   sub_id,
    char *out_chan_buf,
    int  *out_chan_len,
    char *out_payload_buf,
    int  *out_payload_len,
    int  *out_found,
    int  *out_status
);

/* Universal Hybrid RAG (B+Tree + HNSW + TOAST Parent Chunks + GraphRAG + WAL).
 * Each ingest/delete is one transaction; NHE_O_STATUS_OK means its commit is durable.
 * doc_id is 1..16, related_doc_id 0..16 (0 = none). The ingest_3d / ingest_nd variants
 * store the summary as the parent chunk, so summary_len must be at least 1. */
void nhe_o_rag_ingest_3d(
    int         doc_id,
    const char *summary_buf,
    int         summary_len,
    float       vx,
    float       vy,
    float       vz,
    int         related_doc_id,
    int        *out_status
);

void nhe_o_rag_ingest_nd(
    int          doc_id,
    const char  *summary_buf,
    int          summary_len,
    const float *vec_buf,
    int          dim,
    int          related_doc_id,
    int         *out_status
);

/* parent_len 0..16392 (0: the summary is the parent chunk; both 0 is invalid).
 * meta_json_len 0 (and nhe_o_rag_ingest_3d / _nd) store an empty metadata
 * object, which only the filter {} matches. */
void nhe_o_rag_ingest_full_nd(
    int          doc_id,
    const char  *meta_json_buf,
    int          meta_json_len,
    const char  *summary_buf,
    int          summary_len,
    const char  *parent_buf,
    int          parent_len,
    const float *vec_buf,
    int          dim,
    int          related_doc_id,
    int         *out_status
);

void nhe_o_rag_delete(
    int  doc_id,
    int *out_status
);

/* *out_parent_bytes: full byte length of the top hit's parent chunk (no text copied) */
void nhe_o_rag_query_3d(
    float       qx,
    float       qy,
    float       qz,
    int         encoding_mode,
    const char *keyword_buf,
    int         keyword_len,
    int         top_k,
    int        *out_hit_count,
    int        *out_top_doc_id,
    float      *out_top_distance,
    int        *out_parent_bytes,
    int        *out_graph_hit,
    int        *out_status
);

/* out_parent_buf capacity: NHE_O_MAX_TEXT_LEN (512) bytes; *out_parent_len is the number
 * of bytes written (the first 512 bytes of the parent chunk at most) */
void nhe_o_rag_query_nd(
    const float *query_vec_buf,
    int          dim,
    int          encoding_mode,
    const char  *keyword_buf,
    int          keyword_len,
    int          top_k,
    int         *out_hit_count,
    int         *out_top_doc_id,
    float       *out_top_distance,
    char        *out_parent_buf,
    int         *out_parent_len,
    int         *out_graph_hit,
    int         *out_status
);

/* out_parent_buf capacity: NHE_O_MAX_TOAST_BYTES (16392) bytes; *out_parent_len is the
 * byte length of the whole parent chunk, all of which is written */
void nhe_o_rag_query_full_nd(
    const float *query_vec_buf,
    int          dim,
    int          encoding_mode,
    const char  *filter_json_buf,
    int          filter_json_len,
    const char  *keyword_buf,
    int          keyword_len,
    int          top_k,
    int         *out_hit_count,
    int         *out_top_doc_id,
    float       *out_top_distance,
    char        *out_parent_buf,
    int         *out_parent_len,
    int         *out_graph_hit,
    int         *out_status
);

#ifdef __cplusplus
}
#endif

#endif /* NHE_O_H */
