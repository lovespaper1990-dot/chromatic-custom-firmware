#include "slot.h"
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* A/B generations: an interrupted write leaves the other generation intact.
 * Header = 4-byte format identifier, 8-byte FPGA ROM identity, BE32 generation.
 * Trailer = CRC32 of header + all words, big endian. */
enum { HEADER_BYTES = 16 };
static const uint8_t format[4] = {'C','S','S',1};

uint16_t snap_word_count(const uint8_t id[SNAP_ID_BYTES])
{
    // Core format includes 512 placeholder bytes even when RAM is absent.
    if (!id[0] && !id[1] && !id[2]) return SNAP_WORDS;
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
    while (len--) {
        crc ^= *p++;
        for (int bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320u : 0);
    }
    return crc;
}

static snap_result_t read_slot(const char *path, const uint8_t *id, uint32_t *generation, snap_word_fn stage)
{
    FILE *f = fopen(path, "rb");
    if (!f) return errno == ENOENT ? SNAP_EMPTY : SNAP_IO;
    uint8_t header[HEADER_BYTES], word[SNAP_WORD_BYTES], tail[4];
    snap_result_t rc = SNAP_INVALID;
    if (fread(header, 1, sizeof header, f) != sizeof header || memcmp(header, format, 4))
        goto done;
    uint16_t words = snap_word_count(header + 4);
    if (!words) goto done;
    bool same_game = memcmp(header + 4, id, SNAP_ID_BYTES) == 0;
    uint32_t crc = crc_update(UINT32_MAX, header, sizeof header);
    for (uint16_t i = 0; i < words; ++i) {
        if (fread(word, 1, sizeof word, f) != sizeof word) goto done;
        crc = crc_update(crc, word, sizeof word);
        if (same_game && stage) {
            snap_result_t status = stage(i, word);
            if (status != SNAP_OK) { rc = status; goto done; }
        }
    }
    if (fread(tail, 1, sizeof tail, f) == sizeof tail &&
        read32(tail) == ~crc && fgetc(f) == EOF && !ferror(f)) {
        *generation = read32(header + 12);
        rc = same_game ? SNAP_OK : SNAP_WRONG;
    }
done:
    if (ferror(f)) rc = SNAP_IO;
    fclose(f);
    return rc;
}

static snap_result_t write_slot(const char *path, const uint8_t *id, uint32_t generation, snap_word_fn capture)
{
    uint8_t header[HEADER_BYTES], word[SNAP_WORD_BYTES], tail[4];
    memcpy(header, format, 4);
    memcpy(header + 4, id, SNAP_ID_BYTES);
    put32(header + 12, generation);
    FILE *f = fopen(path, "wb");
    if (!f) return SNAP_IO;
    uint16_t words = snap_word_count(id);
    uint32_t crc = crc_update(UINT32_MAX, header, sizeof header);
    snap_result_t rc = SNAP_IO;
    if (fwrite(header, 1, sizeof header, f) != sizeof header) goto done;
    for (uint16_t i = 0; i < words; ++i) {
        snap_result_t status = capture(i, word);
        if (status != SNAP_OK) { rc = status; goto done; }
        if (fwrite(word, 1, sizeof word, f) != sizeof word) goto done;
        crc = crc_update(crc, word, sizeof word);
    }
    put32(tail, ~crc);
    if (fwrite(tail, 1, sizeof tail, f) == sizeof tail && !fflush(f) && !fsync(fileno(f)))
        rc = SNAP_OK;
done:
    if (fclose(f)) rc = SNAP_IO;
    return rc;
}

snap_result_t snap_slot(const char *directory, const uint8_t id[SNAP_ID_BYTES], bool loading, snap_word_fn transfer)
{
    if (!snap_word_count(id)) return SNAP_UNSUPPORTED;
    char paths[2][64];
    uint32_t generations[2] = {0};
    snap_result_t status[2];
    int latest = -1;
    for (int i = 0; i < 2; ++i) {
        int len = snprintf(paths[i], sizeof paths[i], "%s/%08lX.S%d", directory,
                           (unsigned long)read32(id + 4), i);
        if (len < 0 || (size_t)len >= sizeof paths[i]) return SNAP_IO;
        status[i] = read_slot(paths[i], id, &generations[i], NULL);
        if (status[i] == SNAP_OK && (latest < 0 || (int32_t)(generations[i] - generations[latest]) > 0))
            latest = i;
    }
    if (loading && latest >= 0)
        return read_slot(paths[latest], id, &generations[latest], transfer);

    /* Preserve a foreign save with the same filename and any unreadable file. */
    for (int i = 0; i < 2; ++i) {
        if (status[i] == SNAP_IO || status[i] == SNAP_WRONG) return status[i];
    }
    if (!loading) {
        int dest = latest == 0 ? 1 : 0;
        return write_slot(paths[dest], id, latest < 0 ? 1 : generations[latest] + 1, transfer);
    }
    return status[0] == SNAP_EMPTY && status[1] == SNAP_EMPTY ? SNAP_EMPTY : SNAP_INVALID;
}
