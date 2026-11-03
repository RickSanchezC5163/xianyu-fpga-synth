#include "score_resident_sync.h"
#include "score_metadata.h"
#include <string.h>

void xy_resident_sync_init(xy_resident_sync *sync) {
    memset(sync,0,sizeof(*sync));sync->dirty_mask=(1u<<XY_RESIDENT_SLOTS)-1u;
}
void xy_resident_sync_dirty(xy_resident_sync *sync,uint8_t slot) {
    if(slot>=XY_RESIDENT_SLOTS)return;
    sync->dirty_mask|=(uint8_t)(1u<<slot);
    sync->synchronized_mask&=(uint8_t)~(1u<<slot);
}
void xy_resident_sync_complete(xy_resident_sync *sync,uint8_t slot,bool present) {
    if(slot>=XY_RESIDENT_SLOTS)return;
    sync->dirty_mask&=(uint8_t)~(1u<<slot);
    if(present)sync->synchronized_mask|=(uint8_t)(1u<<slot);
    else sync->synchronized_mask&=(uint8_t)~(1u<<slot);
    sync->error=XY_OK;
}
int xy_resident_sync_round(xy_resident_sync *sync,xy_link *link,uint8_t buffer[XY_MAX_SCORE_BYTES],
    xy_resident_load_fn load,xy_resident_timeout_fn timeout,void *context,uint32_t token) {
    if(!sync || !link || !buffer || !load || !timeout || !token)return XY_BAD_ARGUMENT;
    if(link->staging)return XY_BUSY;
    xy_resident_summary summary;
    timeout(context,50);
    int result=xy_read_resident_summary_once(link,&summary);
    timeout(context,500);
    if(result!=XY_OK) {
        sync->dirty_mask|=sync->synchronized_mask;sync->synchronized_mask=0;
        sync->error=result;return result;
    }
    sync->dirty_mask|=sync->synchronized_mask&(uint8_t)~summary.valid_mask;
    sync->synchronized_mask&=summary.valid_mask;
    if(!sync->dirty_mask) {sync->error=XY_OK;return XY_OK;}
    uint8_t slot=sync->cursor;
    while(!(sync->dirty_mask&(1u<<slot)))slot=(slot+1u)%XY_RESIDENT_SLOTS;
    sync->cursor=(slot+1u)%XY_RESIDENT_SLOTS;
    char title[XY_SCORE_TITLE_BYTES];size_t length=0;
    result=load(context,slot,title,buffer,&length);
    bool present=result==XY_OK;
    if(result==XY_RESIDENT_MISSING) {
        result=(summary.valid_mask&(1u<<slot))?xy_clear_resident_score(link,slot):XY_OK;
    } else if(present) {
        xy_score score;xy_score_metadata metadata;
        if(xy_score_validate(buffer,length,&score)!=XY_FILE_OK ||
           !xy_metadata_from_storage_title(title,&metadata))result=XY_RESIDENT_INVALID_STORAGE;
        else {
            metadata.resident_slot=slot+1u;metadata.store_only=true;
            result=xy_stage_score_named(link,&score,token,&metadata);
            if(result==XY_OK)result=xy_commit_score(link);
            if(result!=XY_OK && link->staging) {
                /* Only this round owns the staging transaction. A BUSY cache
                 * update is retried later, never exposed as a manual commit. */
                timeout(context,50);(void)xy_abort_score(link);timeout(context,500);
            }
        }
    }
    if(result==XY_OK)xy_resident_sync_complete(sync,slot,present);
    else sync->error=result;
    return result;
}
