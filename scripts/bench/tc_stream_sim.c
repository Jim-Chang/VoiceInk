// 邊講邊出字的調查:用 transcribe.cpp 的 C API 模擬「錄音中每隔一段時間把目前的錄音重新辨識一次」。
//
// 兩種模式:
//
// --mode prefix:每段錄音取前 2/5/10/20/30/60 秒(--prefixes),整段一次辨識,每個長度跑 --repeat 次。
//   量「已經講了 N 秒時,重新辨識一次要多久」。
//
// --mode loop:照真實時間模擬一次聽寫(錄音長度多少秒就跑多少秒):
//   - 第 --first 秒開始(App 開始錄音時載入模型約 1 秒),辨識「目前這一段」:從上次切點到現在的錄音。
//     辨識完等 --interval 秒再辨識下一次(和 VoiceInk 的 FluidAudioStreamingProvider 一樣:辨識完才開始等)。
//   - --window W > 0:目前這一段超過 W 秒時,在第 W-3 到 W 秒之間找最安靜的地方切(和 App 的
//     energyAwareChunks 同一套算法),切點前的那段再辨識一次當成定稿,之後從切點重新開始。
//     W = 0 表示不顯示(對照組):錄音期間什麼都不跑,等 min(錄音長度, --idle-cap) 秒就當成錄音結束。
//   - 錄音結束(真實時間到了錄音長度)時,如果有一次辨識正在跑,要等它跑完(這版 transcribe.cpp
//     不能中途停止),然後照 App 現在的做法把整段錄音辨識一次(每 30 秒切一段):這就是貼出去的文字。
//     「結束後的等待」= 最後那次辨識完成的時間 − 錄音長度。
//   每次辨識輸出一行 JSON:kind(pass/commit/final)、真實時間的開始/結束、辨識的錄音範圍、花的時間、文字。
//
// --start-at EPOCH --slack S(loop):第 i 段在 EPOCH + Σ(前面各段長度 + S) 秒開始,用來和
// apple_stream_sim 同時跑、每段對齊。
//
// 和 tc_bench 一樣:模型載入一次(Metal),每次辨識各開一個 session,用完就釋放;第一段先暖機,不記。
//
// 編譯(transcribe.cpp 856d7c1 的 include、examples/common/dr_wav.h,和 build 出來的靜態函式庫):
//   cc -O2 -I $INC tc_stream_sim.c $LIB/libtranscribe.a $LIB/libggml.a $LIB/libggml-base.a \
//      $LIB/libggml-cpu.a $LIB/libggml-metal.a -lc++ -framework Accelerate -framework Foundation \
//      -framework Metal -framework MetalKit -o tc_stream_sim
// 用法:
//   tc_stream_sim -m model.gguf -i list.tsv -o out.jsonl -l zh --mode prefix [--prefixes 2,5,10,20,30,60] [--repeat 3]
//   tc_stream_sim -m model.gguf -i list.tsv -o out.jsonl -l zh --mode loop --window 10 [--interval 1] [--first 1]
// list.tsv 每行「id<TAB>wav 路徑」,wav 要 16kHz。

#include "transcribe.h"

#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define RATE 16000

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double epoch_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void sleep_s(double s) {
    if (s <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t) s;
    ts.tv_nsec = (long) ((s - (double) ts.tv_sec) * 1e9);
    nanosleep(&ts, NULL);
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
    int boundary;   // 樣本數
    int window;     // 樣本數(找安靜處的能量視窗)
} opts_t;

typedef struct {
    double wall_ms, encode_ms, decode_ms;
    int ok;
    char * text;
    char status[64];
} result_t;

// 辨識 pcm[start, end),max_chunk > 0 時照 App 每 max_chunk 個樣本切一段。
static void run_range(struct transcribe_model * model, const float * pcm, int start, int end, int max_chunk,
                      const opts_t * o, result_t * r) {
    memset(r, 0, sizeof(*r));
    size_t cap = 4096, len = 0;
    r->text = calloc(cap, 1);
    r->ok = 1;
    double t0 = now_s();
    while (start < end) {
        int stop = end;
        if (max_chunk > 0 && end - start > max_chunk) {
            int max_end = start + max_chunk;
            int search = o->boundary < max_chunk ? o->boundary : max_chunk;
            if (search < 1) search = 1;
            int split = quietest(pcm, max_end - search > start ? max_end - search : start, max_end, o->window);
            stop = split > start + 1 ? split : start + 1;
        }
        struct transcribe_session_params sp;
        transcribe_session_params_init(&sp);
        struct transcribe_session * session = NULL;
        transcribe_status st = transcribe_session_init(model, &sp, &session);
        if (st != TRANSCRIBE_OK) {
            snprintf(r->status, sizeof(r->status), "session: %s", transcribe_status_string(st));
            r->ok = 0;
            break;
        }
        struct transcribe_run_params rp;
        transcribe_run_params_init(&rp);
        rp.timestamps = TRANSCRIBE_TIMESTAMPS_NONE;
        rp.language = o->language;
        rp.keep_special_tags = false;
        st = transcribe_run(session, pcm + start, stop - start, &rp);
        if (st != TRANSCRIBE_OK) {
            snprintf(r->status, sizeof(r->status), "run: %s", transcribe_status_string(st));
            r->ok = 0;
            transcribe_session_free(session);
            break;
        }
        struct transcribe_timings tm;
        transcribe_timings_init(&tm);
        if (transcribe_get_timings(session, &tm) == TRANSCRIBE_OK) {
            r->encode_ms += tm.encode_ms;
            r->decode_ms += tm.decode_ms;
        }
        const char * text = transcribe_full_text(session);
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
        start = stop;
    }
    r->wall_ms = (now_s() - t0) * 1000.0;
}

static void emit(FILE * out, const char * id, const char * kind, double extra_a, double extra_b,
                 int win_start, int win_end, const result_t * r) {
    fprintf(out, "{\"id\":");
    json_str(out, id);
    fprintf(out, ",\"kind\":\"%s\",\"a\":%.3f,\"b\":%.3f,\"win_start\":%.3f,\"win_end\":%.3f,"
                 "\"ok\":%s,\"status\":",
            kind, extra_a, extra_b, win_start / (double) RATE, win_end / (double) RATE, r->ok ? "true" : "false");
    json_str(out, r->status);
    fprintf(out, ",\"wall_ms\":%.1f,\"encode_ms\":%.1f,\"decode_ms\":%.1f,\"text\":",
            r->wall_ms, r->encode_ms, r->decode_ms);
    json_str(out, r->text);
    fprintf(out, "}\n");
    fflush(out);
}

// 照真實時間模擬一次聽寫。a = 真實時間的開始(秒,從錄音開始算),b = 結束。
static void simulate(struct transcribe_model * model, const char * id, const float * pcm, int n,
                     double window_s, double interval_s, double first_s, double idle_cap_s,
                     const opts_t * o, FILE * out) {
    const double dur = n / (double) RATE;
    const int window = (int) (window_s * RATE);
    int seg = 0;
    int passes = 0, commits = 0;
    double busy_s = 0;
    double ep0 = epoch_s();
    double t0 = now_s();
    double next = first_s;
    result_t r;

    if (window > 0) {
        for (;;) {
            double t = now_s() - t0;
            if (t >= dur) break;
            if (t < next) {
                sleep_s((next < dur ? next : dur) - t);
                continue;
            }
            int avail = (int) (t * RATE);
            if (avail > n) avail = n;
            if (avail - seg > window) {
                // 目前這一段太長:在 [seg+W-3, seg+W) 找最安靜的地方切,切點前定稿
                int max_end = seg + window;
                int search = o->boundary < window ? o->boundary : window;
                int cut = quietest(pcm, max_end - search, max_end, o->window);
                if (cut <= seg) cut = seg + 1;
                double a = now_s() - t0;
                run_range(model, pcm, seg, cut, 0, o, &r);
                double b = now_s() - t0;
                busy_s += b - a;
                emit(out, id, "commit", a, b, seg, cut, &r);
                free(r.text);
                commits++;
                seg = cut;
                next = b;   // 切完馬上辨識新的一段
                continue;
            }
            if (avail - seg < RATE / 2) {   // 新的一段不到 0.5 秒,先不跑
                next = t + 0.1;
                continue;
            }
            double a = now_s() - t0;
            run_range(model, pcm, seg, avail, 0, o, &r);
            double b = now_s() - t0;
            busy_s += b - a;
            emit(out, id, "pass", a, b, seg, avail, &r);
            free(r.text);
            passes++;
            next = b + interval_s;
        }
    } else {
        // 對照組(現在的 App):錄音期間 GPU 閒著。等 min(錄音長度, idle_cap) 秒就好,GPU 閒下來只要一兩秒。
        double idle = dur < idle_cap_s ? dur : idle_cap_s;
        sleep_s(idle - (now_s() - t0));
    }

    // 錄音結束:照 App 現在的做法把整段辨識一次(每 30 秒切一段)
    double stop_at = now_s() - t0;   // 如果最後一次辨識跨過錄音結束,這裡已經晚於 dur
    run_range(model, pcm, 0, n, 30 * RATE, o, &r);
    double done = now_s() - t0;
    emit(out, id, "final", stop_at, done, 0, n, &r);
    free(r.text);
    // 結束後的等待:有顯示時從錄音長度算(含等正在跑的那次);對照組從開始辨識算
    double wait = window > 0 ? done - dur : done - stop_at;
    fprintf(out, "{\"id\":");
    json_str(out, id);
    fprintf(out, ",\"kind\":\"summary\",\"window_s\":%.1f,\"interval_s\":%.2f,\"duration\":%.3f,"
                 "\"passes\":%d,\"commits\":%d,\"busy_s\":%.3f,\"wait_after_stop_s\":%.3f,"
                 "\"epoch_start\":%.3f,\"epoch_end\":%.3f}\n",
            window_s, interval_s, dur, passes, commits, busy_s, wait, ep0, epoch_s());
    fflush(out);
}

int main(int argc, char ** argv) {
    const char * model_path = NULL, * list_path = NULL, * out_path = NULL, * mode = "prefix";
    const char * prefixes_arg = "2,5,10,20,30,60";
    int repeat = 3;
    double window_s = 0, interval_s = 1.0, first_s = 1.0, gap_s = 5.0, idle_cap_s = 5.0, start_at = 0, slack_s = 10;
    opts_t o = { NULL, 3 * RATE, 1600 };
    for (int i = 1; i < argc; ++i) {
        const char * a = argv[i];
        const char * v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "-m") && v) { model_path = v; ++i; }
        else if (!strcmp(a, "-i") && v) { list_path = v; ++i; }
        else if (!strcmp(a, "-o") && v) { out_path = v; ++i; }
        else if (!strcmp(a, "-l") && v) { o.language = v; ++i; }
        else if (!strcmp(a, "--mode") && v) { mode = v; ++i; }
        else if (!strcmp(a, "--prefixes") && v) { prefixes_arg = v; ++i; }
        else if (!strcmp(a, "--repeat") && v) { repeat = atoi(v); ++i; }
        else if (!strcmp(a, "--window") && v) { window_s = atof(v); ++i; }
        else if (!strcmp(a, "--interval") && v) { interval_s = atof(v); ++i; }
        else if (!strcmp(a, "--first") && v) { first_s = atof(v); ++i; }
        else if (!strcmp(a, "--gap") && v) { gap_s = atof(v); ++i; }
        else if (!strcmp(a, "--idle-cap") && v) { idle_cap_s = atof(v); ++i; }
        else if (!strcmp(a, "--start-at") && v) { start_at = atof(v); ++i; }
        else if (!strcmp(a, "--slack") && v) { slack_s = atof(v); ++i; }
        else { fprintf(stderr, "unknown or incomplete option: %s\n", a); return 2; }
    }
    if (!model_path || !list_path || !out_path) {
        fprintf(stderr, "usage: %s -m model.gguf -i list.tsv -o out.jsonl --mode prefix|loop [options]\n", argv[0]);
        return 2;
    }

    int prefixes[16], n_prefixes = 0;
    for (const char * p = prefixes_arg; *p && n_prefixes < 16;) {
        prefixes[n_prefixes++] = atoi(p);
        const char * c = strchr(p, ',');
        if (!c) break;
        p = c + 1;
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
    double l0 = now_s();
    struct transcribe_model_load_params mp;
    transcribe_model_load_params_init(&mp);
    mp.backend = TRANSCRIBE_BACKEND_METAL;
    struct transcribe_model * model = NULL;
    transcribe_status st = transcribe_model_load_file(model_path, &mp, &model);
    if (st != TRANSCRIBE_OK) { fprintf(stderr, "load: %s\n", transcribe_status_string(st)); return 1; }
    double load_s = now_s() - l0;

    FILE * out = fopen(out_path, "w");
    if (!out) { fprintf(stderr, "cannot write %s\n", out_path); return 1; }

    // 暖機:第一段的前 5 秒
    {
        int n = 0;
        unsigned int rate = 0;
        float * pcm = load_wav(wavs[0], &n, &rate);
        if (!pcm || rate != RATE) { fprintf(stderr, "bad wav %s (rate %u)\n", wavs[0], rate); return 1; }
        result_t r;
        run_range(model, pcm, 0, n < 5 * RATE ? n : 5 * RATE, 0, &o, &r);
        fprintf(out, "{\"warmup\":true,\"mode\":\"%s\",\"load_s\":%.3f,\"wall_ms\":%.1f}\n", mode, load_s, r.wall_ms);
        fprintf(stderr, "load %.2f s, warmup %.0f ms\n", load_s, r.wall_ms);
        free(r.text);
        free(pcm);
    }

    for (int i = 0; i < n_items; ++i) {
        int n = 0;
        unsigned int rate = 0;
        float * pcm = load_wav(wavs[i], &n, &rate);
        if (!pcm || rate != RATE) { fprintf(stderr, "bad wav %s (rate %u)\n", wavs[i], rate); return 1; }
        if (!strcmp(mode, "prefix")) {
            for (int k = 0; k < n_prefixes; ++k) {
                int len = prefixes[k] * RATE;
                if (len > n) continue;
                for (int rep = 0; rep < repeat; ++rep) {
                    result_t r;
                    run_range(model, pcm, 0, len, 0, &o, &r);
                    emit(out, ids[i], "prefix", prefixes[k], rep, 0, len, &r);
                    free(r.text);
                }
            }
        } else {
            if (start_at > 0) sleep_s(start_at - epoch_s());
            fprintf(stderr, "%s %.1f s\n", ids[i], n / (double) RATE);
            simulate(model, ids[i], pcm, n, window_s, interval_s, first_s, idle_cap_s, &o, out);
            if (start_at > 0) start_at += n / (double) RATE + slack_s;
            else sleep_s(gap_s);   // 兩次聽寫之間讓 GPU 閒下來,像真的使用
        }
        free(pcm);
    }
    fclose(out);
    transcribe_model_free(model);
    return 0;
}
