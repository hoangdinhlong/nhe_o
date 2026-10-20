/*
 * nhe_o.h — C99 / C++17 Foreign Function Interface Header for Nhe_O
 *
 * Formally verified embedded PostgreSQL + pgvector + Redis + Hybrid RAG engine
 * written in 100% Ada/SPARK 2022 (pragma SPARK_Mode (On);).
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
#define NHE_O_TOP_K_MIN        1
#define NHE_O_TOP_K_MAX        8
#define NHE_O_MAX_TX_ID        8192
#define NHE_O_MAX_CLOG_ENTRIES 8192
#define NHE_O_MAX_WAL_FRAMES   4096
#define NHE_O_MAX_KV_KEYS      64

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

/* Initialize / reset embedded Nhe_O runtime state (default paths, 3D vectors) */
void nhe_o_init(int *out_status);

/* Initialize embedded Nhe_O runtime state with custom DB/WAL paths & dimension (1..4096),
 * recovering existing WAL/DB state when present on disk */
void nhe_o_init_with_paths(
    const char *db_path_buf,
    int         db_path_len,
    const char *wal_path_buf,
    int         wal_path_len,
    int         dim,
    int        *out_status
);

/* Analyze a PostgreSQL-dialect SQL statement */
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

/* Redis-compatible Key-Value Cache operations */
void nhe_o_kv_set(
    const char *key_buf,
    int         key_len,
    const char *val_buf,
    int         val_len,
    int64_t     now_sec,
    int64_t     ttl_sec,
    int        *out_status
);

void nhe_o_kv_get(
    const char *key_buf,
    int         key_len,
    int64_t     now_sec,
    char       *out_val_buf,
    int        *out_val_len,
    int        *out_status
);

void nhe_o_kv_del(
    const char *key_buf,
    int         key_len,
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

/* Dual-Mode Ring-Buffer & Durable WAL Pub/Sub Broker operations */
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

void nhe_o_pubsub_poll(
    int   sub_id,
    char *out_chan_buf,
    int  *out_chan_len,
    char *out_payload_buf,
    int  *out_payload_len,
    int  *out_found,
    int  *out_status
);

/* Universal Hybrid RAG (B+Tree + HNSW + TOAST Parent Chunks + GraphRAG + WAL) */
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
