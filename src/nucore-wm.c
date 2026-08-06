/* Minimal EWMH window manager for a single-application Nucore X session. */
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Display *dpy;
static Window root;
static int ownership_failed;
static Atom net_supported, net_supporting_wm_check, net_wm_name;
static Atom net_wm_state, net_wm_state_fullscreen, utf8_string;

static int has_fullscreen(Window window)
{
    Atom type;
    int format;
    unsigned long count, remaining, i;
    unsigned char *data = NULL;

    if (XGetWindowProperty(dpy, window, net_wm_state, 0, 64, False,
                           XA_ATOM, &type, &format, &count, &remaining,
                           &data) != Success || !data)
        return 0;
    for (i = 0; i < count; ++i) {
        if (((Atom *)data)[i] == net_wm_state_fullscreen) {
            XFree(data);
            return 1;
        }
    }
    XFree(data);
    return 0;
}

static void set_fullscreen(Window window, int enabled)
{
    if (enabled) {
        XChangeProperty(dpy, window, net_wm_state, XA_ATOM, 32,
                        PropModeReplace,
                        (unsigned char *)&net_wm_state_fullscreen, 1);
        XMoveResizeWindow(dpy, window, 0, 0,
                          DisplayWidth(dpy, DefaultScreen(dpy)),
                          DisplayHeight(dpy, DefaultScreen(dpy)));
        XRaiseWindow(dpy, window);
        XSetInputFocus(dpy, window, RevertToPointerRoot, CurrentTime);
    } else {
        XDeleteProperty(dpy, window, net_wm_state);
    }
}

static int xerror(Display *display, XErrorEvent *error)
{
    char message[128];
    (void)display;
    if (error->error_code == BadAccess)
        ownership_failed = 1;
    XGetErrorText(dpy, error->error_code, message, sizeof(message));
    fprintf(stderr, "nucore-wm: X error: %s\n", message);
    return 0;
}

static int wm_is_ready(void)
{
    Atom type;
    int format;
    unsigned long count, remaining;
    unsigned char *data = NULL;
    int ready = 0;

    if (XGetWindowProperty(dpy, root, net_supporting_wm_check, 0, 1, False,
                           XA_WINDOW, &type, &format, &count, &remaining,
                           &data) == Success && data && count == 1) {
        XWindowAttributes attributes;
        ready = XGetWindowAttributes(dpy, *(Window *)data, &attributes) != 0;
    }
    if (data)
        XFree(data);
    return ready;
}

int main(int argc, char **argv)
{
    XEvent event;
    Window check;
    const char name[] = "nucore-wm";

    dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "nucore-wm: cannot open DISPLAY\n");
        return 1;
    }
    root = DefaultRootWindow(dpy);
    net_supported = XInternAtom(dpy, "_NET_SUPPORTED", False);
    net_supporting_wm_check =
        XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
    net_wm_name = XInternAtom(dpy, "_NET_WM_NAME", False);
    net_wm_state = XInternAtom(dpy, "_NET_WM_STATE", False);
    net_wm_state_fullscreen =
        XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
    utf8_string = XInternAtom(dpy, "UTF8_STRING", False);

    if (argc == 2 && strcmp(argv[1], "--ready") == 0) {
        int ready = wm_is_ready();
        XCloseDisplay(dpy);
        return ready ? 0 : 1;
    }

    XSetErrorHandler(xerror);
    XSelectInput(dpy, root, SubstructureRedirectMask | SubstructureNotifyMask);
    XSync(dpy, False);
    if (ownership_failed) {
        fprintf(stderr, "nucore-wm: another window manager owns DISPLAY\n");
        XCloseDisplay(dpy);
        return 2;
    }
    XChangeProperty(dpy, root, net_supported, XA_ATOM, 32,
                    PropModeReplace,
                    (unsigned char *)&net_wm_state_fullscreen, 1);
    check = XCreateSimpleWindow(dpy, root, -1, -1, 1, 1, 0, 0, 0);
    XChangeProperty(dpy, root, net_supporting_wm_check, XA_WINDOW, 32,
                    PropModeReplace, (unsigned char *)&check, 1);
    XChangeProperty(dpy, check, net_supporting_wm_check, XA_WINDOW, 32,
                    PropModeReplace, (unsigned char *)&check, 1);
    XChangeProperty(dpy, check, net_wm_name, utf8_string, 8,
                    PropModeReplace, (const unsigned char *)name,
                    strlen(name));
    XSync(dpy, False);

    for (;;) {
        XNextEvent(dpy, &event);
        if (event.type == MapRequest) {
            XMapWindow(dpy, event.xmaprequest.window);
            if (has_fullscreen(event.xmaprequest.window))
                set_fullscreen(event.xmaprequest.window, 1);
        } else if (event.type == ConfigureRequest) {
            XConfigureRequestEvent *request = &event.xconfigurerequest;
            XWindowChanges changes = {
                .x = request->x, .y = request->y,
                .width = request->width, .height = request->height,
                .border_width = request->border_width,
                .sibling = request->above, .stack_mode = request->detail
            };
            XConfigureWindow(dpy, request->window, request->value_mask,
                             &changes);
        } else if (event.type == ClientMessage &&
                   event.xclient.message_type == net_wm_state &&
                   (Atom)event.xclient.data.l[1] == net_wm_state_fullscreen) {
            long action = event.xclient.data.l[0];
            int current = has_fullscreen(event.xclient.window);
            set_fullscreen(event.xclient.window,
                           action == 1 || (action == 2 && !current));
        }
    }
}
