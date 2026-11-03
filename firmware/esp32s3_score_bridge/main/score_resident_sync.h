#ifndef XIANYU_SCORE_RESIDENT_SYNC_H
#define XIANYU_SCORE_RESIDENT_SYNC_H
#include "score_transfer.h"
#include "score_record.h"

/* Load returns OK, MISSING, or an application storage error. No ESP dependency. */
/* Keep these separate from ESP_FAIL (-1) returned by a storage adapter. */
enum { XY_RESIDENT_MISSING=-1001, XY_RESIDENT_INVALID_STORAGE=-1002 };
typedef int (*xy_resident_load_fn)(void *context,uint8_t slot,char title[XY_SCORE_TITLE_BYTES],
    uint8_t score[XY_MAX_SCORE_BYTES],size_t *length);
typedef void (*xy_resident_timeout_fn)(void *context,unsigned timeout_ms);
typedef struct {
    uint8_t dirty_mask,synchronized_mask,cursor;
    int error;
} xy_resident_sync;

void xy_resident_sync_init(xy_resident_sync *sync);
void xy_resident_sync_dirty(xy_resident_sync *sync,uint8_t slot);
/** Successful named manual selection also confirms that resident mapping. */
void xy_resident_sync_complete(xy_resident_sync *sync,uint8_t slot,bool present);
/** One short liveness query and at most one slot restore/clear. Caller holds the
 * shared UART/buffer/NVS mutex; invoke no faster than once per 500ms. A manual
 * pending transaction is left intact. Timeout callback is restored to 500ms. */
int xy_resident_sync_round(xy_resident_sync *sync,xy_link *link,uint8_t buffer[XY_MAX_SCORE_BYTES],
    xy_resident_load_fn load,xy_resident_timeout_fn timeout,void *context,uint32_t token);
#endif
