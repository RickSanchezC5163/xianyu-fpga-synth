#ifndef XIANYU_SCORE_METADATA_H
#define XIANYU_SCORE_METADATA_H
#include "score_transfer.h"
/* Source title is UTF-8 <=48 bytes. Display is GB2312 <=24 bytes, preserving
 * character boundaries. Unsupported glyphs/HMI string delimiters become '?'. */
bool xy_metadata_from_utf8(const char *title,uint16_t part,uint16_t total,xy_score_metadata *out);
/* Preserve part metadata encoded by catalog NVS titles: name·01/06. */
bool xy_metadata_from_storage_title(const char *title,xy_score_metadata *out);
bool xy_metadata_title_utf8(const uint8_t *title,size_t length,char *out,size_t capacity);
#endif
