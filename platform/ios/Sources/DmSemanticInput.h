// 安卓 SemanticInput 忠实 C 移植（jadx 全文对表；2026-11-10 触控重构轮）。
// 摇杆曲线 = 安卓原版：mag=dist/radius 夹 1，死区 0.12，线性 remap (mag-0.12)/(1-0.12)*32767
//（旧 iOS 版的 0.72 饱和点系误读，本轮纠正）。dy 取反（centerY-y，上=正）。
// | Faithful C port of Android SemanticInput: two sticks, dead zone 0.12 with linear remap,
// | evade vector queue, button bitmap by pointer. Pure C, unit-testable.
#ifndef DM_SEMANTIC_INPUT_H
#define DM_SEMANTIC_INPUT_H

#define DMSI_HELD_N 16
#define DMSI_EVADE_N 32

typedef struct {
    long long buttons;      // 按位 OR 的按键掩码（安卓 button mask）
    int lx, ly, rx, ry;     // 摇杆 [-32767,32767]，上=正
    int evade[8];           // 本拍闪避向量（x,y 对，已排水）
    int evadeN;
    int cancelEvades;
} DmSemState;

typedef struct { int owner; float cx, cy, radius; int x, y; } DmSemStick;

typedef struct {
    float deadZone;         // 0.12（安卓构造缺省）
    struct { int pid; unsigned long long buttons; } held[DMSI_HELD_N]; int heldN;
    DmSemStick sticks[2];
    int evades[DMSI_EVADE_N]; int evadeN;   // 待排空向量（x,y 对）
    int cancelEvades;
} DmSemInput;

void dmsi_init(DmSemInput *s);
void dmsi_press(DmSemInput *s, int pid, unsigned long long buttons);   // buttons=0 → 移除
void dmsi_release(DmSemInput *s, int pid);                             // 同时清该指的摇杆
int  dmsi_begin_stick(DmSemInput *s, int pid, int stick, float cx, float cy, float radius);
void dmsi_move(DmSemInput *s, int pid, float x, float y);
void dmsi_cancel(DmSemInput *s);
void dmsi_evade(DmSemInput *s);                        // 压入左摇杆方向向量（归一×32767）
void dmsi_discard_evades(DmSemInput *s);
DmSemState dmsi_snapshot(const DmSemInput *s);
DmSemState dmsi_publication(DmSemInput *s);            // snapshot + 排空 evades + 消费 cancelEvades

#endif
