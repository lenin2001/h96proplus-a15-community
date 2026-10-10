// SPDX-License-Identifier: GPL-2.0
/*
 * meson-ir (RAW NEC) -> virtual keyboard + virtual mouse.
 * One exclusive reader, one toggle per key press, no event-number assumption.
 * The measured 0x100 scan is mapped to KEY_F13 by h96-remote.map.
 */
#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/uinput.h>

#include "h96mouse_core.h"

#define KEY_BITS_BYTES ((KEY_CNT + 7) / 8)
static volatile sig_atomic_t stopping;

struct output_devices { int keyboard, mouse; bool failed; };

static void stop_handler(int signo)
{
    (void)signo;
    stopping = 1;
}

static bool key_bit(const uint8_t *bits, unsigned int key)
{
    return (bits[key / 8] & (1U << (key % 8))) != 0;
}

static void output_event(void *opaque, enum h96_target target,
                         int type, int code, int value)
{
    struct output_devices *out = opaque;
    struct input_event ev = {0};
    ev.type = type;
    ev.code = code;
    ev.value = value;
    const int fd = target == H96_KEYBOARD ? out->keyboard : out->mouse;
    ssize_t n;
    do {
        n = write(fd, &ev, sizeof(ev));
    } while (n < 0 && errno == EINTR && !stopping);
    if (n != (ssize_t)sizeof(ev))
        out->failed = true;
}

static int open_remote(uint8_t *keys)
{
    glob_t paths = {0};
    int found = -1;
    if (glob("/dev/input/event*", 0, NULL, &paths) != 0)
        return -1;
    for (size_t i = 0; i < paths.gl_pathc; ++i) {
        int fd = open(paths.gl_pathv[i], O_RDONLY | O_CLOEXEC);
        if (fd < 0)
            continue;
        char name[128] = {0};
        memset(keys, 0, KEY_BITS_BYTES);
        if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0 &&
            strcmp(name, "meson-ir") == 0 &&
            ioctl(fd, EVIOCGBIT(EV_KEY, KEY_BITS_BYTES), keys) >= 0 &&
            key_bit(keys, KEY_POWER) && key_bit(keys, KEY_UP) &&
            key_bit(keys, H96_TOGGLE_KEY)) {
            found = fd;
            fprintf(stderr, "h96mouse: input %s (%s)\n", paths.gl_pathv[i], name);
            break;
        }
        close(fd);
    }
    globfree(&paths);
    return found;
}

static int make_device(bool mouse, const uint8_t *keys)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return -1;
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0)
        goto fail;
    if (mouse) {
        if (ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||
            ioctl(fd, UI_SET_EVBIT, EV_REL) < 0 ||
            ioctl(fd, UI_SET_RELBIT, REL_X) < 0 ||
            ioctl(fd, UI_SET_RELBIT, REL_Y) < 0)
            goto fail;
    } else {
        for (unsigned int key = 1; key < KEY_CNT; ++key)
            if (key != H96_TOGGLE_KEY && key_bit(keys, key) &&
                ioctl(fd, UI_SET_KEYBIT, key) < 0)
                goto fail;
    }
    struct uinput_setup setup = {0};
    setup.id.bustype = BUS_VIRTUAL;
    snprintf(setup.name, sizeof(setup.name), "%s",
             mouse ? "h96-remote-mouse" : "h96-remote");
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0)
        goto fail;
    return fd;
fail:
    close(fd);
    return -1;
}

int main(void)
{
    struct sigaction action = {0};
    action.sa_handler = stop_handler;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    uint8_t keys[KEY_BITS_BYTES];
    int ir = open_remote(keys);
    if (ir < 0) {
        fprintf(stderr, "h96mouse: mapped meson-ir not ready; init will retry\n");
        return 1;
    }
    struct output_devices out = { .keyboard = -1, .mouse = -1 };
    out.keyboard = make_device(false, keys);
    out.mouse = make_device(true, keys);
    if (out.keyboard < 0 || out.mouse < 0 || ioctl(ir, EVIOCGRAB, 1) < 0) {
        perror("h96mouse: uinput/EVIOCGRAB");
        if (out.keyboard >= 0) close(out.keyboard);
        if (out.mouse >= 0) close(out.mouse);
        close(ir);
        return 1;
    }
    struct h96_remote remote = { .emit = output_event, .opaque = &out };
    while (!stopping && !out.failed) {
        struct input_event ev;
        ssize_t n = read(ir, &ev, sizeof(ev));
        if (n < 0 && errno == EINTR)
            continue;
        if (n != (ssize_t)sizeof(ev)) {
            out.failed = true;
            break;
        }
        h96_process(&remote, &ev);
    }
    h96_release(&remote);
    ioctl(ir, EVIOCGRAB, 0);
    ioctl(out.mouse, UI_DEV_DESTROY);
    ioctl(out.keyboard, UI_DEV_DESTROY);
    close(out.mouse);
    close(out.keyboard);
    close(ir);
    return out.failed ? 1 : 0;
}
