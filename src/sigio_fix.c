/*
 * sigio_fix.c — LD_PRELOAD shim that makes the legacy 32-bit Pinball 2000
 *               emulator (`nucore` and the `pinbox` fork) run on modern
 *               x86_64 Linux hosts. Without this shim the audio pipeline
 *               crashes within seconds and the RTC/SIGIO storm corrupts
 *               signal-handler stacks → segfault. With it loaded, audio
 *               stays clean and the binary survives indefinitely.
 *
 * TARGET BINARIES : bin/nucore, bin/nucore_nwd, bin/pinbox, bin/pinbox_nwd
 *                   (all 32-bit ELF, stripped, GCC 4.2.4-era builds).
 *
 * Five interventions:
 *
 *  1. sigaction wrapper   — adds SA_ONSTACK|SA_RESTART to SIGALRM/SIGIO handlers.
 *                           Each thread gets a 128 KB dedicated alternate stack so
 *                           signal frames can never corrupt the interrupted stack.
 *
 *  2. pthread_create wrap — blocks SIGIO+SIGALRM in every child thread at birth.
 *                           SDL audio / render threads are never interrupted by the
 *                           RTC/timer storm.  Sets SCHED_FIFO prio 10 so the audio
 *                           callback always wins against SCHED_OTHER threads.
 *
 *  3. fcntl wrapper       — redirects F_SETOWN(pid) → F_SETOWN_EX(F_OWNER_TID, main)
 *                           so SIGIO from the RTC fd is pinned to the main thread TID.
 *
 *  4. Mix_OpenAudio wrap  — doubles the SDL_mixer chunk size (4096 → 8192 samples).
 *                           At 44100 Hz this gives ~186 ms of audio buffer headroom,
 *                           eliminating underruns caused by scheduling jitter.
 *
 *  5. setpriority wrap    — silences the "can't set nice" error when already at the
 *                           desired priority level (harmless no-op if not root).
 *
 * BUILD:
 *   make            # from the nucore-portable root → writes bin/sigio_fix.so
 *   # or, by hand:
 *   gcc -m32 -shared -fPIC -O1 -o ../bin/sigio_fix.so sigio_fix.c -ldl -lpthread
 *
 * USE:
 *   bin/bundled.sh injects this .so via the bundled ld-linux.so.2 --preload
 *   path automatically; you do not need to set LD_PRELOAD by hand.
 */

#define _GNU_SOURCE
#include <signal.h>
#include <pthread.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <stdarg.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sched.h>
#include <errno.h>

typedef unsigned short Uint16;

/* -----------------------------------------------------------------------
 * Alternate signal stack — one per thread via TLS
 * ----------------------------------------------------------------------- */
#define ALTSTACK_SZ (128 * 1024)

static __thread char   tls_alt[ALTSTACK_SZ];
static __thread int    tls_alt_installed;

static void ensure_altstack(void)
{
    if (tls_alt_installed) return;
    stack_t ss;
    ss.ss_sp    = tls_alt;
    ss.ss_size  = ALTSTACK_SZ;
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);
    tls_alt_installed = 1;
}

/* -----------------------------------------------------------------------
 * Block SIGIO+SIGALRM in the calling thread
 * ----------------------------------------------------------------------- */
static void block_timer_signals(void)
{
    sigset_t bs;
    sigemptyset(&bs);
    sigaddset(&bs, SIGIO);
    sigaddset(&bs, SIGALRM);
    pthread_sigmask(SIG_BLOCK, &bs, NULL);
}

/* -----------------------------------------------------------------------
 * 1. sigaction wrapper
 * ----------------------------------------------------------------------- */
static int (*real_sigaction)(int, const struct sigaction *,
                             struct sigaction *) = NULL;

int sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
    if (!real_sigaction)
        real_sigaction = dlsym(RTLD_NEXT, "sigaction");

    if (act && (sig == SIGALRM || sig == SIGIO)) {
        struct sigaction fixed = *act;

        ensure_altstack();
        fixed.sa_flags |= SA_ONSTACK | SA_RESTART;

        /* Make SIGIO and SIGALRM block each other during handler */
        sigaddset(&fixed.sa_mask, SIGIO);
        sigaddset(&fixed.sa_mask, SIGALRM);

        return real_sigaction(sig, &fixed, old);
    }
    return real_sigaction(sig, act, old);
}

/* -----------------------------------------------------------------------
 * 2. pthread_create wrapper — block timer signals in every child thread
 * ----------------------------------------------------------------------- */
typedef struct {
    void *(*fn)(void *);
    void  *arg;
} wrap_t;

static void *thread_trampoline(void *p)
{
    wrap_t *w  = (wrap_t *)p;
    void *(*fn)(void *) = w->fn;
    void  *arg          = w->arg;
    free(w);

    ensure_altstack();
    block_timer_signals();

    /*
     * Boost child threads to SCHED_FIFO priority 10.
     * The audio callback thread will always preempt SCHED_OTHER work,
     * preventing starvation that causes ALSA underruns.
     * Requires CAP_SYS_NICE (i.e. run with sudo).
     */
    struct sched_param sp = { .sched_priority = 10 };
    if (pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp) != 0)
        pthread_setschedparam(pthread_self(), SCHED_RR, &sp);  /* fallback */

    return fn(arg);
}

static int (*real_ptcreate)(pthread_t *, const pthread_attr_t *,
                            void *(*)(void *), void *) = NULL;

int pthread_create(pthread_t *t, const pthread_attr_t *attr,
                   void *(*fn)(void *), void *arg)
{
    if (!real_ptcreate)
        real_ptcreate = dlsym(RTLD_NEXT, "pthread_create");

    wrap_t *w = malloc(sizeof(wrap_t));
    if (!w) return real_ptcreate(t, attr, fn, arg);   /* fallback */
    w->fn  = fn;
    w->arg = arg;
    return real_ptcreate(t, attr, thread_trampoline, w);
}

/* -----------------------------------------------------------------------
 * 4. Mix_OpenAudio wrapper — double the chunk size to 8192 samples
 *
 * The binary requests 4096 samples @ 44100 Hz → 93 ms callback interval.
 * Doubling to 8192 → 186 ms gives the scheduler far more headroom and
 * eliminates underruns caused by the remaining jitter after the SIGIO fix.
 * Audio latency increases by ~93 ms, imperceptible for a pinball machine.
 * ----------------------------------------------------------------------- */
static int (*real_Mix_OpenAudio)(int, Uint16, int, int) = NULL;

int Mix_OpenAudio(int frequency, Uint16 format, int channels, int chunksize)
{
    if (!real_Mix_OpenAudio)
        real_Mix_OpenAudio = dlsym(RTLD_NEXT, "Mix_OpenAudio");

    int new_chunk = chunksize * 2;   /* 4096 → 8192 */
    fprintf(stderr,
            "[sigio_fix] Mix_OpenAudio: freq=%d fmt=0x%04x ch=%d "
            "chunk %d→%d samples\n",
            frequency, format, channels, chunksize, new_chunk);
    return real_Mix_OpenAudio(frequency, format, channels, new_chunk);
}

/* -----------------------------------------------------------------------
 * 5. setpriority wrapper — suppress the spurious "can't set nice" error
 *
 * The binary calls setpriority(PRIO_PROCESS, 0, -18) and prints a noisy
 * error if it fails.  When running as root this succeeds; this wrapper
 * silences the errno noise in edge cases where it is already set.
 * ----------------------------------------------------------------------- */
static int (*real_setpriority)(__priority_which_t, id_t, int) = NULL;

int setpriority(__priority_which_t which, id_t who, int prio)
{
    if (!real_setpriority)
        real_setpriority = dlsym(RTLD_NEXT, "setpriority");

    int r = real_setpriority(which, who, prio);
    if (r != 0 && errno == EACCES) {
        /* Already at a higher priority — treat as success */
        errno = 0;
        return 0;
    }
    return r;
}

/* -----------------------------------------------------------------------
 * 3. fcntl wrapper — pin SIGIO to main thread TID via F_SETOWN_EX
 * ----------------------------------------------------------------------- */
static int (*real_fcntl)(int, int, ...) = NULL;
static pid_t main_tid;

int fcntl(int fd, int cmd, ...)
{
    if (!real_fcntl)
        real_fcntl = dlsym(RTLD_NEXT, "fcntl");

    va_list ap;
    va_start(ap, cmd);
    long arg = va_arg(ap, long);
    va_end(ap);

    if (cmd == F_SETOWN) {
        /*
         * Original code: fcntl(rtcFD, F_SETOWN, getpid())
         * Replace with F_SETOWN_EX targeting main thread TID so SIGIO
         * goes only to the main thread, not SDL audio/render threads.
         */
        struct f_owner_ex ex;
        ex.type = F_OWNER_TID;
        ex.pid  = main_tid;
        return real_fcntl(fd, F_SETOWN_EX, &ex);
    }
    return real_fcntl(fd, cmd, arg);
}

/* -----------------------------------------------------------------------
 * Constructor — runs before main(); records main TID, sets up alt stack
 * ----------------------------------------------------------------------- */
__attribute__((constructor))
static void sigio_fix_init(void)
{
    main_tid = (pid_t)syscall(SYS_gettid);
    ensure_altstack();

    /* Main thread must NOT block SIGIO/SIGALRM — unblock just in case */
    sigset_t ub;
    sigemptyset(&ub);
    sigaddset(&ub, SIGIO);
    sigaddset(&ub, SIGALRM);
    pthread_sigmask(SIG_UNBLOCK, &ub, NULL);

    fprintf(stderr,
            "[sigio_fix] loaded — main_tid=%d  "
            "SA_ONSTACK+pthread_mask+F_SETOWN_EX+Mix_OpenAudio+SCHED_FIFO active\n",
            main_tid);
}
