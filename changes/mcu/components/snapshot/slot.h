#pragma once
#include <stdint.h>
#include <stdbool.h>

enum { SNAP_WORDS = 6309, SNAP_WORD_BYTES = 8, SNAP_ID_BYTES = 8 };
typedef enum { SNAP_OK, SNAP_EMPTY, SNAP_INVALID, SNAP_IO, SNAP_LINK, SNAP_UNSUPPORTED, SNAP_WRONG, SNAP_BUSY, SNAP_HW } snap_result_t;
typedef snap_result_t (*snap_word_fn)(uint16_t index, uint8_t word[SNAP_WORD_BYTES]);
uint16_t snap_word_count(const uint8_t id[SNAP_ID_BYTES]);
/* Capture has already finished, or restore will be issued only after this returns OK. */
snap_result_t snap_slot(const char *directory, const uint8_t id[SNAP_ID_BYTES],
                        bool loading, snap_word_fn transfer);
