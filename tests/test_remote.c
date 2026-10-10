#include <assert.h>
#include <stdio.h>
#include "../device/h96proplus/h96mouse/h96mouse_core.h"

struct event { int target, type, code, value; };
static struct event events[512];
static size_t count;
static void record(void *p, enum h96_target target, int type, int code, int value)
{
    (void)p;
    assert(count < sizeof(events) / sizeof(events[0]));
    events[count++] = (struct event){target, type, code, value};
}
static void key(struct h96_remote *r, int code, int value)
{
    struct input_event ev = {.type = EV_KEY, .code = code, .value = value};
    h96_process(r, &ev);
}
static void toggle(struct h96_remote *r)
{
    key(r, H96_TOGGLE_KEY, 1);
    key(r, H96_TOGGLE_KEY, 0);
}
static void expect(size_t i, int target, int type, int code, int value)
{
    assert(i < count);
    assert(events[i].target == target && events[i].type == type &&
           events[i].code == code && events[i].value == value);
}

int main(void)
{
    struct h96_remote r = {.emit = record};
    key(&r, KEY_UP, 1); key(&r, KEY_UP, 2); key(&r, KEY_UP, 0);
    assert(count == 6);
    expect(0, H96_KEYBOARD, EV_KEY, KEY_UP, 1);
    expect(2, H96_KEYBOARD, EV_KEY, KEY_UP, 2);
    expect(4, H96_KEYBOARD, EV_KEY, KEY_UP, 0);
    count = 0;

    key(&r, H96_TOGGLE_KEY, 1);
    key(&r, H96_TOGGLE_KEY, 2);
    key(&r, H96_TOGGLE_KEY, 1); /* repeated NEC full frame */
    assert(r.mouse_mode && count == 0);
    key(&r, H96_TOGGLE_KEY, 0);
    const int keys[] = {KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT};
    const int axes[] = {REL_Y, REL_Y, REL_X, REL_X};
    const int deltas[] = {-18, 18, -18, 18};
    for (int i = 0; i < 4; ++i) {
        count = 0;
        key(&r, keys[i], 1); key(&r, keys[i], 2); key(&r, keys[i], 0);
        assert(count == 4); /* no keyboard or release leakage */
        expect(0, H96_MOUSE, EV_REL, axes[i], deltas[i]);
        expect(2, H96_MOUSE, EV_REL, axes[i], deltas[i]);
    }
    count = 0;
    key(&r, KEY_SELECT, 1); key(&r, KEY_SELECT, 2); key(&r, KEY_SELECT, 0);
    assert(count == 4);
    expect(0, H96_MOUSE, EV_KEY, BTN_LEFT, 1);
    expect(2, H96_MOUSE, EV_KEY, BTN_LEFT, 0);

    const int pass[] = {KEY_POWER, KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_BACK, KEY_HOMEPAGE};
    for (unsigned int i = 0; i < sizeof(pass) / sizeof(pass[0]); ++i) {
        count = 0;
        key(&r, pass[i], 1); key(&r, pass[i], 0);
        assert(count == 4 && r.mouse_mode);
        expect(0, H96_KEYBOARD, EV_KEY, pass[i], 1);
        expect(2, H96_KEYBOARD, EV_KEY, pass[i], 0);
    }

    /* Switching off mid-click releases BTN_LEFT exactly once. */
    count = 0;
    key(&r, KEY_SELECT, 1);
    toggle(&r);
    key(&r, KEY_SELECT, 0);
    assert(!r.mouse_mode && !r.left_down && count == 4);
    expect(2, H96_MOUSE, EV_KEY, BTN_LEFT, 0);

    /* Switching on mid-D-pad hold releases the key, then suppresses repeats. */
    count = 0;
    key(&r, KEY_LEFT, 1); toggle(&r);
    key(&r, KEY_LEFT, 2); key(&r, KEY_LEFT, 0);
    assert(count == 4);
    expect(2, H96_KEYBOARD, EV_KEY, KEY_LEFT, 0);

    /* Lost input packets cannot leave synthetic buttons stuck. */
    count = 0;
    key(&r, KEY_SELECT, 1); key(&r, KEY_VOLUMEUP, 1);
    struct input_event lost = {.type = EV_SYN, .code = SYN_DROPPED};
    h96_process(&r, &lost);
    assert(r.syncing && !r.left_down && count == 8);
    key(&r, H96_TOGGLE_KEY, 1);
    assert(r.mouse_mode);
    struct input_event sync = {.type = EV_SYN, .code = SYN_REPORT};
    h96_process(&r, &sync);
    key(&r, KEY_SELECT, 2);
    assert(count == 8);
    key(&r, KEY_SELECT, 1);
    h96_release(&r); /* unplug / process exit */
    assert(!r.left_down);
    expect(count - 2, H96_MOUSE, EV_KEY, BTN_LEFT, 0);
    puts("remote: navigation, 4 directions, repeat, click, passthrough, toggles, overflow: PASS");
    return 0;
}
