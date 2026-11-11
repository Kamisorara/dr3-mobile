// Adapted from Blade II Mobile gamepad_generic.m (MIT); see third_party/LICENSE.blade2.
// Nintendo position mapping, separate physical input, hot plug and focus management.
#import <GameController/GameController.h>
#include <TargetConditionals.h>
#include <math.h>
#include <string.h>
#include "dm.h"
#include "dm_input.h"
#include "dm_padmap.h"

enum { NSLOT = 8 };
static struct { const void *who; uint64_t b; int32_t ax[4]; } g_s[NSLOT];
static int g_active = 1;
static int g_count;                            // number of attached extended gamepads
static void (*g_on_present)(int present);
static int g_face_letter = -1; static float g_dead = -1;

static int slot_of(const void *who, int make) {
    int fr = -1;
    for (int i = 0; i < NSLOT; i++) { if (g_s[i].who == who) return i; if (fr < 0 && !g_s[i].who) fr = i; }
    if (make && fr >= 0) { memset(&g_s[fr], 0, sizeof g_s[fr]); g_s[fr].who = who; return fr; }
    return -1;
}
// Optional bounded publication trace. Uses the same clock as the guest HID receipt.
static void trace(uint64_t buttons, const int32_t axes[4]) {
    static FILE *file; static int initialized, count;
    static uint64_t last_buttons, last_flush;
    if (!initialized) {
        initialized = 1; const char *path = getenv("DM_PAD_EVENT_LOG");
        if (path && *path) { file = fopen(path, "w"); if (!file) LOG("Cannot open gamepad event log: %s", path); }
    }
    if (!file || count >= 65536) return;
    uint64_t time = now_ns();
    fprintf(file, "{\"time_ns\":%llu,\"buttons\":%llu,\"axes\":[%d,%d,%d,%d],\"active\":%d,\"controllers\":%d,\"read_samples\":%llu}\n",
        (unsigned long long)time, (unsigned long long)buttons, axes[0], axes[1], axes[2], axes[3],
        g_active, g_count, (unsigned long long)dm_input_samples());
    if (++count == 65536) fprintf(file, "{\"limit_reached\":65536}\n");
    if (buttons != last_buttons || (!axes[0] && !axes[1] && !axes[2] && !axes[3]) || !g_active || time - last_flush >= 1000000000ull || count == 65536) { fflush(file); last_flush = time; }
    last_buttons = buttons;
}
// Merge all controllers and hand the result to the host
static void apply(void) {
    uint64_t b = 0; int32_t ax[4] = {0}; double best[2] = {0};
    for (int i = 0; i < NSLOT; i++) {
        if (!g_s[i].who) continue; b |= g_s[i].b;
        for (int k = 0; k < 2; k++) { double m = hypot(g_s[i].ax[2 * k], g_s[i].ax[2 * k + 1]); if (m > best[k]) { best[k] = m; ax[2 * k] = g_s[i].ax[2 * k]; ax[2 * k + 1] = g_s[i].ax[2 * k + 1]; } }
    }
    dm_pad_set(b, ax[0], ax[1], ax[2], ax[3]);
    trace(b, ax);
}
// Stick: radial dead zone, then rescale to full range
static void stick(float x, float y, int32_t *ox, int32_t *oy) {
    if (g_dead < 0) { const char *e = getenv("DM_PAD_DEADZONE"); g_dead = e ? (float)atof(e) : 0.12f; if (!isfinite(g_dead) || g_dead < 0 || g_dead > 0.9f) g_dead = 0.12f; }
    if (!isfinite(x) || !isfinite(y)) { *ox = *oy = 0; return; }
    float m = hypotf(x, y);
    if (m <= g_dead) { *ox = *oy = 0; return; }
    float k = (fminf(m, 1.0f) - g_dead) / (1.0f - g_dead) / m;   // dead-zone edge = 0, rim = 1
    *ox = (int32_t)lroundf(x * k * DM_STICK_MAX); *oy = (int32_t)lroundf(y * k * DM_STICK_MAX);
}
static void publish(GCController *c, GCExtendedGamepad *g) {
    if (g_face_letter < 0) { const char *e = getenv("DM_PAD_FACE"); g_face_letter = e && !strcmp(e, "letter") ? 1 : e && !strcmp(e, "position") ? 0 : -2; }
    if (!g_active) return;
    uint64_t b = 0;
    int bot = g.buttonA.pressed, rgt = g.buttonB.pressed, lft = g.buttonX.pressed, top = g.buttonY.pressed;
    // iOS 16+ 对 Switch 系手柄按键帽字母上报（buttonA = 键帽 A = 东位），对 Xbox/MFi 按位置上报（buttonA = 南位）。
    // 旧逻辑一律当位置用 → Switch Pro 全部错位一格（A/B 反、X/Y 反，2026-11-11 真机）。
    // 按手柄类别选映射（dm_padmap.h：switch/nintendo/joy-con = Nintendo）；DM_PAD_FACE=letter/position 强制覆盖。
    int letter = g_face_letter >= 0 ? g_face_letter
        : dm_padmap_kind(c.productCategory.UTF8String ?: "", c.vendorName.UTF8String ?: "") == DM_PADKIND_NINTENDO;
    if (letter) { if (bot) b |= DM_BTN_A; if (rgt) b |= DM_BTN_B; if (lft) b |= DM_BTN_X; if (top) b |= DM_BTN_Y; }   // 字母直映（键帽即语义）
    else { if (rgt) b |= DM_BTN_A; if (bot) b |= DM_BTN_B; if (top) b |= DM_BTN_X; if (lft) b |= DM_BTN_Y; }   // 位置映射（南=确认）
    if (g.leftShoulder.pressed) b |= DM_BTN_L; if (g.rightShoulder.pressed) b |= DM_BTN_R;
    if (g.leftTrigger.pressed) b |= DM_BTN_ZL; if (g.rightTrigger.pressed) b |= DM_BTN_ZR;
    if (g.leftThumbstickButton.pressed) b |= DM_BTN_LS; if (g.rightThumbstickButton.pressed) b |= DM_BTN_RS;
    if (g.buttonMenu.pressed) b |= DM_BTN_PLUS; if (g.buttonOptions.pressed) b |= DM_BTN_MINUS;
    if (g.dpad.left.pressed) b |= DM_BTN_LEFT; if (g.dpad.up.pressed) b |= DM_BTN_UP; if (g.dpad.right.pressed) b |= DM_BTN_RIGHT; if (g.dpad.down.pressed) b |= DM_BTN_DOWN;
    int i = slot_of((__bridge const void *)c, 1); if (i < 0) return;
    g_s[i].b = b;
    stick(g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value, &g_s[i].ax[0], &g_s[i].ax[1]);
    stick(g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value, &g_s[i].ax[2], &g_s[i].ax[3]);
    apply();
}
static void present_changed(void) { static int was = -1; int now = g_count > 0; if (now == was) return; was = now; if (g_on_present) g_on_present(now); }
static void attach(GCController *c) {
    GCExtendedGamepad *g = c.extendedGamepad;
    if (!g) { LOG("Gamepad unsupported (no extended profile): %s", c.vendorName.UTF8String ?: "?"); return; }
    if (slot_of((__bridge const void *)c, 0) >= 0) return;   // already attached (start enumeration and the connect notification can both arrive)
    if (slot_of((__bridge const void *)c, 1) < 0) { LOG("Gamepad slots full (%d): %s", NSLOT, c.vendorName.UTF8String ?: "?"); return; }
    g_count++;
    c.handlerQueue = dispatch_get_main_queue();
    LOG("Gamepad connected: %s (%s), count=%d, face=%s, deadzone=%s", c.vendorName.UTF8String ?: "?",
        c.productCategory.UTF8String ?: "?", g_count,
        g_face_letter >= 0 ? (g_face_letter ? "letter" : "position")
            : dm_padmap_kind(c.productCategory.UTF8String ?: "", c.vendorName.UTF8String ?: "") == DM_PADKIND_NINTENDO ? "letter(auto)" : "position(auto)",
        getenv("DM_PAD_DEADZONE") ?: "0.12");
    __weak GCController *wc = c;
    g.valueChangedHandler = ^(GCExtendedGamepad *gp, GCControllerElement *el) { (void)el; GCController *sc = wc; if (sc) publish(sc, gp); };
    publish(c, g);
    present_changed();
}
static void detach(GCController *c) {
    int i = slot_of((__bridge const void *)c, 0); if (i < 0) return;
    c.extendedGamepad.valueChangedHandler = nil;
    memset(&g_s[i], 0, sizeof g_s[i]); g_count--; apply();
    if (!g_count) dm_pad_clear();
    LOG("Gamepad disconnected: %s, count=%d", c.vendorName.UTF8String ?: "?", g_count);
    present_changed();
}

int dm_gamepad_count(void) { return g_count; }
void dm_gamepad_reset(void) {
    int any = 0;
    for (int i = 0; i < NSLOT; i++) if (g_s[i].who) { any |= g_s[i].b != 0 || g_s[i].ax[0] || g_s[i].ax[1] || g_s[i].ax[2] || g_s[i].ax[3]; g_s[i].b = 0; memset(g_s[i].ax, 0, sizeof g_s[i].ax); }
    dm_pad_clear();
    const int32_t zero[4] = {0}; trace(0, zero);
    if (any) LOG("Gamepad focus lost: cleared buttons and axes");
}
void dm_gamepad_start(void (*on_present)(int present)) {
    static int started; if (started) return; started = 1;
    g_on_present = on_present;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { attach(n.object); }];
    [nc addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { detach(n.object); }];
    NSArray<GCController *> *cs = GCController.controllers;
    LOG("GameController started: system controllers=%lu, face=%s, deadzone=%s", (unsigned long)cs.count,
        getenv("DM_PAD_FACE") ?: "position", getenv("DM_PAD_DEADZONE") ?: "0.12");
    for (GCController *c in cs) attach(c);   // attaching one calls back on_present(1)
    if (!g_count) present_changed();         // none: call back once with 0 for the current count
}

// Called on the AppKit main thread. Background callbacks cannot republish held keys.
void dm_gamepad_set_active(int active) {
    g_active = active;
    if (!active) { dm_gamepad_reset(); return; }
    for (GCController *c in GCController.controllers)
        if (slot_of((__bridge const void *)c, 0) >= 0) publish(c, c.extendedGamepad);
}
