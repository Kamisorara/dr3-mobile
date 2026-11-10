// 安卓 SemanticControlsView$Control+$Layout 忠实 C 移植（jadx 932-1320 行逐条对表；2026-11-10 触控重构轮）。
// 几何引擎：scale=min(可用宽/1851, 可用高/849) 右组锚右下、摇杆锚左+groupTop、worldControls=0 → 空数组
//（面不收触控，全落菜单指针通道——安卓显隐机制本体）。纯 C 可单测（tests/test_semantic_layout.c）。
// | Faithful C port of the Android SemanticControlsView Layout engine: design canvas 1851x849
// | anchored bottom-right, stick zone left-bottom 40%x50%, empty control set when worldControls
// | is off (all touches fall through to the menu pointer channel). Pure C, unit-testable.
#ifndef DM_SEMANTIC_LAYOUT_H
#define DM_SEMANTIC_LAYOUT_H

// kind：0=摇杆 2=按键 3=闪避 4=拾取（安卓 Control.kind 同值）
// button：安卓键掩码 1=A 2=B 4=X 8=Y 128=药 256=ZL 512=ZR 1024=包 2048=单 16384=城
typedef struct DmSemControl {
    int kind;
    unsigned long long button;
    int slot;                // 技能槽 0..5，-1=非技能
    float x, y;              // 视图点坐标
    float halfW, halfH;
    float hitRadius;         // = max(halfW, minimumRadius)（安卓 Control 构造同式）
    int enabled, held;
} DmSemControl;

typedef struct DmSemLayout {
    DmSemControl c[16];
    int n;
    float stickL, stickT, stickR, stickB;   // 摇杆认领区（左 40% × 下半可用区）
    float unit;                              // min(density, min(可用宽/720, 可用高/400))
    float scale;                             // min(可用宽/1851, 可用高/849)
} DmSemLayout;

// density：安卓 display density；iOS 无同物，用 2.0（point≈dp 的中值约定，kb/07 §12）
void dm_semlayout_build(DmSemLayout *L, float width, float height, float density,
                        int left, int top, int right, int bottom,
                        int worldControls, float rightMargin, int includePickup);
// 安卓 Layout.hit：倒序扫（后加者优先：拾取>弧>攻>闪>药>城>顶排），摇杆只做记忆、
// 循环后在认领区内兜底；未命中返回 -1。
int dm_semlayout_hit(const DmSemLayout *L, float x, float y);
// 安卓 roleBottomNormalized：非顶排（button≠1024/2048）enabled 控件的 max(y+halfH)/viewH；无 → -1
float dm_semlayout_role_bottom(const DmSemLayout *L, float viewH);

#endif
