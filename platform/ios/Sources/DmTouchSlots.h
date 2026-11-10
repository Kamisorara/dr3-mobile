// 安卓 TouchSlots.java 逐行 C 移植（2026-11-10 完全照搬轮）。
// 触点 id → 稳定槽号（0..15）分配：retain 收缩存活集，slot 先查旧后开新；
// .so dm_touch_set 的槽位表按此槽号索引（nativeTouch 契约）。
// | Faithful C port of Android TouchSlots: stable pointer-id → slot allocation.
#ifndef DM_TOUCH_SLOTS_H
#define DM_TOUCH_SLOTS_H

#define DMTS_N 16

typedef struct {
    int ids[DMTS_N];   // -1 = 空槽
} DmTouchSlots;

void dmts_init(DmTouchSlots *s);                            // 全 -1（构造即 clear）
void dmts_clear(DmTouchSlots *s);
void dmts_retain(DmTouchSlots *s, const int *active, int n); // 不在 active 集的槽释放
int  dmts_slot(DmTouchSlots *s, int id);                     // 已占→原槽；否则开首个空槽；-1 满/非法

#endif
