#include "score_metadata.h"
#include <string.h>
#include "gb2312_table.inc"

static uint16_t encode_gb(uint32_t cp) {
    size_t lo=0,hi=sizeof(gb2312_table)/sizeof(gb2312_table[0]);
    while(lo<hi) {
        size_t m=lo+(hi-lo)/2;
        uint32_t word=gb2312_table[m];uint16_t code=(uint16_t)word;
        if(cp==code)return (uint16_t)(word>>16);
        if(cp<code)hi=m;else lo=m+1;
    }
    return 0;
}
static uint32_t decode_gb(uint16_t gb) {
    /* Only used for <=12 display characters on an explicit HTTP query. */
    for(size_t n=0;n<sizeof(gb2312_table)/sizeof(gb2312_table[0]);n++)
        if((uint16_t)(gb2312_table[n]>>16)==gb)return (uint16_t)gb2312_table[n];
    return '?';
}
bool xy_metadata_from_utf8(const char *title,uint16_t part,uint16_t total,xy_score_metadata *out) {
    if(!title || !out || part<1 || part>total || total>999)return false;
    size_t length=0;while(length<=48 && title[length])length++;
    if(!length || length>48)return false;
    xy_score_metadata value={0};value.part=part;value.total=total;
    bool full=false;
    for(size_t i=0;i<length;) {
        uint32_t cp=(uint8_t)title[i++],minimum=0;unsigned rest=0;
        if(cp<0x80u) { }
        else if(cp>=0xc2u && cp<=0xdfu) {cp&=31u;rest=1;minimum=0x80u;}
        else if(cp>=0xe0u && cp<=0xefu) {cp&=15u;rest=2;minimum=0x800u;}
        else if(cp>=0xf0u && cp<=0xf4u) {cp&=7u;rest=3;minimum=0x10000u;}
        else return false;
        if(length-i<rest)return false;
        for(unsigned n=0;n<rest;n++) {
            uint8_t b=(uint8_t)title[i++];if((b&0xc0u)!=0x80u)return false;
            cp=(cp<<6)|(b&63u);
        }
        if(cp<minimum || cp>0x10ffffu || (cp>=0xd800u && cp<=0xdfffu) ||
           cp<0x20u || (cp>=0x7fu && cp<=0x9fu))return false;
        uint16_t encoded=0;unsigned bytes=1;
        if(cp<0x80u)encoded=(cp=='"' || cp=='\\')?'?':(uint16_t)cp;
        else {encoded=encode_gb(cp);if(encoded)bytes=2;else encoded='?';}
        if(value.title_len+bytes>XY_META_TITLE_BYTES)full=true;
        if(!full) {
            if(bytes==2)value.title[value.title_len++]=(uint8_t)(encoded>>8);
            value.title[value.title_len++]=(uint8_t)encoded;
        }
    }
    if(!xy_gb_title_valid(value.title,value.title_len))return false;
    *out=value;return true;
}
bool xy_metadata_title_utf8(const uint8_t *title,size_t length,char *out,size_t capacity) {
    if(!out || !capacity)return false;
    out[0]=0;
    if(!xy_gb_title_valid(title,length))return false;
    size_t used=0;
    for(size_t i=0;i<length;i++) {
        uint32_t cp=title[i];
        if(cp>=0x80u) {cp=decode_gb((uint16_t)((cp<<8)|title[i+1]));i++;}
        unsigned count=cp<0x80u?1:cp<0x800u?2:3;
        if(used+count>=capacity)return false;
        if(count==1)out[used++]=(char)cp;
        else if(count==2) {out[used++]=(char)(0xc0u|(cp>>6));out[used++]=(char)(0x80u|(cp&63u));}
        else {out[used++]=(char)(0xe0u|(cp>>12));out[used++]=(char)(0x80u|((cp>>6)&63u));out[used++]=(char)(0x80u|(cp&63u));}
    }
    out[used]=0;return true;
}
bool xy_metadata_from_storage_title(const char *title,xy_score_metadata *out) {
    if(!title || !out)return false;
    const char *last=NULL,*scan=title;
    while((scan=strstr(scan,"\xc2\xb7"))!=NULL) {last=scan;scan+=2;}
    if(last && last>title) {
        const char *p=last+2;unsigned part=0,total=0,n=0;
        while(*p>='0' && *p<='9' && n<3) {part=part*10u+(unsigned)(*p++-'0');n++;}
        if(n && *p++=='/') {
            n=0;
            while(*p>='0' && *p<='9' && n<3) {total=total*10u+(unsigned)(*p++-'0');n++;}
            size_t size=(size_t)(last-title);
            if(n && !*p && part>=1 && part<=total && total<=999 && size<=48) {
                char name[49];memcpy(name,title,size);name[size]=0;
                return xy_metadata_from_utf8(name,(uint16_t)part,(uint16_t)total,out);
            }
        }
    }
    return xy_metadata_from_utf8(title,1,1,out);
}
