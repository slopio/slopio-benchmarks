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
#include "h2o.h"
#include "h2o/http2.h"

#define PAYLOAD_LEN 2048
static char payload[PAYLOAD_LEN];

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

/* slopio-h2's router: the path without its query, `/` only; a 404 and a 405
 * with `allow`, both without a content-length, as it writes them. */
static int on_req(h2o_handler_t *self, h2o_req_t *req)
{
    if (!h2o_memis(req->path_normalized.base, req->path_normalized.len, H2O_STRLIT("/"))) {
        respond(req, 404, "Not Found", NULL, h2o_iovec_init(H2O_STRLIT("not found\n")), SIZE_MAX);
    } else if (!h2o_memis(req->method.base, req->method.len, H2O_STRLIT("GET"))) {
        respond(req, 405, "Method Not Allowed", "GET", h2o_iovec_init(H2O_STRLIT("method not allowed\n")), SIZE_MAX);
    } else {
        respond(req, 200, "OK", NULL, h2o_iovec_init(payload, PAYLOAD_LEN), PAYLOAD_LEN);
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
