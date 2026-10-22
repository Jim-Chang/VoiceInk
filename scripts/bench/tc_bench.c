// 換語音辨識模型的調查:用 transcribe.cpp 的 C API 離線跑同一批錄音,量每段的辨識時間。
//
// 做法照 VoiceInk 的 OfflineTranscribeCppService:
// - 模型載入一次(Metal),之後每一段(或每一小段)各開一個 session,用完就釋放。
// - 錄音超過 --max-chunk-sec 時,在最後 --boundary-sec 秒裡找最安靜的地方切
//   (energyAwareChunks / quietestWindowStart 的同一套算法)。中文各段直接接起來。
// - 第一段先跑一次暖機,不記。載入時間另外記(App 在錄音開始時載入)。
//
// 編譯(transcribe.cpp 的 include、examples/common/dr_wav.h、build/lib):
//   cc -O2 -I $TC/include -I $TC/examples/common tc_bench.c -L $TC/build/lib -ltranscribe \
//      -Wl,-rpath,$TC/build/lib -o tc_bench
// 用法:
//   tc_bench -m model.gguf -i list.tsv -o out.jsonl [-l zh] [--itn on|off|default]
//            [--max-chunk-sec 0] [--boundary-sec 3] [--window 1600] [--n-ctx 0] [--backend metal|cpu]
//            [--vocabulary-file terms.txt] [--prompt 文字]
//            [--batch N [--sort-length] [--retry-split] [--min-retry-sec 4]]
// list.tsv 每行「id<TAB>wav 路徑」,wav 要 16kHz。輸出每段一行 JSON。
//
// 詞彙表(--vocabulary-file,一行一個詞)和 --prompt 要 transcribe.cpp 0.3.0 以後的標頭檔,編譯時加
// -DTC_PROMPTING(TEA 詞彙表的量測,見 docs/plan/2026-10-22-tea-vocabulary.md)。也可以連結 release 的
// xcframework(FW=.../TranscribeCpp.xcframework/macos-arm64_x86_64):
//   cc -O2 [-DTC_PROMPTING] -I $FW/CTranscribe.framework/Headers -I $TC/examples/common tc_bench.c \
//      -F $FW -framework CTranscribe -Wl,-rpath,$FW -o tc_bench
//
// 批次(--batch N,要 transcribe.cpp 0.4.0 的 transcribe_run_batch;見 docs/plan/2026-10-23-tea-batch.md):
//   每個錄音先照 --max-chunk-sec 切段,所有段照順序每 N 段送一次 transcribe_run_batch(一批一個 session)。
//   --sort-length:先依長度排序再分批,辨識完照原順序接回。
//   --retry-split:某段鬼打牆停下(OUTPUT_REPETITION / OUTPUT_TRUNCATED)時照 App 的切法切兩半,
//                  所有半段一樣每 N 段一批,還是停下就再切,切到不到 --min-retry-sec(4)秒為止。
//   輸出多了每批一行({"batch":…},時間和逐段狀態)和最後一行 {"summary":…};每個錄音一行照舊,
//   加上 chunks(App 的每一段:狀態、重跑次數、文字)。

#include "transcribe.h"

#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static float * load_wav(const char * path, int * n, unsigned int * rate) {
    unsigned int ch = 0;
    drwav_uint64 frames = 0;
    float * pcm = drwav_open_file_and_read_pcm_frames_f32(path, &ch, rate, &frames, NULL);
    if (!pcm) return NULL;
    if (ch > 1) {
        for (drwav_uint64 i = 0; i < frames; ++i) {
            float acc = 0;
            for (unsigned int c = 0; c < ch; ++c) acc += pcm[i * ch + c];
            pcm[i] = acc / ch;
        }
    }
    *n = (int) frames;
    return pcm;
}

// VoiceInk 的 quietestWindowStart:在 [start, end) 每 window 個樣本算一次平均能量,取最小的。
static int quietest(const float * x, int start, int end, int window) {
    if (end - start <= window) return (start + end) / 2;
    int best = start;
    double lowest = 1e300;
    int last = end - window;
    for (int s = start;; s += window) {
        if (s > last) s = last;
        double sum = 0;
        for (int i = s; i < s + window; ++i) sum += (double) x[i] * x[i];
        double e = sum / window;
        if (e < lowest) { lowest = e; best = s; }
        if (s == last) break;
    }
    return best;
}

// VoiceInk 的 energyAwareChunks 的一步:從 start 開始的一段在哪裡結束(end 是整段的結尾)。
// 超過 max_count 就在最後 boundary 個樣本裡找最安靜的地方切。
static int chunk_end(const float * x, int start, int end, int max_count, int boundary, int window) {
    if (max_count <= 0 || end - start <= max_count) return end;
    int max_end = start + max_count;
    int search = boundary < max_count ? boundary : max_count;
    if (search < 1) search = 1;
    int split = quietest(x, max_end - search > start ? max_end - search : start, max_end, window);
    return split > start + 1 ? split : start + 1;
}

static void json_str(FILE * f, const char * s) {
    fputc('"', f);
    for (const unsigned char * p = (const unsigned char *) s; *p; ++p) {
        if (*p == '"' || *p == '\\') { fputc('\\', f); fputc(*p, f); }
        else if (*p == '\n') fputs("\\n", f);
        else if (*p < 0x20) fprintf(f, "\\u%04x", *p);
        else fputc(*p, f);
    }
    fputc('"', f);
}

typedef struct {
    const char * language;
    enum transcribe_itn_mode itn;
    int max_chunk, boundary, window, n_ctx;
    const char ** vocabulary;
    int n_vocabulary;
    const char * prompt;
} opts_t;

// 一行一個詞,略過空行;不排序、不去重(照檔案的順序送,檔案自己整理好)。
static int load_terms(const char * path, const char *** out) {
    FILE * f = fopen(path, "r");
    if (!f) return -1;
    char line[1024];
    int n = 0, cap = 0;
    const char ** terms = NULL;
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!line[0]) continue;
        if (n == cap) {
            cap = cap ? cap * 2 : 64;
            terms = realloc(terms, cap * sizeof(char *));
        }
        terms[n++] = strdup(line);
    }
    fclose(f);
    *out = terms;
    return n;
}

typedef struct {
    double wall_ms, session_ms, mel_ms, encode_ms, decode_ms;
    int n_chunks;
    int ok;
    char * text;
    char status[64];
} result_t;

static void init_run_params(struct transcribe_run_params * rp, const opts_t * o) {
    transcribe_run_params_init(rp);
    rp->timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
    rp->itn = o->itn;
    rp->language = o->language;
    rp->keep_special_tags = false;
#ifdef TC_PROMPTING
    rp->vocabulary = o->vocabulary;
    rp->n_vocabulary = o->n_vocabulary;
    rp->prompt = o->prompt;
#endif
}

static void run_one(struct transcribe_model * model, const float * pcm, int n, const opts_t * o, result_t * r) {
    memset(r, 0, sizeof(*r));
    size_t cap = 4096, len = 0;
    r->text = calloc(cap, 1);
    r->ok = 1;
    double t0 = now_ms();
    int start = 0;
    while (start < n) {
        int end = chunk_end(pcm, start, n, o->max_chunk, o->boundary, o->window);
        double s0 = now_ms();
        struct transcribe_session_params sp;
        transcribe_session_params_init(&sp);
        sp.n_ctx = o->n_ctx;
        struct transcribe_session * session = NULL;
        transcribe_status st = transcribe_session_init(model, &sp, &session);
        r->session_ms += now_ms() - s0;
        if (st != TRANSCRIBE_OK) {
            snprintf(r->status, sizeof(r->status), "session: %s", transcribe_status_string(st));
            r->ok = 0;
            break;
        }
        struct transcribe_run_params rp;
        init_run_params(&rp, o);
        st = transcribe_run(session, pcm + start, end - start, &rp);
        if (st != TRANSCRIBE_OK) {
            snprintf(r->status, sizeof(r->status), "run: %s", transcribe_status_string(st));
            r->ok = 0;
            transcribe_session_free(session);
            break;
        }
        struct transcribe_timings tm;
        transcribe_timings_init(&tm);
        if (transcribe_get_timings(session, &tm) == TRANSCRIBE_OK) {
            r->mel_ms += tm.mel_ms;
            r->encode_ms += tm.encode_ms;
            r->decode_ms += tm.decode_ms;
        }
        const char * text = transcribe_full_text(session);
        // VoiceInk 去掉每段頭尾空白後直接接起來(中文不加空格)
        while (*text == ' ' || *text == '\n' || *text == '\t') ++text;
        size_t tl = strlen(text);
        while (tl > 0 && (text[tl - 1] == ' ' || text[tl - 1] == '\n' || text[tl - 1] == '\t')) --tl;
        if (len + tl + 1 > cap) {
            cap = (len + tl + 1) * 2;
            r->text = realloc(r->text, cap);
        }
        memcpy(r->text + len, text, tl);
        len += tl;
        r->text[len] = 0;
        transcribe_session_free(session);
        r->n_chunks++;
        start = end;
    }
    r->wall_ms = now_ms() - t0;
}

// ---- 批次(--batch N) ----

typedef struct {
    int batch;        // 每批幾段;0 = 不用批次(上面的 run_one)
    int sort_length;  // 依長度排序再分批
    int retry_split;  // 停下的段切兩半重跑
    int min_retry;    // 再切的最短段長(樣本)
} batch_opts_t;

typedef struct {
    int item;                      // 第幾個錄音
    int start, len;                // 在那個錄音裡的位置(樣本)
    int depth;                     // 0 = App 的一段;切兩半重跑的半段是 1、2…
    int first_child, n_children;   // 切開時的半段(連續的編號)
    int status;                    // 這段跑出來的狀態
    char * text;
} piece_t;

typedef struct {
    piece_t * v;
    int n, cap;
    int batches, runs, retried, salvaged, failed;
    double session_ms, run_ms, main_ms, retry_ms;
} pieces_t;

static int add_piece(pieces_t * ps, int item, int start, int len, int depth) {
    if (ps->n == ps->cap) {
        ps->cap = ps->cap ? ps->cap * 2 : 256;
        ps->v = realloc(ps->v, ps->cap * sizeof(piece_t));
    }
    piece_t * p = &ps->v[ps->n];
    memset(p, 0, sizeof(*p));
    p->item = item;
    p->start = start;
    p->len = len;
    p->depth = depth;
    p->first_child = -1;
    p->status = -1;
    return ps->n++;
}

static int stopped(int status) {
    return status == TRANSCRIBE_ERR_OUTPUT_REPETITION || status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED;
}

static const char * status_name(int status) {
    if (status == TRANSCRIBE_OK) return "ok";
    if (status == TRANSCRIBE_ERR_OUTPUT_REPETITION) return "repetition";
    if (status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED) return "truncated";
    return transcribe_status_string(status);
}

static char * trimmed_copy(const char * text) {
    while (*text == ' ' || *text == '\n' || *text == '\t') ++text;
    size_t tl = strlen(text);
    while (tl > 0 && (text[tl - 1] == ' ' || text[tl - 1] == '\n' || text[tl - 1] == '\t')) --tl;
    char * s = malloc(tl + 1);
    memcpy(s, text, tl);
    s[tl] = 0;
    return s;
}

// 長的排前面;一樣長照原順序
static void sort_by_length(const pieces_t * ps, int * q, int n) {
    for (int i = 1; i < n; ++i) {
        int v = q[i], j = i - 1;
        while (j >= 0 && ps->v[q[j]].len < ps->v[v].len) { q[j + 1] = q[j]; --j; }
        q[j + 1] = v;
    }
}

// 一批:一個 session、一次 transcribe_run_batch。warmup 時不記結果。
static void run_one_batch(struct transcribe_model * model, float ** pcms, pieces_t * ps, const int * q, int m,
                          const opts_t * o, int depth, int warmup, FILE * out) {
    const float ** ptrs = malloc(m * sizeof(float *));
    int * counts = malloc(m * sizeof(int));
    double max_sec = 0, sum_sec = 0;
    for (int j = 0; j < m; ++j) {
        const piece_t * p = &ps->v[q[j]];
        ptrs[j] = pcms[p->item] + p->start;
        counts[j] = p->len;
        double sec = p->len / 16000.0;
        sum_sec += sec;
        if (sec > max_sec) max_sec = sec;
    }
    double t0 = now_ms();
    struct transcribe_session_params sp;
    transcribe_session_params_init(&sp);
    sp.n_ctx = o->n_ctx;
    struct transcribe_session * session = NULL;
    transcribe_status st = transcribe_session_init(model, &sp, &session);
    if (st != TRANSCRIBE_OK) { fprintf(stderr, "session: %s\n", transcribe_status_string(st)); exit(1); }
    double t1 = now_ms();
    struct transcribe_run_params rp;
    init_run_params(&rp, o);
    st = transcribe_run_batch(session, ptrs, counts, m, &rp);
    double t2 = now_ms();
    if (st != TRANSCRIBE_OK) { fprintf(stderr, "run_batch: %s\n", transcribe_status_string(st)); exit(1); }
    double mel = 0, enc = 0, dec = 0;
    int * statuses = malloc(m * sizeof(int));
    int * chars = malloc(m * sizeof(int));
    for (int j = 0; j < m; ++j) {
        statuses[j] = transcribe_batch_status(session, j);
        struct transcribe_timings tm;
        transcribe_timings_init(&tm);
        if (transcribe_batch_get_timings(session, j, &tm) == TRANSCRIBE_OK) {
            mel += tm.mel_ms;
            enc += tm.encode_ms;
            dec += tm.decode_ms;
        }
        char * text = trimmed_copy(transcribe_batch_full_text(session, j));
        chars[j] = (int) strlen(text);
        if (warmup) free(text);
        else {
            ps->v[q[j]].status = statuses[j];
            ps->v[q[j]].text = text;
        }
    }
    transcribe_session_free(session);
    double wall = now_ms() - t0;
    if (!warmup) {
        ps->batches++;
        ps->runs += m;
        ps->session_ms += t1 - t0;
        ps->run_ms += wall;
        if (depth == 0) ps->main_ms += wall; else ps->retry_ms += wall;
        fprintf(out, "{\"batch\":%d,\"depth\":%d,\"n\":%d,\"max_sec\":%.3f,\"sum_sec\":%.3f,\"session_ms\":%.1f,"
                     "\"run_ms\":%.1f,\"wall_ms\":%.1f,\"mel_ms\":%.1f,\"encode_ms\":%.1f,\"decode_ms\":%.1f,\"status\":[",
                ps->batches, depth, m, max_sec, sum_sec, t1 - t0, t2 - t1, wall, mel, enc, dec);
        for (int j = 0; j < m; ++j) fprintf(out, "%s\"%s\"", j ? "," : "", status_name(statuses[j]));
        fprintf(out, "],\"bytes\":[");
        for (int j = 0; j < m; ++j) fprintf(out, "%s%d", j ? "," : "", chars[j]);
        fprintf(out, "]}\n");
        fflush(out);
    }
    free(ptrs);
    free(counts);
    free(statuses);
    free(chars);
}

// 跑一層:每 batch 段一批;停下的段切開,半段全部收集起來再跑下一層。
static void run_level(struct transcribe_model * model, float ** pcms, pieces_t * ps, int * q, int nq,
                      const opts_t * o, const batch_opts_t * b, int depth, FILE * out) {
    if (b->sort_length) sort_by_length(ps, q, nq);
    int * next = NULL;
    int nn = 0, cap = 0;
    for (int i = 0; i < nq; i += b->batch) {
        int m = nq - i < b->batch ? nq - i : b->batch;
        run_one_batch(model, pcms, ps, q + i, m, o, depth, 0, out);
        for (int j = 0; j < m; ++j) {
            int idx = q[i + j];
            int status = ps->v[idx].status;
            if (status == TRANSCRIBE_OK) continue;
            if (!stopped(status)) { ps->failed++; continue; }
            if (!b->retry_split || ps->v[idx].len < b->min_retry) { ps->salvaged++; continue; }
            // App 的切法:上限設原長度六成、在中間兩成找最安靜的地方
            ps->retried++;
            int item = ps->v[idx].item, start = ps->v[idx].start, end = start + ps->v[idx].len;
            int len = ps->v[idx].len;
            int first = -1, count = 0;
            for (int s = start; s < end;) {
                int e = chunk_end(pcms[item], s, end, len * 6 / 10, len * 2 / 10, o->window);
                int child = add_piece(ps, item, s, e - s, depth + 1);
                if (first < 0) first = child;
                count++;
                if (nn == cap) { cap = cap ? cap * 2 : 16; next = realloc(next, cap * sizeof(int)); }
                next[nn++] = child;
                s = e;
            }
            ps->v[idx].first_child = first;
            ps->v[idx].n_children = count;
        }
    }
    if (nn > 0) run_level(model, pcms, ps, next, nn, o, b, depth + 1, out);
    free(next);
}

// 一段(含切開的半段)的文字照順序接起來;中文不加空格,和 run_one 一樣
static void append_text(const pieces_t * ps, int idx, char ** buf, size_t * len, size_t * cap) {
    const piece_t * p = &ps->v[idx];
    if (p->n_children > 0) {
        for (int c = 0; c < p->n_children; ++c) append_text(ps, p->first_child + c, buf, len, cap);
        return;
    }
    size_t tl = p->text ? strlen(p->text) : 0;
    if (*len + tl + 1 > *cap) {
        *cap = (*len + tl + 1) * 2;
        *buf = realloc(*buf, *cap);
    }
    if (tl) memcpy(*buf + *len, p->text, tl);
    *len += tl;
    (*buf)[*len] = 0;
}

static void count_tree(const pieces_t * ps, int idx, int * retried, int * salvaged, int * failed) {
    const piece_t * p = &ps->v[idx];
    if (p->n_children > 0) {
        (*retried)++;
        for (int c = 0; c < p->n_children; ++c) count_tree(ps, p->first_child + c, retried, salvaged, failed);
    } else if (stopped(p->status)) (*salvaged)++;
    else if (p->status != TRANSCRIBE_OK) (*failed)++;
}

static int run_batched(struct transcribe_model * model, double load_ms, char ** ids, char ** wavs, int n_items,
                       const opts_t * o, const batch_opts_t * b, FILE * out) {
    float ** pcms = calloc(n_items, sizeof(float *));
    int * lens = calloc(n_items, sizeof(int));
    pieces_t ps;
    memset(&ps, 0, sizeof(ps));
    for (int i = 0; i < n_items; ++i) {
        unsigned int rate = 0;
        pcms[i] = load_wav(wavs[i], &lens[i], &rate);
        if (!pcms[i] || rate != 16000) { fprintf(stderr, "bad wav %s (rate %u)\n", wavs[i], rate); return 1; }
        for (int s = 0; s < lens[i];) {
            int e = chunk_end(pcms[i], s, lens[i], o->max_chunk, o->boundary, o->window);
            add_piece(&ps, i, s, e - s, 0);
            s = e;
        }
    }
    int n_top = ps.n;
    int * q = malloc(n_top * sizeof(int));
    for (int i = 0; i < n_top; ++i) q[i] = i;

    // 暖機:前 N 段跑一批不記(第一次會編譯批次用的 Metal 程式)
    double w0 = now_ms();
    run_one_batch(model, pcms, &ps, q, n_top < b->batch ? n_top : b->batch, o, 0, 1, out);
    double warm_ms = now_ms() - w0;
    fprintf(out, "{\"warmup\":true,\"load_ms\":%.1f,\"wall_ms\":%.1f,\"batch\":%d,\"sort_length\":%s,\"retry_split\":%s}\n",
            load_ms, warm_ms, b->batch, b->sort_length ? "true" : "false", b->retry_split ? "true" : "false");
    fprintf(stderr, "load %.0f ms, warmup %.0f ms, %d chunks\n", load_ms, warm_ms, n_top);

    double t0 = now_ms();
    run_level(model, pcms, &ps, q, n_top, o, b, 0, out);
    double total_ms = now_ms() - t0;

    // 每個錄音一行:接起來的文字,和 App 的每一段(chunks)
    int p = 0;
    for (int i = 0; i < n_items; ++i) {
        size_t cap = 4096, len = 0;
        char * text = calloc(cap, 1);
        int retried = 0, salvaged = 0, failed = 0, first = p;
        while (p < n_top && ps.v[p].item == i) {
            append_text(&ps, p, &text, &len, &cap);
            count_tree(&ps, p, &retried, &salvaged, &failed);
            p++;
        }
        fprintf(out, "{\"id\":");
        json_str(out, ids[i]);
        fprintf(out, ",\"duration\":%.3f,\"ok\":%s,\"status\":\"\",\"n_chunks\":%d,\"retried\":%d,\"truncated\":%d,"
                     "\"failed\":%d,\"text\":",
                lens[i] / 16000.0, failed ? "false" : "true", p - first, retried, salvaged, failed);
        json_str(out, text);
        fprintf(out, ",\"chunks\":[");
        for (int c = first; c < p; ++c) {
            size_t ccap = 1024, clen = 0;
            char * ctext = calloc(ccap, 1);
            append_text(&ps, c, &ctext, &clen, &ccap);
            int cr = 0, cs = 0, cf = 0;
            count_tree(&ps, c, &cr, &cs, &cf);
            fprintf(out, "%s{\"start\":%.3f,\"sec\":%.3f,\"status\":\"%s\",\"retried\":%d,\"truncated\":%d,\"text\":",
                    c > first ? "," : "", ps.v[c].start / 16000.0, ps.v[c].len / 16000.0, status_name(ps.v[c].status),
                    cr, cs);
            json_str(out, ctext);
            fputc('}', out);
            free(ctext);
        }
        fprintf(out, "]}\n");
        free(text);
    }
    fprintf(out, "{\"summary\":true,\"batch\":%d,\"chunks\":%d,\"runs\":%d,\"batches\":%d,\"retried\":%d,\"truncated\":%d,"
                 "\"failed\":%d,\"total_ms\":%.1f,\"run_ms\":%.1f,\"main_ms\":%.1f,\"retry_ms\":%.1f,\"session_ms\":%.1f}\n",
            b->batch, n_top, ps.runs, ps.batches, ps.retried, ps.salvaged, ps.failed, total_ms, ps.run_ms, ps.main_ms,
            ps.retry_ms, ps.session_ms);
    fprintf(stderr, "batch %d: %d chunks, %d runs in %d batches, retried %d, truncated %d, failed %d, %.1f s\n",
            b->batch, n_top, ps.runs, ps.batches, ps.retried, ps.salvaged, ps.failed, total_ms / 1000);
    for (int i = 0; i < ps.n; ++i) free(ps.v[i].text);
    free(ps.v);
    free(q);
    for (int i = 0; i < n_items; ++i) free(pcms[i]);
    free(pcms);
    free(lens);
    return 0;
}

int main(int argc, char ** argv) {
    const char * model_path = NULL, * list_path = NULL, * out_path = NULL;
    opts_t o = { NULL, TRANSCRIBE_ITN_MODE_DEFAULT, 0, 3, 1600, 0, NULL, 0, NULL };
    batch_opts_t b = { 0, 0, 0, 4 };
    transcribe_backend_request backend = TRANSCRIBE_BACKEND_METAL;
    for (int i = 1; i < argc; ++i) {
        const char * a = argv[i];
        const char * v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "-m") && v) { model_path = v; ++i; }
        else if (!strcmp(a, "-i") && v) { list_path = v; ++i; }
        else if (!strcmp(a, "-o") && v) { out_path = v; ++i; }
        else if (!strcmp(a, "-l") && v) { o.language = v; ++i; }
        else if (!strcmp(a, "--itn") && v) {
            o.itn = !strcmp(v, "on") ? TRANSCRIBE_ITN_MODE_ON : !strcmp(v, "off") ? TRANSCRIBE_ITN_MODE_OFF : TRANSCRIBE_ITN_MODE_DEFAULT;
            ++i;
        }
        else if (!strcmp(a, "--max-chunk-sec") && v) { o.max_chunk = atoi(v) * 16000; ++i; }
        else if (!strcmp(a, "--boundary-sec") && v) { o.boundary = atoi(v); ++i; }
        else if (!strcmp(a, "--window") && v) { o.window = atoi(v); ++i; }
        else if (!strcmp(a, "--n-ctx") && v) { o.n_ctx = atoi(v); ++i; }
        else if (!strcmp(a, "--backend") && v) { backend = !strcmp(v, "cpu") ? TRANSCRIBE_BACKEND_CPU : TRANSCRIBE_BACKEND_METAL; ++i; }
        else if (!strcmp(a, "--vocabulary-file") && v) {
            o.n_vocabulary = load_terms(v, &o.vocabulary);
            if (o.n_vocabulary < 0) { fprintf(stderr, "cannot open %s\n", v); return 1; }
            ++i;
        }
        else if (!strcmp(a, "--prompt") && v) { o.prompt = v; ++i; }
        else if (!strcmp(a, "--batch") && v) { b.batch = atoi(v); ++i; }
        else if (!strcmp(a, "--sort-length")) b.sort_length = 1;
        else if (!strcmp(a, "--retry-split")) b.retry_split = 1;
        else if (!strcmp(a, "--min-retry-sec") && v) { b.min_retry = atoi(v); ++i; }
        else { fprintf(stderr, "unknown or incomplete option: %s\n", a); return 2; }
    }
    o.boundary *= 16000;
    b.min_retry *= 16000;
    if ((b.sort_length || b.retry_split) && b.batch < 1) {
        fprintf(stderr, "--sort-length / --retry-split need --batch N (N >= 1)\n");
        return 2;
    }
#ifndef TC_PROMPTING
    if (o.n_vocabulary > 0 || o.prompt) {
        fprintf(stderr, "--vocabulary-file / --prompt need a build with -DTC_PROMPTING (transcribe.cpp >= 0.3.0)\n");
        return 2;
    }
#endif
    if (!model_path || !list_path || !out_path) {
        fprintf(stderr, "usage: %s -m model.gguf -i list.tsv -o out.jsonl [options]\n", argv[0]);
        return 2;
    }

    char ** ids = NULL, ** wavs = NULL;
    int n_items = 0, cap_items = 0;
    FILE * lf = fopen(list_path, "r");
    if (!lf) { fprintf(stderr, "cannot open %s\n", list_path); return 1; }
    char line[4096];
    while (fgets(line, sizeof(line), lf)) {
        line[strcspn(line, "\r\n")] = 0;
        char * tab = strchr(line, '\t');
        if (!tab) continue;
        *tab = 0;
        if (n_items == cap_items) {
            cap_items = cap_items ? cap_items * 2 : 128;
            ids = realloc(ids, cap_items * sizeof(char *));
            wavs = realloc(wavs, cap_items * sizeof(char *));
        }
        ids[n_items] = strdup(line);
        wavs[n_items] = strdup(tab + 1);
        n_items++;
    }
    fclose(lf);
    if (n_items == 0) { fprintf(stderr, "empty list\n"); return 1; }

    transcribe_init_backends_default();
    double l0 = now_ms();
    struct transcribe_model_load_params mp;
    transcribe_model_load_params_init(&mp);
    mp.backend = backend;
    struct transcribe_model * model = NULL;
    transcribe_status st = transcribe_model_load_file(model_path, &mp, &model);
    if (st != TRANSCRIBE_OK) { fprintf(stderr, "load: %s\n", transcribe_status_string(st)); return 1; }
    double load_ms = now_ms() - l0;

    FILE * out = fopen(out_path, "w");
    if (!out) { fprintf(stderr, "cannot write %s\n", out_path); return 1; }
    if (b.batch > 0) {
        int rc = run_batched(model, load_ms, ids, wavs, n_items, &o, &b, out);
        fclose(out);
        transcribe_model_free(model);
        return rc;
    }

    for (int i = -1; i < n_items; ++i) {
        int idx = i < 0 ? 0 : i;
        int n = 0;
        unsigned int rate = 0;
        float * pcm = load_wav(wavs[idx], &n, &rate);
        if (!pcm || rate != 16000) { fprintf(stderr, "bad wav %s (rate %u)\n", wavs[idx], rate); return 1; }
        result_t r;
        run_one(model, pcm, n, &o, &r);
        if (i < 0) {
            fprintf(out, "{\"warmup\":true,\"load_ms\":%.1f,\"wall_ms\":%.1f,\"n_vocabulary\":%d,\"prompt\":%s}\n",
                    load_ms, r.wall_ms, o.n_vocabulary, o.prompt ? "true" : "false");
            fprintf(stderr, "load %.0f ms, warmup %.0f ms\n", load_ms, r.wall_ms);
        } else {
            fprintf(out, "{\"id\":");
            json_str(out, ids[idx]);
            fprintf(out, ",\"duration\":%.3f,\"ok\":%s,\"status\":", n / 16000.0, r.ok ? "true" : "false");
            json_str(out, r.status);
            fprintf(out, ",\"wall_ms\":%.1f,\"session_ms\":%.1f,\"mel_ms\":%.1f,\"encode_ms\":%.1f,\"decode_ms\":%.1f,\"n_chunks\":%d,\"text\":",
                    r.wall_ms, r.session_ms, r.mel_ms, r.encode_ms, r.decode_ms, r.n_chunks);
            json_str(out, r.text);
            fprintf(out, "}\n");
            fflush(out);
        }
        free(r.text);
        free(pcm);
    }
    fclose(out);
    transcribe_model_free(model);
    return 0;
}
