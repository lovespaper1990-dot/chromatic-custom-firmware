/* cc -std=c11 -Icomponents/snapshot tests/snapshot_slot_test.c components/snapshot/slot.c -o /tmp/slot-test */
#include "slot.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static int pattern, interrupt_at = -1;
static int power_cut_at = -1;
static bool bad_core_header;
static const char *lost_destination;
static unsigned restored;
static uint8_t byte_at(uint16_t i, int j) {
    static const uint8_t core_header[4] = {0, 0, 0xb0, 0xca};
    if (i == 0 && j < 4) return core_header[j];
    if (i == 64 && j < 2) return j ? 0x07 : 0xc5;
    return (uint8_t)(pattern + i * 13 + j);
}
/* Produce a structurally complete file with a fresh CRC, so rejection tests
 * exercise semantic format checks rather than incidental checksum damage. */
static void rewrite_byte_crc(const char *path, size_t offset, uint8_t value) {
    FILE *f = fopen(path, "r+b");
    assert(f && !fseek(f, 0, SEEK_END));
    long size = ftell(f);
    assert(size > 4 && offset < (size_t)size - 4 && !fseek(f, 0, SEEK_SET));
    uint8_t *bytes = malloc((size_t)size);
    assert(bytes && fread(bytes, 1, (size_t)size, f) == (size_t)size);
    bytes[offset] = value;
    uint32_t crc = UINT32_MAX;
    for (long i = 0; i < size - 4; ++i) {
        crc ^= bytes[i];
        for (int bit = 0; bit < 8; ++bit) crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320u : 0);
    }
    crc = ~crc;
    for (int i = 0; i < 4; ++i) bytes[size - 4 + i] = crc >> (24 - 8 * i);
    assert(!fseek(f, 0, SEEK_SET) && fwrite(bytes, 1, (size_t)size, f) == (size_t)size);
    assert(!fclose(f));
    free(bytes);
}
static snap_result_t capture(uint16_t i, uint8_t word[8]) {
    if (i == power_cut_at) _exit(19); // No stdio flush or firmware cleanup.
    if (i == interrupt_at) return SNAP_LINK;
    // Keep the descriptor writable, but make readback at the destination fail.
    if (i == 32 && lost_destination) assert(!unlink(lost_destination));
    for (int j=0; j<8; ++j) word[j] = byte_at(i, j);
    if (i == 0 && bad_core_header) word[2] = 0;
    return SNAP_OK;
}
static snap_result_t restore(uint16_t i, uint8_t word[8]) {
    assert(i == restored++);
    for (int j=0; j<8; ++j) assert(word[j] == byte_at(i, j));
    return SNAP_OK;
}
static void mbc1_geometry(void) {
    static const struct { uint8_t mapper, rom, ram; uint16_t words; } cases[] = {
        {1,0,0,6309}, {1,6,0,6309}, {2,3,0,6309}, {3,6,0,6309},
        {2,0,2,7269}, {3,6,2,7269}, {2,4,3,10341}, {3,4,3,10341},
        {1,4,2,0}, {1,4,3,0}, {2,5,3,0}, {3,6,3,0},
        {1,7,0,0}, {2,7,2,0}, {3,8,3,0},
        {2,2,1,0}, {3,4,1,0}, {3,4,4,0}, {3,4,5,0}
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; ++i) {
        uint8_t id[8] = {cases[i].mapper,cases[i].rom,cases[i].ram};
        assert(snap_word_count(id) == cases[i].words);
    }

    // No battery or cartridge save feature is required for a core snapshot.
    static const uint8_t geometries[][3] = {
        {1,6,0}, {2,3,0}, {3,3,0}, {2,6,2}, {3,4,3}
    };
    for (size_t i = 0; i < sizeof geometries / sizeof *geometries; ++i) {
        char temp[] = "/tmp/chromatic-mbc1-slot-XXXXXX";
        char *dir = mkdtemp(temp);
        uint8_t id[8] = {0,0,0,0x5a,0x90,0,0,(uint8_t)(i+1)};
        memcpy(id, geometries[i], 3);
        assert(dir);
        pattern = 17 + (int)i;
        restored = 0;
        assert(snap_slot(dir, id, false, capture) == SNAP_OK);
        assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == snap_word_count(id));
        char file[64];
        snprintf(file, sizeof file, "%s/900000%02X.S0", dir, (unsigned)i+1);
        FILE *f = fopen(file, "rb");
        assert(f && !fseek(f, 0, SEEK_END));
        assert(ftell(f) == 16 + (long)snap_word_count(id)*8 + 4 && !fclose(f));
        assert(!unlink(file) && !rmdir(dir));
    }
}

static void expect_numbered_load(const char *dir, const uint8_t id[8], unsigned slot, int expected) {
    pattern = expected;
    restored = 0;
    assert(snap_slot_for_number(dir, id, slot, true, restore) == SNAP_OK);
    assert(restored == snap_word_count(id));
}

static void numbered_slots(void) {
    char root[] = "/tmp/chrom-slots-XXXXXX";
    assert(mkdtemp(root));
    const uint8_t games[][8] = {
        {0,0,0,0x5a,1,2,3,4}, {0,0,0,0x5a,1,2,3,5}
    };
    const uint8_t collision[8] = {1,1,0,0x88,1,2,3,4};
    const unsigned invalid[] = {0, SNAP_SLOT_COUNT + 1, UINT32_MAX};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; ++i) {
        assert(snap_slot_for_number(root, games[0], invalid[i], false, NULL) == SNAP_INVALID);
        assert(snap_slot_for_number(root, games[0], invalid[i], true, NULL) == SNAP_INVALID);
    }
    for (unsigned slot = 1; slot <= SNAP_SLOT_COUNT; ++slot)
        assert(snap_slot_for_number(root, games[0], slot, true, NULL) == SNAP_EMPTY);
    // An empty read or an invalid request must not create any on-card paths.
    assert(!rmdir(root) && !mkdir(root, 0700));
    for (unsigned game = 0; game < 2; ++game) {
        for (unsigned slot = 1; slot <= SNAP_SLOT_COUNT; ++slot) {
            pattern = 10 * game + slot;
            if (slot == 1) assert(snap_slot(root, games[game], false, capture) == SNAP_OK);
            else assert(snap_slot_for_number(root, games[game], slot, false, capture) == SNAP_OK);
        }
    }
    // Overwriting slot 2 survives an interrupted subsequent overwrite.
    pattern = 54;
    assert(snap_slot_for_number(root, games[0], 2, false, capture) == SNAP_OK);
    interrupt_at = 631;
    pattern = 12;
    assert(snap_slot_for_number(root, games[0], 2, false, capture) == SNAP_LINK);
    interrupt_at = -1;
    // Keep the full length but damage the CRC of the latest slot 3.
    assert(snap_slot_for_number(root, games[0], 3, false, capture) == SNAP_OK);
    char path[96];
    snprintf(path, sizeof path, "%s/SLOT3/0000005A/01020304.S1", root);
    FILE *file = fopen(path, "r+b");
    assert(file && !fseek(file, -1, SEEK_END));
    int last = fgetc(file);
    assert(last != EOF && !fseek(file, -1, SEEK_END));
    assert(fputc(last ^ 1, file) != EOF && !fclose(file));
    pattern = 75;
    assert(snap_slot_for_number(root, collision, 2, false, capture) == SNAP_OK);
    expect_numbered_load(root, collision, 2, 75);
    assert(snap_slot_for_number(root, collision, 3, true, NULL) == SNAP_EMPTY);
    for (unsigned game = 0; game < 2; ++game) {
        for (unsigned slot = 1; slot <= SNAP_SLOT_COUNT; ++slot) {
            int expected = game == 0 && slot == 2 ? 54 : 10 * game + slot;
            expect_numbered_load(root, games[game], slot, expected);
        }
    }
    snprintf(path, sizeof path, "%s/SLOT3/0000005A/01020304.S0", root);
    assert(!truncate(path, 100));
    assert(snap_slot_for_number(root, games[0], 3, true, NULL) == SNAP_INVALID);
    expect_numbered_load(root, games[0], 2, 54);
    expect_numbered_load(root, games[1], 3, 13);
    pattern = 96;
    assert(snap_slot_for_number(root, games[0], 1, false, capture) == SNAP_OK);
    restored = 0;
    assert(snap_slot(root, games[0], true, restore) == SNAP_OK && restored == SNAP_WORDS);

    snprintf(path, sizeof path, "%s/SLOT2/01010088/01020304.S0", root);
    assert(!unlink(path));
    snprintf(path, sizeof path, "%s/SLOT2/01010088", root);
    assert(!rmdir(path));
    for (unsigned slot = 1; slot <= SNAP_SLOT_COUNT; ++slot) {
        char directory[64];
        if (slot == 1) snprintf(directory, sizeof directory, "%s", root);
        else snprintf(directory, sizeof directory, "%s/SLOT%u/0000005A", root, slot);
        for (int game = 0; game < 2; ++game) {
            for (int generation = 0; generation < 2; ++generation) {
                snprintf(path, sizeof path, "%s/0102030%d.S%d", directory, 4 + game, generation);
                assert(!unlink(path) || errno == ENOENT);
            }
        }
        if (slot > 1) {
            assert(!rmdir(directory));
            snprintf(path, sizeof path, "%s/SLOT%u", root, slot);
            assert(!rmdir(path));
        }
    }
    assert(!rmdir(root));
    puts("PASS three independent per-game slots, legacy slot 1, invalid and empty requests, interrupted overwrite, isolated fallback, full ID collision.");
}

int main(void) {
    mbc1_geometry();
    numbered_slots();
    char temp[] = "/tmp/chromatic-slot-XXXXXX";
    char *dir = mkdtemp(temp);
    uint8_t id[8] = {0,0,0,0x88,1,2,3,4};
    assert(dir);
    assert(snap_slot(dir, id, true, restore) == SNAP_EMPTY);
    pattern = 73;
    assert(snap_slot(dir, id, false, capture) == SNAP_OK);
    const int interrupted[] = {0, 15, 16, 64, 213, SNAP_WORDS-1};
    for (size_t i = 0; i < sizeof interrupted / sizeof *interrupted; ++i) {
        pattern = 92; interrupt_at = interrupted[i];
        assert(snap_slot(dir, id, false, capture) == SNAP_LINK);
        pattern = 73; restored = 0;
        assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    }
    interrupt_at = -1;
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        pattern = 92;
        power_cut_at = SNAP_WORDS / 2;
        snap_slot(dir, id, false, capture);
        _exit(1);
    }
    int exit_status;
    assert(waitpid(child, &exit_status, 0) == child);
    assert(WIFEXITED(exit_status) && WEXITSTATUS(exit_status) == 19);
    pattern = 73; restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    pattern = 31; interrupt_at = -1;
    assert(snap_slot(dir, id, false, capture) == SNAP_OK);
    restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    char second[64], first[64];
    snprintf(second, sizeof second, "%s/01020304.S1", dir);
    snprintf(first, sizeof first, "%s/01020304.S0", dir);
    // FAT may expose all payload bytes and a torn checksum trailer after a power loss.
    for (int missing = 1; missing <= 4; ++missing) {
        assert(!truncate(second, 16 + SNAP_WORDS * SNAP_WORD_BYTES + 4 - missing));
        pattern = 73; restored = 0;
        assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
        pattern = 31;
        assert(snap_slot(dir, id, false, capture) == SNAP_OK);
    }
    // An older restorable generation survives a CRC-valid but unusable latest image.
    rewrite_byte_crc(second, 16 + 3, 0);
    pattern = 73; restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    bad_core_header = true;
    assert(snap_slot(dir, id, false, capture) == SNAP_HW);
    bad_core_header = false;
    restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    lost_destination = second;
    assert(snap_slot(dir, id, false, capture) == SNAP_IO);
    lost_destination = NULL;
    restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == SNAP_WORDS);
    pattern = 31;
    assert(snap_slot(dir, id, false, capture) == SNAP_OK);
    FILE *f = fopen(second, "r+b");
    assert(f && fseek(f, 16 + 6, SEEK_SET) == 0 && fputc(0, f) == 0 && fclose(f) == 0);
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
    other_id[0] = 0x1b; other_id[1] = 3; other_id[2] = 3;
    assert(snap_word_count(other_id) == 10341);
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
    assert(snap_slot(dir, other_id, true, restore) == SNAP_OK && restored == 10341);
    assert(unlink(second) == 0);
    id[3]++;
    assert(snap_slot(dir, id, true, restore) == SNAP_WRONG);
    id[3]--; id[7]++;
    assert(snap_slot(dir, id, true, restore) == SNAP_EMPTY);
    assert(!unlink(first));
    id[0] = 0x1a; id[1] = 5; id[2] = 2;
    assert(snap_word_count(id) == 7269);
    assert(snap_slot(dir, id, false, capture) == SNAP_OK);
    restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_OK && restored == 7269);
    snprintf(first, sizeof first, "%s/01020305.S0", dir);
    rewrite_byte_crc(first, 16 + 64 * 8, 0); // Valid CRC, missing cart timing.
    restored = 0;
    assert(snap_slot(dir, id, true, restore) == SNAP_INVALID && !restored);
    rewrite_byte_crc(first, 16 + 64 * 8, 0xc5);
    rewrite_byte_crc(first, 3, 1); // Legacy CSS1 is explicitly rejected.
    assert(snap_slot(dir, id, true, restore) == SNAP_INVALID && !restored);
    id[0] = 0x10;
    assert(snap_slot(dir, id, false, capture) == SNAP_UNSUPPORTED);
    snprintf(first, sizeof first, "%s/01020305.S0", dir);
    assert(!unlink(first) && !rmdir(dir));
    puts("Snapshot persistence: round trip, interrupted writes, abrupt process exit, torn trailers, post-close readback failure, corrupt core header/data/identity fallback, foreign save preservation, legacy format and missing cart timing rejection passed.");
}
