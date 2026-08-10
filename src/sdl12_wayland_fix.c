/* Small SDL 1.2 ABI adapter for sdl12-compat's Wayland path.
 *
 * Wayland requires UTF-8 window titles, while the legacy emulator sometimes
 * passes an 8-bit caption that X11 accepted. Pinbox also calls SDL_Flip from
 * its render worker rather than the thread that initialized SDL. Some Wayland
 * compositors tolerate SDL2 presentation from that worker, but Gamescope
 * displays a black surface. Coalesce worker flips and present the latest one
 * when the SDL thread next polls events. Native SDL and X11 never load this
 * adapter. */
extern void *dlsym(void *, const char *);
extern long write(int, const void *, unsigned long);
extern long syscall(long, ...);

static void (*real_set_caption)(const char *, const char *);
static int (*real_init)(unsigned int);
static void *(*real_set_video_mode)(int, int, int, unsigned int);
static char *(*real_get_error)(void);
static int (*real_flip)(void *);
static int (*real_poll_event)(void *);
static long video_thread;
static void *pending_flip;

static unsigned long text_length(const char *text)
{
    unsigned long length = 0;
    while (text && text[length])
        length++;
    return length;
}

static void report_error(const char *operation)
{
    static const char prefix[] = "[sdl12_wayland_fix] ";
    static const char separator[] = " failed: ";
    static const char newline[] = "\n";

    if (!real_get_error)
        real_get_error = dlsym((void *) -1L, "SDL_GetError");
    write(2, prefix, sizeof(prefix) - 1);
    write(2, operation, text_length(operation));
    write(2, separator, sizeof(separator) - 1);
    if (real_get_error) {
        const char *error = real_get_error();
        write(2, error, text_length(error));
    }
    write(2, newline, sizeof(newline) - 1);
}

int SDL_Init(unsigned int flags)
{
    int result;
    if (!real_init)
        real_init = dlsym((void *) -1L, "SDL_Init");
    result = real_init(flags);
    if (result == 0 && !video_thread)
        video_thread = syscall(224); /* __NR_gettid on i386 */
    if (result < 0)
        report_error("SDL_Init");
    return result;
}

int SDL_Flip(void *surface)
{
    if (!real_flip)
        real_flip = dlsym((void *) -1L, "SDL_Flip");
    if (video_thread && syscall(224) != video_thread) {
        /* Pinbox renders at 60 Hz, so keeping only the latest complete frame
         * avoids a queue while preserving its normal frame-dropping model. */
        __sync_lock_test_and_set(&pending_flip, surface);
        return 0;
    }
    return real_flip(surface);
}

int SDL_PollEvent(void *event)
{
    void *surface;
    if (!real_poll_event)
        real_poll_event = dlsym((void *) -1L, "SDL_PollEvent");
    /* Only the thread that initialized SDL may submit a deferred frame. */
    if (video_thread && syscall(224) == video_thread) {
        if (!real_flip)
            real_flip = dlsym((void *) -1L, "SDL_Flip");
        surface = __sync_lock_test_and_set(&pending_flip, (void *)0);
        if (surface)
            real_flip(surface);
    }
    return real_poll_event(event);
}

void SDL_WM_SetCaption(const char *title, const char *icon)
{
    (void) title;
    if (!real_set_caption)
        real_set_caption = dlsym((void *) -1L, "SDL_WM_SetCaption");
    real_set_caption("Nucore", icon);
}

void *SDL_SetVideoMode(int width, int height, int bpp, unsigned int flags)
{
    void *surface;

    if (!real_set_video_mode)
        real_set_video_mode = dlsym((void *) -1L, "SDL_SetVideoMode");
    surface = real_set_video_mode(width, height, bpp, flags);
    if (!surface)
        report_error("SDL_SetVideoMode");
    return surface;
}
