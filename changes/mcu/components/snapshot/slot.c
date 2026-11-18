#include "slot.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* A/B generations: an interrupted write leaves the other generation intact.
 * Header = 4-byte format identifier, 8-byte FPGA ROM identity, BE32 generation.
 * Trailer = CRC32 of header + all words, big endian. */
enum { HEADER_BYTES = 16, CHUNK_WORDS = 16 };
typedef struct {
    uint32_t generation;
    uint32_t crc;
} slot_record_t;
// Version 2 requires the physical cartridge timing state at stream word 64.
// Old ROM-only snapshots cannot safely resume that bus from another phase.
static const uint8_t format[4] = {'C','S','S',2};
static bool core_word_valid(uint16_t index, const uint8_t word[SNAP_WORD_BYTES])
{
    // The core only accepts a stream with its 32-bit size marker in word 0.
    if (index == 0)
        return word[0] == 0 && word[1] == 0 && word[2] == 0xb0 && word[3] == 0xca;
    return index != 64 || (word[0] == 0xc5 && word[1] == 0x07);
}

uint16_t snap_word_count(const uint8_t id[SNAP_ID_BYTES])
{
    // Core format includes 512 placeholder bytes even when RAM is absent.
    if (!id[0] && !id[1] && !id[2]) return SNAP_WORDS;
    if (id[0] >= 1 && id[0] <= 3) {
        // Standard MBC1: large-ROM wiring has only one 8 KiB RAM bank.
        if (id[1] > 6) return 0;
        if (id[2] == 0) return SNAP_WORDS;
        if (id[0] != 1) {
            if (id[2] == 2) return 6245 + 8192 / SNAP_WORD_BYTES;
            if (id[2] == 3 && id[1] <= 4) return 6245 + 32768 / SNAP_WORD_BYTES;
        }
        return 0;
    }
    if (id[1] > 8) return 0; // MBC5 has a nine-bit ROM bank register.
    if (id[0] == 0x19 && id[2] == 0) return SNAP_WORDS;
    if (id[0] == 0x1a || id[0] == 0x1b) {
        if (id[2] == 2) return 6245 + 8192 / SNAP_WORD_BYTES;
        if (id[2] == 3) return 6245 + 32768 / SNAP_WORD_BYTES;
    }
    return 0;
}

static uint32_t read32(const uint8_t p[4])
{
    return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3];
}
static void put32(uint8_t p[4], uint32_t n)
{
    p[0] = n>>24; p[1] = n>>16; p[2] = n>>8; p[3] = n;
}
static uint32_t crc_update(uint32_t crc, const uint8_t *p, size_t len)
{
    static const uint32_t nibble[16] = {
        0x00000000, 0x1db71064, 0x3b6e20c8, 0x26d930ac,
        0x76dc4190, 0x6b6b51f4, 0x4db26158, 0x5005713c,
        0xedb88320, 0xf00f9344, 0xd6d6a3e8, 0xcb61b38c,
        0x9b64c2b0, 0x86d3d2d4, 0xa00ae278, 0xbdbdf21c
    };
    while (len--) {
        crc ^= *p++;
        crc = (crc >> 4) ^ nibble[crc & 15];
        crc = (crc >> 4) ^ nibble[crc & 15];
    }
    return crc;
}

static snap_result_t read_slot(const char *path, const uint8_t *id, slot_record_t *record, snap_word_fn stage)
{
    FILE *f = fopen(path, "rb");
    if (!f) return errno == ENOENT ? SNAP_EMPTY : SNAP_IO;
    uint8_t header[HEADER_BYTES], chunk[CHUNK_WORDS * SNAP_WORD_BYTES], tail[4];
    snap_result_t rc = SNAP_INVALID;
    if (fread(header, 1, sizeof header, f) != sizeof header || memcmp(header, format, 4))
        goto done;
    uint16_t words = snap_word_count(header + 4);
    if (!words) goto done;
    bool same_game = memcmp(header + 4, id, SNAP_ID_BYTES) == 0;
    uint32_t crc = crc_update(UINT32_MAX, header, sizeof header);
    for (uint16_t first = 0; first < words; first += CHUNK_WORDS) {
        unsigned count = words - first;
        if (count > CHUNK_WORDS) count = CHUNK_WORDS;
        size_t bytes = count * SNAP_WORD_BYTES;
        if (fread(chunk, 1, bytes, f) != bytes) goto done;
        crc = crc_update(crc, chunk, bytes);
        for (unsigned j = 0; j < count; ++j) {
            uint8_t *word = chunk + j * SNAP_WORD_BYTES;
            if (!core_word_valid(first + j, word)) goto done;
            if (same_game && stage) {
                snap_result_t status = stage(first + j, word);
                if (status != SNAP_OK) { rc = status; goto done; }
            }
        }
    }
    if (fread(tail, 1, sizeof tail, f) == sizeof tail &&
        read32(tail) == ~crc && fgetc(f) == EOF && !ferror(f)) {
        record->generation = read32(header + 12);
        record->crc = ~crc;
        rc = same_game ? SNAP_OK : SNAP_WRONG;
    }
done:
    if (ferror(f)) rc = SNAP_IO;
    if (fclose(f)) rc = SNAP_IO;
    return rc;
}

static snap_result_t write_slot(const char *path, const uint8_t *id, uint32_t generation, snap_word_fn capture,
                                slot_record_t *record)
{
    uint8_t header[HEADER_BYTES], chunk[CHUNK_WORDS * SNAP_WORD_BYTES], tail[4];
    memcpy(header, format, 4);
    memcpy(header + 4, id, SNAP_ID_BYTES);
    put32(header + 12, generation);
    FILE *f = fopen(path, "wb");
    if (!f) return SNAP_IO;
    uint16_t words = snap_word_count(id);
    uint32_t crc = crc_update(UINT32_MAX, header, sizeof header);
    snap_result_t rc = SNAP_IO;
    if (fwrite(header, 1, sizeof header, f) != sizeof header) goto done;
    for (uint16_t first = 0; first < words; first += CHUNK_WORDS) {
        unsigned count = words - first;
        if (count > CHUNK_WORDS) count = CHUNK_WORDS;
        for (unsigned j = 0; j < count; ++j) {
            uint8_t *word = chunk + j * SNAP_WORD_BYTES;
            snap_result_t status = capture(first + j, word);
            if (status != SNAP_OK) { rc = status; goto done; }
            if (!core_word_valid(first + j, word)) { rc = SNAP_HW; goto done; }
        }
        size_t bytes = count * SNAP_WORD_BYTES;
        if (fwrite(chunk, 1, bytes, f) != bytes) goto done;
        crc = crc_update(crc, chunk, bytes);
    }
    put32(tail, ~crc);
    if (fwrite(tail, 1, sizeof tail, f) == sizeof tail && !fflush(f) && !fsync(fileno(f))) {
        record->generation = generation;
        record->crc = ~crc;
        rc = SNAP_OK;
    }
done:
    if (fclose(f)) rc = SNAP_IO;
    return rc;
}

snap_result_t snap_slot_for_number(const char *directory, const uint8_t id[SNAP_ID_BYTES],
                                   unsigned slot_number, bool loading, snap_word_fn transfer)
{
    if (!slot_number || slot_number > SNAP_SLOT_COUNT) return SNAP_INVALID;
    if (!snap_word_count(id)) return SNAP_UNSUPPORTED;
    // The flat layout is shared with older firmware. New slots can use every
    // identity byte in their path, including games with the same ROM CRC.
    char game_directory[64];
    if (slot_number != 1) {
        char slot_directory[64];
        int n = snprintf(slot_directory, sizeof slot_directory, "%s/SLOT%u", directory, slot_number);
        if (n < 0 || (size_t)n >= sizeof slot_directory) return SNAP_IO;
        n = snprintf(game_directory, sizeof game_directory, "%s/%08lX", slot_directory,
                     (unsigned long)read32(id));
        if (n < 0 || (size_t)n >= sizeof game_directory) return SNAP_IO;
        if (!loading) {
            if (mkdir(slot_directory, 0777) && errno != EEXIST) return SNAP_IO;
            if (mkdir(game_directory, 0777) && errno != EEXIST) return SNAP_IO;
        }
        directory = game_directory;
    }
    char paths[2][64];
    slot_record_t records[2];
    snap_result_t status[2];
    int latest = -1;
    for (int i = 0; i < 2; ++i) {
        int len = snprintf(paths[i], sizeof paths[i], "%s/%08lX.S%d", directory,
                           (unsigned long)read32(id + 4), i);
        if (len < 0 || (size_t)len >= sizeof paths[i]) return SNAP_IO;
        status[i] = read_slot(paths[i], id, &records[i], NULL);
        if (status[i] == SNAP_OK && (latest < 0 || (int32_t)(records[i].generation - records[latest].generation) > 0))
            latest = i;
    }
    if (loading && latest >= 0) {
        slot_record_t staged;
        snap_result_t rc = read_slot(paths[latest], id, &staged, transfer);
        if (rc != SNAP_OK) return rc;
        return staged.generation == records[latest].generation && staged.crc == records[latest].crc
               ? SNAP_OK : SNAP_INVALID;
    }

    /* Preserve a foreign save with the same filename and any unreadable file. */
    for (int i = 0; i < 2; ++i) {
        if (status[i] == SNAP_IO || status[i] == SNAP_WRONG) return status[i];
    }
    if (!loading) {
        int dest = latest == 0 ? 1 : 0;
        uint32_t generation = latest < 0 ? 1 : records[latest].generation + 1;
        slot_record_t written, on_card;
        snap_result_t rc = write_slot(paths[dest], id, generation, transfer, &written);
        if (rc != SNAP_OK) return rc;
        // Confirm the closed file can be read back before announcing success.
        rc = read_slot(paths[dest], id, &on_card, NULL);
        return rc == SNAP_OK && on_card.generation == written.generation && on_card.crc == written.crc
               ? SNAP_OK : SNAP_IO;
    }
    return status[0] == SNAP_EMPTY && status[1] == SNAP_EMPTY ? SNAP_EMPTY : SNAP_INVALID;
}

snap_result_t snap_slot(const char *directory, const uint8_t id[SNAP_ID_BYTES], bool loading, snap_word_fn transfer)
{
    return snap_slot_for_number(directory, id, 1, loading, transfer);
}
