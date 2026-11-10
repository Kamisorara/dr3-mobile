// 安卓 SemanticControlsView$Route 忠实 C 移植（jadx 1320-1650 行逐条对表；2026-11-10 触控重构轮）。
// 触点分配：Owner(control|raw)→SemanticInput 压键/摇杆；raw（control==null）触点集经
// listener.changedAt 进 UI 指针通道；摇杆轻点 <350ms 且无其他 raw → tap 合成事件。
// syncOwner(generation) 换代即 releaseSemantic（全释放+技能取消+闪避丢弃）。
// | Faithful C port of the Android Route touch-allocation engine. Pure C, unit-testable.
#ifndef DM_SEMANTIC_ROUTE_H
#define DM_SEMANTIC_ROUTE_H

#include "DmSemanticInput.h"
#include "DmSemanticLayout.h"
#include "DmSkillAim.h"

#define DMROUTE_OWN_N 16

typedef struct DmSemRouteListener {
    void *ctx;
    // raw（未认领）触点集 + 语义态（安卓 changedAt→publishSemanticInput：uiPointer+nativeTouch+nativeControls）
    void (*changed_at)(void *ctx, const DmSemState *st, int cancelled,
                       const int *ids, const float *xs, const float *ys, int n, long long ms);
    // 技能瞄准事件（安卓 skills→skillPublisher.publish）
    void (*skills)(void *ctx, long long owner, const DmAimEvent *ev, int n, int w, int h, int cancelled);
    // 摇杆轻点透传（安卓 tap→合成 down/up 喂 uiPointer）
    void (*tap)(void *ctx, long long owner, int id, float x, float y,
                long long down_ms, long long up_ms, const DmSemState *snap);
    // 拾取边沿（安卓 pickup→nativePickupEdge；token 恒 0 时拾取钮禁用）
    void (*pickup)(void *ctx, long long token, int phase);
} DmSemRouteListener;

typedef struct {
    int pid, ctrl;           // ctrl = Layout 控件下标，-1=raw
    int active, moved;
    float x, y, downX, downY;
    long long downMs;
    long long pickupToken;
} DmRouteOwner;

typedef struct {
    DmSemInput input;
    DmSkillAim aim;
    DmRouteOwner own[DMROUTE_OWN_N]; int ownN;
    DmSemControl *ctrl; int ctrlN;           // 当前布局控件表（视图 rebuild 后重绑；安卓同款共享引用）
    const DmSemRouteListener *ln;            // 视图生命周期常量（pickup 回调直用）
    long long eventMs;
    long long pickupToken;
    long long ownerGeneration;   // -1 = 未挂代（安卓初值）
    int cancelSkills;
    int touchSlop;               // px；安卓 ViewConfiguration touchSlop，iOS 用 12pt 约定
    long long longPressMs;       // 安卓 getLongPressTimeout（500）
    // tap 待发（安卓 tap/tapId/tapOwner）
    int tapValid, tapId;
    float tapX, tapY;
    long long tapDownMs, tapOwner;
} DmSemRoute;

void dmroute_init(DmSemRoute *r);
void dmroute_bind_controls(DmSemRoute *r, DmSemControl *c, int n);
void dmroute_set_listener(DmSemRoute *r, const DmSemRouteListener *ln);
void dmroute_set_pickup(DmSemRoute *r, long long token);
// 触点事件（eventMs 由视图喂，安卓 route.eventMs 同源）
void dmroute_down(DmSemRoute *r, int id, int ctrl, float x, float y, long long ms);
void dmroute_move(DmSemRoute *r, int id, float x, float y, long long ms);
void dmroute_up(DmSemRoute *r, int id, long long ms);
void dmroute_cancel(DmSemRoute *r, long long ms);
// 显隐换代：代相同→0（无动作）；代变化→全释放并发布（安卓 syncOwner/releaseSemantic）
int  dmroute_sync_owner(DmSemRoute *r, long long generation, int w, int h);
// 发布：raw 集 + 语义态 + 技能事件 + tap 回放（安卓 Route.publish；ln 须已 set_listener）
void dmroute_publish(DmSemRoute *r, int cancelled, int w, int h);
long long dmroute_next_long_press_delay(const DmSemRoute *r, long long now);   // -1=无
int  dmroute_long_press(DmSemRoute *r, long long now);

#endif
