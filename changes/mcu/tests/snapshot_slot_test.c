/* cc -std=c11 -Icomponents/snapshot tests/snapshot_slot_test.c components/snapshot/slot.c -o /tmp/slot-test */
#include "slot.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int pattern, interrupt_at = -1;
static unsigned restored;
static uint8_t byte_at(uint16_t i, int j) { return (uint8_t)(pattern + i * 13 + j); }
static snap_result_t capture(uint16_t i, uint8_t word[8]) {
    if (i == interrupt_at) return SNAP_LINK;
    for (int j=0; j<8; ++j) word[j] = byte_at(i, j);
    return SNAP_OK;
}
static snap_result_t restore(uint16_t i, uint8_t word[8]) {
    assert(i == restored++);
    for (int j=0; j<8; ++j) assert(word[j] == byte_at(i, j));
    return SNAP_OK;
}
int main(void) {
    char temp[] = "/tmp/chromatic-slot-XXXXXX";
    char *dir = mkdtemp(temp);
    uint8_t id[8] = {0,0,0,0x88,1,2,3,4};
    assert(dir);
    assert(snap_slot(dir, id, true, restore) == SNAP_EMPTY);
    pattern = 73;
    assert(snap_slot(dir, id, false, capture) == SNAP_OK);
    pattern = 92; interrupt_at = 213;
    assert(snap_slot(dir, id, false, capture) == SNAP_LINK);
    pattern = 73; restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    pattern = 31; interrupt_at = -1;
    assert(snap_slot(dir, id, false, capture) == SNAP_OK);
    restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    char second[64], first[64];
    snprintf(second, sizeof second, "%s/01020304.S1", dir);
    snprintf(first, sizeof first, "%s/01020304.S0", dir);
    FILE *f = fopen(second, "r+b");
    assert(f && fseek(f, 16, SEEK_SET) == 0 && fputc(0, f) == 0 && fclose(f) == 0);
    pattern = 73; restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);

    /* A damaged game ID in the newer file must fall back to the older save. */
    pattern = 31;
    assert(snap_slot(dir, id, false, capture) == SNAP_OK);
    f = fopen(second, "r+b");
    assert(f && fseek(f, 7, SEEK_SET) == 0 && fputc(0, f) == 0 && fclose(f) == 0);
    pattern = 73; restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);

    /* A valid file for a different ID can share the same filename hash. */
    uint8_t other_id[8];
    memcpy(other_id, id, sizeof other_id);
    other_id[3]++;
    char other_directory[] = "/tmp/chromatic-slot-XXXXXX";
    assert(mkdtemp(other_directory));
    pattern = 49;
    assert(snap_slot(other_directory, other_id, false, capture) == SNAP_OK);
    char other_file[64];
    snprintf(other_file, sizeof other_file, "%s/01020304.S0", other_directory);
    assert(rename(other_file, second) == 0 && rmdir(other_directory) == 0);
    pattern = 73; restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    assert(snap_slot(dir, id, false, capture) == SNAP_WRONG);
    pattern = 49; restored = 0;
    assert(snap_slot(dir, other_id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    assert(unlink(second) == 0);
    id[3]++;
    assert(snap_slot(dir, id, true, restore) == SNAP_WRONG);
    id[3]--; id[7]++;
    assert(snap_slot(dir, id, true, restore) == SNAP_EMPTY);
    assert(!unlink(first) && !rmdir(dir));
    puts("Snapshot persistence: round trip, interrupted write, damaged data/identity fallback and foreign save preservation passed.");
}
