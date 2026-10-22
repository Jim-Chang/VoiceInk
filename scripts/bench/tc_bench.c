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
// list.tsv 每行「id<TAB>wav 路徑」,wav 要 16kHz。輸出每段一行 JSON。
//
// 詞彙表(--vocabulary-file,一行一個詞)和 --prompt 要 transcribe.cpp 0.3.0 以後的標頭檔,編譯時加
// -DTC_PROMPTING(TEA 詞彙表的量測,見 docs/plan/2026-10-22-tea-vocabulary.md)。也可以連結 release 的
// xcframework(FW=.../TranscribeCpp.xcframework/macos-arm64_x86_64):
//   cc -O2 [-DTC_PROMPTING] -I $FW/CTranscribe.framework/Headers -I $TC/examples/common tc_bench.c \
//      -F $FW -framework CTranscribe -Wl,-rpath,$FW -o tc_bench

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

static void run_one(struct transcribe_model * model, const float * pcm, int n, const opts_t * o, result_t * r) {
    memset(r, 0, sizeof(*r));
    size_t cap = 4096, len = 0;
    r->text = calloc(cap, 1);
    r->ok = 1;
    double t0 = now_ms();
    int start = 0;
    while (start < n) {
        int end = n;
        if (o->max_chunk > 0 && n - start > o->max_chunk) {
            int max_end = start + o->max_chunk;
            int search = o->boundary < o->max_chunk ? o->boundary : o->max_chunk;
            if (search < 1) search = 1;
            int split = quietest(pcm, max_end - search > start ? max_end - search : start, max_end, o->window);
            end = split > start + 1 ? split : start + 1;
        }
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
        transcribe_run_params_init(&rp);
        rp.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
        rp.itn = o->itn;
        rp.language = o->language;
        rp.keep_special_tags = false;
#ifdef TC_PROMPTING
        rp.vocabulary = o->vocabulary;
        rp.n_vocabulary = o->n_vocabulary;
        rp.prompt = o->prompt;
#endif
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

int main(int argc, char ** argv) {
    const char * model_path = NULL, * list_path = NULL, * out_path = NULL;
    opts_t o = { NULL, TRANSCRIBE_ITN_MODE_DEFAULT, 0, 3, 1600, 0, NULL, 0, NULL };
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
        else { fprintf(stderr, "unknown or incomplete option: %s\n", a); return 2; }
    }
    o.boundary *= 16000;
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
