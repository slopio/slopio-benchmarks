/*
 * The README's one route on libh2o, h2o's own library, set up as the other
 * two servers are so that only the stacks differ: one event loop (epoll) per
 * thread, each pinned to a CPU of the mask with its own SO_REUSEPORT listener
 * and a backlog of 1024, TCP_NODELAY on every connection (libh2o sets it),
 * no `server` or `date` header, the same HTTP/2 limits.
 *
 *     PER_CORE=1 ./target/h2o/h2o-server
 *     h2load -n 100000 -c 64 -m 32 http://127.0.0.1:8080/
 *
 * PORT (8080), PER_CORE (unset: one thread), MAX_STREAMS (64), STREAM_WINDOW
 * (1048576), INCOMING_CPU (unset; with PER_CORE, SO_INCOMING_CPU on each
 * thread's listener, as slopio's runtime does by default).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include "h2o.h"
#include "h2o/http2.h"

#define PAYLOAD_LEN 2048
static char payload[PAYLOAD_LEN];
/* /app's body, size_kb of it: every body is a prefix. */
#define MAX_SIZE_KB 1024
static char body[MAX_SIZE_KB * 1024];

/* slopio's listener: what the kernel queues before an accept. */
#define BACKLOG 1024
/* As h2o's own server: at most this many accepts per wakeup of a listener. */
#define ACCEPTS_PER_WAKEUP 10

static h2o_globalconf_t config;
static int port, incoming_cpu;

static h2o_generator_t generator = {NULL, NULL};

static void respond(h2o_req_t *req, int status, const char *reason, const char *allow, h2o_iovec_t body, size_t content_length)
{
    req->res.status = status;
    req->res.reason = reason;
    if (allow != NULL)
        h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_ALLOW, NULL, allow, strlen(allow));
    h2o_add_header(&req->pool, &req->res.headers, H2O_TOKEN_CONTENT_TYPE, NULL, H2O_STRLIT("text/plain"));
    req->res.content_length = content_length;
    h2o_start_response(req, &generator);
    h2o_send(req, &body, 1, H2O_SEND_STATE_FINAL);
}

static void respond_payload(h2o_req_t *req)
{
    respond(req, 200, "OK", NULL, h2o_iovec_init(payload, PAYLOAD_LEN), PAYLOAD_LEN);
}

/*
 * GET or POST /app?delay_ms=&jitter_ms=&cpu_us=&touch_kb=&size_kb=, as servers/work does it
 * for the Rust servers: the request's memory allocated and filled, a wait on
 * h2o's timer (milliseconds; with jitter_ms, a whole number drawn evenly
 * either side of delay_ms), the computation, the memory read back and freed,
 * then `/`'s answer, of size_kb if asked (h2o copies it into its output, as
 * it does any body). A POST first goes over every byte of its body, which h2o
 * has gathered whole before calling the handler (req->entity), as
 * servers/work's digest does. How long each wait really took, and how far from what
 * it asked, is logged once a second, in the same `slept` lines.
 */
#define MAX_DELAY_MS 60000
#define MAX_CPU_US 1000000
#define MAX_TOUCH_KB 65536
#define LINE 64
#define BUCKET_US 100
#define BUCKETS 2000
#define ERR_FROM_US (-20000)
#define ERR_BUCKETS 2000

static uint64_t monotonic_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/* xorshift64*, per thread, as servers/work draws. */
static __thread uint64_t random_state;

static uint64_t next_random(void)
{
    if (random_state == 0) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        random_state = ((uint64_t)ts.tv_nsec ^ ((uint64_t)(uintptr_t)&ts << 32)) | 1;
    }
    uint64_t x = random_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    random_state = x;
    return x * 0x2545f4914f6cdd1dULL;
}

/* Per thread, as the Rust servers count. */
static __thread struct {
    uint64_t n, requested_us, sum_us, max_us, since_us, early;
    int64_t err_sum_us;
    uint32_t hist[BUCKETS];
    uint32_t err[ERR_BUCKETS];
} slept;

static void record_sleep(uint64_t requested_us, uint64_t us)
{
    if (slept.since_us == 0)
        slept.since_us = monotonic_us();
    ++slept.n;
    slept.requested_us += requested_us;
    slept.sum_us += us;
    if (us > slept.max_us)
        slept.max_us = us;
    uint64_t b = us / BUCKET_US;
    ++slept.hist[b < BUCKETS ? b : BUCKETS - 1];
    int64_t err = (int64_t)us - (int64_t)requested_us;
    slept.err_sum_us += err;
    slept.early += err < 0;
    /* Floor division, as div_euclid: -1 µs is in the bucket below zero. */
    int64_t off = err - ERR_FROM_US, eb = off >= 0 ? off / BUCKET_US : -((-off + BUCKET_US - 1) / BUCKET_US);
    ++slept.err[eb < 0 ? 0 : eb >= ERR_BUCKETS ? ERR_BUCKETS - 1 : eb];
    if (monotonic_us() - slept.since_us < 1000000)
        return;
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    char line[(BUCKETS + ERR_BUCKETS) * 14 + 300];
    int len = snprintf(line, sizeof(line), "slept at=%lld.%03ld n=%llu requested_us=%llu sum_us=%llu max_us=%llu hist=",
                       (long long)now.tv_sec, now.tv_nsec / 1000000, (unsigned long long)slept.n,
                       (unsigned long long)slept.requested_us, (unsigned long long)slept.sum_us, (unsigned long long)slept.max_us);
    const char *sep = "";
    for (int i = 0; i < BUCKETS; ++i) {
        if (slept.hist[i] == 0)
            continue;
        len += snprintf(line + len, sizeof(line) - len, "%s%d:%u", sep, i, slept.hist[i]);
        sep = ",";
    }
    len += snprintf(line + len, sizeof(line) - len, " err_sum_us=%lld early=%llu err=", (long long)slept.err_sum_us,
                    (unsigned long long)slept.early);
    sep = "";
    for (int i = 0; i < ERR_BUCKETS; ++i) {
        if (slept.err[i] == 0)
            continue;
        len += snprintf(line + len, sizeof(line) - len, "%s%d:%u", sep, ERR_FROM_US / BUCKET_US + i, slept.err[i]);
        sep = ",";
    }
    fprintf(stderr, "%s\n", line);
    memset(&slept, 0, sizeof(slept));
    slept.since_us = monotonic_us();
}

struct app {
    h2o_req_t *req;
    h2o_timer_t timer;
    uint64_t delay_ms, cpu_us, started_us;
    unsigned char *mem;
    size_t len, size;
};

/* With the request: a client that resets the stream mid-wait must not be
 * answered once the request is gone. */
static void app_dispose(void *p)
{
    struct app *app = p;
    if (h2o_timer_is_linked(&app->timer))
        h2o_timer_unlink(&app->timer);
    free(app->mem);
}

static void app_end(struct app *app)
{
    if (app->cpu_us > 0) {
        uint64_t start = monotonic_us();
        while (monotonic_us() - start < app->cpu_us)
            ;
    }
    uint64_t sum = 0;
    for (size_t i = 0; i < app->len; i += LINE)
        sum += app->mem[i];
    __asm__ volatile("" : : "r"(sum));
    free(app->mem);
    app->mem = NULL;
    respond(app->req, 200, "OK", NULL, h2o_iovec_init(body, app->size), app->size);
}

static void app_woken(h2o_timer_t *timer)
{
    struct app *app = H2O_STRUCT_FROM_MEMBER(struct app, timer, timer);
    record_sleep(app->delay_ms * 1000, monotonic_us() - app->started_us);
    app_end(app);
}

/* servers/work's parse: delay_ms, cpu_us and touch_kb only, each within its
 * bound, or a 400. */
static int parse_work(h2o_iovec_t query, uint64_t *delay_ms, uint64_t *jitter_ms, uint64_t *cpu_us, uint64_t *touch_kb,
                      uint64_t *size)
{
    *delay_ms = *jitter_ms = *cpu_us = *touch_kb = 0;
    *size = PAYLOAD_LEN;
    const char *p = query.base, *end = query.base + query.len;
    while (p < end) {
        const char *amp = memchr(p, '&', end - p), *stop = amp != NULL ? amp : end;
        if (stop > p) {
            const char *eq = memchr(p, '=', stop - p);
            if (eq == NULL || eq + 1 == stop)
                return -1;
            uint64_t v = 0;
            for (const char *d = eq + 1; d < stop; ++d) {
                if (*d < '0' || *d > '9' || v > UINT64_MAX / 10)
                    return -1;
                v = v * 10 + (*d - '0');
            }
            if (h2o_memis(p, eq - p, H2O_STRLIT("delay_ms")) && v <= MAX_DELAY_MS)
                *delay_ms = v;
            else if (h2o_memis(p, eq - p, H2O_STRLIT("jitter_ms")) && v <= MAX_DELAY_MS)
                *jitter_ms = v;
            else if (h2o_memis(p, eq - p, H2O_STRLIT("cpu_us")) && v <= MAX_CPU_US)
                *cpu_us = v;
            else if (h2o_memis(p, eq - p, H2O_STRLIT("touch_kb")) && v <= MAX_TOUCH_KB)
                *touch_kb = v;
            else if (h2o_memis(p, eq - p, H2O_STRLIT("size_kb")) && v >= 1 && v <= MAX_SIZE_KB)
                *size = v * 1024;
            else
                return -1;
        }
        p = stop + 1;
    }
    return *jitter_ms <= *delay_ms ? 0 : -1;
}

/* servers/work's digest: every byte of the body, as a parser would. */
static void digest(h2o_iovec_t body)
{
    uint64_t sum = 0;
    for (size_t i = 0; i < body.len; ++i)
        sum += (unsigned char)body.base[i];
    __asm__ volatile("" : : "r"(sum));
}

static void on_app(h2o_req_t *req)
{
    h2o_iovec_t query = {NULL, 0};
    if (req->query_at != SIZE_MAX)
        query = h2o_iovec_init(req->path.base + req->query_at + 1, req->path.len - req->query_at - 1);
    uint64_t delay_ms, jitter_ms, cpu_us, touch_kb, size;
    if (parse_work(query, &delay_ms, &jitter_ms, &cpu_us, &touch_kb, &size) != 0) {
        respond(req, 400, "Bad Request", NULL, h2o_iovec_init(H2O_STRLIT("bad request\n")), SIZE_MAX);
        return;
    }
    if (h2o_memis(req->method.base, req->method.len, H2O_STRLIT("POST")))
        digest(req->entity);
    if (jitter_ms > 0)
        delay_ms = delay_ms - jitter_ms + next_random() % (2 * jitter_ms + 1);
    struct app *app = h2o_mem_alloc_shared(&req->pool, sizeof(*app), app_dispose);
    *app = (struct app){.req = req, .delay_ms = delay_ms, .cpu_us = cpu_us, .len = touch_kb * 1024, .size = size};
    h2o_timer_init(&app->timer, app_woken);
    if (app->len > 0) {
        app->mem = malloc(app->len);
        memset(app->mem, 0x5a, app->len);
    }
    if (delay_ms == 0) {
        app_end(app);
        return;
    }
    app->started_us = monotonic_us();
    h2o_timer_link(req->conn->ctx->loop, delay_ms, &app->timer);
}

/* slopio-h2's router: the path without its query, `GET /` and `GET` or
 * `POST /app`; a 404 and a 405 with `allow`, both without a content-length,
 * as it writes them. */
static int on_req(h2o_handler_t *self, h2o_req_t *req)
{
    int root = h2o_memis(req->path_normalized.base, req->path_normalized.len, H2O_STRLIT("/"));
    int app = h2o_memis(req->path_normalized.base, req->path_normalized.len, H2O_STRLIT("/app"));
    if (!root && !app) {
        respond(req, 404, "Not Found", NULL, h2o_iovec_init(H2O_STRLIT("not found\n")), SIZE_MAX);
    } else if (app && !h2o_memis(req->method.base, req->method.len, H2O_STRLIT("GET")) &&
               !h2o_memis(req->method.base, req->method.len, H2O_STRLIT("POST"))) {
        respond(req, 405, "Method Not Allowed", "GET, POST", h2o_iovec_init(H2O_STRLIT("method not allowed\n")), SIZE_MAX);
    } else if (!app && !h2o_memis(req->method.base, req->method.len, H2O_STRLIT("GET"))) {
        respond(req, 405, "Method Not Allowed", "GET", h2o_iovec_init(H2O_STRLIT("method not allowed\n")), SIZE_MAX);
    } else if (app) {
        on_app(req);
    } else {
        respond_payload(req);
    }
    return 0;
}

struct worker {
    int cpu; /* -1: not pinned */
    h2o_context_t ctx;
    h2o_accept_ctx_t accept_ctx;
};

static void on_accept(h2o_socket_t *listener, const char *err)
{
    struct worker *worker = listener->data;
    if (err != NULL)
        return;
    for (int i = 0; i < ACCEPTS_PER_WAKEUP; ++i) {
        h2o_socket_t *sock = h2o_evloop_socket_accept(listener);
        if (sock == NULL)
            break;
        h2o_accept(&worker->accept_ctx, sock);
    }
}

/* As slopio's MultiAccept::bind. */
static int listen_on(int cpu)
{
    int fd, on = 1;
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if ((fd = socket(AF_INET, SOCK_STREAM, 0)) == -1)
        return -1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on)) != 0 || setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on)) != 0)
        return -1;
    if (cpu >= 0 && incoming_cpu && setsockopt(fd, SOL_SOCKET, SO_INCOMING_CPU, &cpu, sizeof(cpu)) != 0)
        return -1;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, BACKLOG) != 0)
        return -1;
    return fd;
}

static void *run(void *arg)
{
    struct worker *worker = arg;
    if (worker->cpu >= 0) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(worker->cpu, &set);
        if (pthread_setaffinity_np(pthread_self(), sizeof(set), &set) != 0) {
            fprintf(stderr, "cannot pin to CPU %d\n", worker->cpu);
            exit(1);
        }
    }
    h2o_context_init(&worker->ctx, h2o_evloop_create(), &config);
    worker->accept_ctx.ctx = &worker->ctx;
    worker->accept_ctx.hosts = config.hosts;
    int fd = listen_on(worker->cpu);
    if (fd == -1) {
        fprintf(stderr, "cannot listen on :%d: %s\n", port, strerror(errno));
        exit(1);
    }
    h2o_socket_t *listener = h2o_evloop_socket_create(worker->ctx.loop, fd, H2O_SOCKET_FLAG_DONT_READ);
    listener->data = worker;
    h2o_socket_read_start(listener, on_accept);
    while (h2o_evloop_run(worker->ctx.loop, INT32_MAX) == 0)
        ;
    return NULL;
}

static long env(const char *name, long fallback)
{
    const char *v = getenv(name);
    return v != NULL && *v != '\0' ? strtol(v, NULL, 10) : fallback;
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    memset(payload, 'x', PAYLOAD_LEN);
    memset(body, 'x', sizeof(body));
    port = (int)env("PORT", 8080);
    int per_core = env("PER_CORE", 0) != 0;
    incoming_cpu = env("INCOMING_CPU", 0) != 0;

    h2o_config_init(&config);
    /* slopio-h2 sends no `server` header: neither does this. */
    config.server_name = h2o_iovec_init(H2O_STRLIT(""));
    config.http2.max_streams = (uint32_t)env("MAX_STREAMS", 64);
    config.http2.max_concurrent_requests_per_connection = config.http2.max_streams;
    config.http2.active_stream_window_size = (uint32_t)env("STREAM_WINDOW", 1048576);
    /* slopio-h2 closes a connection silent for 2 minutes; h2o's default is 10 s. */
    config.http2.idle_timeout = 120000;
    /* servers/work's MAX_BODY: a larger POST gets h2o's own 413. */
    config.max_request_entity_size = 16 * 1024 * 1024;
    h2o_hostconf_t *hostconf = h2o_config_register_host(&config, h2o_iovec_init(H2O_STRLIT("default")), 65535);
    h2o_pathconf_t *pathconf = h2o_config_register_path(hostconf, "/", 0);
    h2o_create_handler(pathconf, sizeof(h2o_handler_t))->on_req = on_req;

    /* As slopio's runtime: one worker per CPU the mask allows, in order. */
    cpu_set_t mask;
    CPU_ZERO(&mask);
    sched_getaffinity(0, sizeof(mask), &mask);
    int threads = per_core ? CPU_COUNT(&mask) : 1;
    printf("h2o-server on :%d (h2c), threads=%d, max_streams=%u, stream_window=%u, incoming_cpu=%s\n", port, threads,
           config.http2.max_streams, config.http2.active_stream_window_size, incoming_cpu ? "true" : "false");
    fflush(stdout);

    if (!per_core) {
        struct worker worker = {.cpu = -1};
        run(&worker);
        return 0;
    }
    struct worker *workers = calloc(threads, sizeof(*workers));
    pthread_t *tids = calloc(threads, sizeof(*tids));
    for (int cpu = 0, n = 0; cpu < CPU_SETSIZE && n < threads; ++cpu) {
        if (!CPU_ISSET(cpu, &mask))
            continue;
        workers[n].cpu = cpu;
        pthread_create(&tids[n], NULL, run, &workers[n]);
        ++n;
    }
    for (int n = 0; n < threads; ++n)
        pthread_join(tids[n], NULL);
    return 0;
}
