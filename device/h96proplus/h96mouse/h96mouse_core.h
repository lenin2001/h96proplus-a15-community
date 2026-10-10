// SPDX-License-Identifier: GPL-2.0
#ifndef H96MOUSE_CORE_H
#define H96MOUSE_CORE_H

#include <linux/input.h>
#include <stdbool.h>
#include <string.h>

#define H96_TOGGLE_KEY KEY_F13
#define H96_MOUSE_STEP 18

enum h96_target { H96_KEYBOARD, H96_MOUSE };
enum h96_route { H96_DROP, H96_KEY, H96_POINTER };
typedef void (*h96_emit_fn)(void *, enum h96_target, int, int, int);

struct h96_remote {
    bool mouse_mode;
    bool syncing;
    bool left_down;
    bool down[KEY_CNT];
    unsigned char route[KEY_CNT];
    h96_emit_fn emit;
    void *opaque;
};

static inline void h96_emit(struct h96_remote *r, enum h96_target target,
                            int type, int code, int value)
{
    r->emit(r->opaque, target, type, code, value);
    r->emit(r->opaque, target, EV_SYN, SYN_REPORT, 0);
}

/* Release synthetic holds, but suppress physical repeats until key-up.
 * Used on mode switches, SYN_DROPPED and daemon shutdown. */
static inline void h96_release(struct h96_remote *r)
{
    for (unsigned int key = 0; key < KEY_CNT; ++key) {
        if (r->route[key] == H96_KEY && r->down[key])
            h96_emit(r, H96_KEYBOARD, EV_KEY, key, 0);
        r->route[key] = H96_DROP;
    }
    if (r->left_down)
        h96_emit(r, H96_MOUSE, EV_KEY, BTN_LEFT, 0);
    r->left_down = false;
}

static inline bool h96_is_ok(unsigned int key)
{
    return key == KEY_ENTER || key == KEY_KPENTER ||
           key == KEY_SELECT || key == KEY_RIGHTCTRL;
}

static inline bool h96_move(struct h96_remote *r, unsigned int key)
{
    switch (key) {
    case KEY_UP:    h96_emit(r, H96_MOUSE, EV_REL, REL_Y, -H96_MOUSE_STEP); break;
    case KEY_DOWN:  h96_emit(r, H96_MOUSE, EV_REL, REL_Y, H96_MOUSE_STEP); break;
    case KEY_LEFT:  h96_emit(r, H96_MOUSE, EV_REL, REL_X, -H96_MOUSE_STEP); break;
    case KEY_RIGHT: h96_emit(r, H96_MOUSE, EV_REL, REL_X, H96_MOUSE_STEP); break;
    default: return false;
    }
    return true;
}

static inline void h96_process(struct h96_remote *r, const struct input_event *ev)
{
    if (ev->type == EV_SYN && ev->code == SYN_DROPPED) {
        h96_release(r);
        memset(r->down, 0, sizeof(r->down));
        r->syncing = true;
        return;
    }
    if (r->syncing) {
        if (ev->type == EV_SYN && ev->code == SYN_REPORT)
            r->syncing = false;
        return;
    }
    if (ev->type != EV_KEY || ev->code >= KEY_CNT ||
        ev->value < 0 || ev->value > 2)
        return;

    const unsigned int key = ev->code;
    int value = ev->value;
    if (value == 1 && r->down[key])
        value = 2;
    if (value == 2 && !r->down[key])
        return;

    if (key == H96_TOGGLE_KEY) {
        if (value == 1) {
            h96_release(r);
            r->mouse_mode = !r->mouse_mode;
        }
        r->down[key] = value != 0;
        return;
    }

    if (value == 0) {
        if (r->route[key] == H96_KEY && r->down[key])
            h96_emit(r, H96_KEYBOARD, EV_KEY, key, 0);
        else if (r->route[key] == H96_POINTER && h96_is_ok(key) && r->left_down) {
            h96_emit(r, H96_MOUSE, EV_KEY, BTN_LEFT, 0);
            r->left_down = false;
        }
        r->down[key] = false;
        r->route[key] = H96_DROP;
        return;
    }
    if (value == 1) {
        r->down[key] = true;
        if (r->mouse_mode && h96_move(r, key)) {
            r->route[key] = H96_POINTER;
            return;
        }
        if (r->mouse_mode && h96_is_ok(key)) {
            r->route[key] = H96_POINTER;
            if (!r->left_down)
                h96_emit(r, H96_MOUSE, EV_KEY, BTN_LEFT, 1);
            r->left_down = true;
            return;
        }
        /* POWER, HOME, BACK, volume and every other key remain usable. */
        r->route[key] = H96_KEY;
    }
    if (r->route[key] == H96_KEY)
        h96_emit(r, H96_KEYBOARD, EV_KEY, key, value);
    else if (r->route[key] == H96_POINTER && r->mouse_mode)
        h96_move(r, key);
}
#endif
