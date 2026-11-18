#include "slot.h"
#include <errno.h>
#include <fcntl.h>
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

static snap_result_t slot_directory(const char *base, const uint8_t id[SNAP_ID_BYTES],
                                    unsigned slot_number, bool create, char directory[64])
{
    if (!slot_number || slot_number > SNAP_SLOT_COUNT) return SNAP_INVALID;
    // The flat layout is shared with older firmware. New slots can use every
    // identity byte in their path, including games with the same ROM CRC.
    int n;
    if (slot_number == 1) n = snprintf(directory, 64, "%s", base);
    else {
        char parent[64];
        n = snprintf(parent, sizeof parent, "%s/SLOT%u", base, slot_number);
        if (n < 0 || (size_t)n >= sizeof parent) return SNAP_IO;
        n = snprintf(directory, 64, "%s/%08lX", parent,
                     (unsigned long)read32(id));
        if (n < 0 || n >= 64) return SNAP_IO;
        if (create) {
            if (mkdir(parent, 0777) && errno != EEXIST) return SNAP_IO;
            if (mkdir(directory, 0777) && errno != EEXIST) return SNAP_IO;
        }
    }
    return n < 0 || n >= 64 ? SNAP_IO : SNAP_OK;
}

snap_result_t snap_slot_for_number(const char *base, const uint8_t id[SNAP_ID_BYTES],
                                   unsigned slot_number, bool loading, snap_word_fn transfer)
{
    if (!slot_number || slot_number > SNAP_SLOT_COUNT) return SNAP_INVALID;
    if (!snap_word_count(id)) return SNAP_UNSUPPORTED;
    char directory[64];
    snap_result_t directory_result = slot_directory(base, id, slot_number, !loading, directory);
    if (directory_result != SNAP_OK) return directory_result;
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

static snap_result_t import_file(const char *source, const char *destination,
                                const uint8_t old_id[SNAP_ID_BYTES], const uint8_t new_id[SNAP_ID_BYTES],
                                const slot_record_t *expected)
{
    const char *stage = "source_open";
    errno = 0;
    FILE *input = fopen(source, "rb");
    uint8_t header[HEADER_BYTES], chunk[CHUNK_WORDS * SNAP_WORD_BYTES], tail[4];
    snap_result_t result = SNAP_IO;
    int output = -1, error = 0;
    bool created = false;
    uint32_t new_crc = 0;
    if (!input) goto done;
    result = SNAP_INVALID;
    stage = "source_header";
    if (fread(header, 1, sizeof header, input) != sizeof header ||
        memcmp(header, format, sizeof format) || memcmp(header + 4, old_id, SNAP_ID_BYTES) ||
        read32(header + 12) != expected->generation) goto done;
    uint32_t old_crc = crc_update(UINT32_MAX, header, sizeof header);
    memcpy(header + 4, new_id, SNAP_ID_BYTES);
    new_crc = crc_update(UINT32_MAX, header, sizeof header);
    stage = "target_open";
    output = open(destination, O_CREAT | O_EXCL | O_WRONLY, 0666);
    if (output < 0) { result = errno == EEXIST ? SNAP_BUSY : SNAP_IO; goto done; }
    created = true;
    result = SNAP_IO;
    // FatFs has no fcntl callback. Newlib fdopen performs F_GETFL, so use
    // the exclusive descriptor directly through the supported VFS methods.
    stage = "target_header";
    if (write(output, header, sizeof header) != (ssize_t)sizeof header) goto done;
    size_t remaining = (size_t)snap_word_count(old_id) * SNAP_WORD_BYTES;
    while (remaining) {
        size_t bytes = remaining < sizeof chunk ? remaining : sizeof chunk;
        stage = "source_read";
        if (fread(chunk, 1, bytes, input) != bytes) goto done;
        old_crc = crc_update(old_crc, chunk, bytes);
        new_crc = crc_update(new_crc, chunk, bytes);
        stage = "target_write";
        if (write(output, chunk, bytes) != (ssize_t)bytes) goto done;
        remaining -= bytes;
    }
    stage = "source_crc";
    if (fread(tail, 1, sizeof tail, input) != sizeof tail || read32(tail) != ~old_crc ||
        ~old_crc != expected->crc || fgetc(input) != EOF || ferror(input)) {
        result = SNAP_INVALID;
        goto done;
    }
    put32(tail, ~new_crc);
    stage = "target_tail";
    if (write(output, tail, sizeof tail) != (ssize_t)sizeof tail) goto done;
    stage = "target_sync";
    if (fsync(output)) goto done;
    result = SNAP_OK;
done:
    if (result != SNAP_OK) error = errno;
    if (input) {
        if (ferror(input)) result = SNAP_IO;
        if (fclose(input) && result == SNAP_OK) {
            stage = "source_close"; error = errno; result = SNAP_IO;
        }
    }
    if (output >= 0 && close(output) && result == SNAP_OK) {
        stage = "target_close"; error = errno; result = SNAP_IO;
    }
    if (result == SNAP_OK) {
        slot_record_t verified;
        stage = "target_verify";
        result = read_slot(destination, new_id, &verified, NULL);
        if (result != SNAP_OK) error = errno;
        if (result == SNAP_OK && (verified.generation != expected->generation || verified.crc != ~new_crc))
            result = SNAP_INVALID;
    }
    // The source is always read-only. Clean up only this attempt's failed new file.
    if (result != SNAP_OK && created && unlink(destination)) {
        stage = "target_cleanup"; error = errno; result = SNAP_IO;
    }
    if (result != SNAP_OK)
        printf("SNAPSHOT import path=%s stage=%s errno=%d result=%u\n", destination, stage, error, result);
    return result;
}

static snap_result_t import_slot(const char *base, const uint8_t old_id[SNAP_ID_BYTES],
                                const uint8_t new_id[SNAP_ID_BYTES], unsigned slot_number, unsigned *copied)
{
    char directory[64], sources[2][64], targets[2][64];
    snap_result_t result = slot_directory(base, old_id, slot_number, false, directory);
    if (result != SNAP_OK) return result;
    struct stat metadata;
    for (unsigned i = 0; i < 2; ++i) {
        int source_length = snprintf(sources[i], sizeof sources[i], "%s/%08lX.S%u",
                                     directory, (unsigned long)read32(old_id + 4), i);
        int target_length = snprintf(targets[i], sizeof targets[i], "%s/%08lX.S%u",
                                     directory, (unsigned long)read32(new_id + 4), i);
        if (source_length < 0 || (size_t)source_length >= sizeof sources[i] ||
            target_length < 0 || (size_t)target_length >= sizeof targets[i]) return SNAP_IO;
        if (!stat(targets[i], &metadata)) return SNAP_BUSY;
        if (errno != ENOENT) {
            printf("SNAPSHOT import slot=%u generation=%u stage=target_stat errno=%d\n", slot_number, i, errno);
            return SNAP_IO;
        }
    }
    slot_record_t records[2];
    snap_result_t statuses[2];
    int latest = -1;
    for (unsigned i = 0; i < 2; ++i) {
        statuses[i] = read_slot(sources[i], old_id, &records[i], NULL);
        if (statuses[i] == SNAP_IO || statuses[i] == SNAP_WRONG) {
            printf("SNAPSHOT import slot=%u generation=%u stage=source_validate errno=%d result=%u\n",
                   slot_number, i, errno, statuses[i]);
            return statuses[i];
        }
        if (statuses[i] == SNAP_OK && (latest < 0 ||
            (int32_t)(records[i].generation - records[latest].generation) > 0)) latest = i;
    }
    if (latest < 0)
        return statuses[0] == SNAP_EMPTY && statuses[1] == SNAP_EMPTY ? SNAP_EMPTY : SNAP_INVALID;
    // Publish the newest valid generation first so an interrupted import is useful.
    for (unsigned step = 0; step < 2; ++step) {
        unsigned index = (latest + step) % 2;
        if (statuses[index] != SNAP_OK) continue;
        result = import_file(sources[index], targets[index], old_id, new_id, &records[index]);
        if (result != SNAP_OK) return result;
        ++*copied;
    }
    return SNAP_OK;
}

snap_result_t snap_import_slots(const char *directory, const uint8_t old_id[SNAP_ID_BYTES],
                                const uint8_t new_id[SNAP_ID_BYTES])
{
    if (!old_id || !new_id || !directory || !memcmp(old_id, new_id, SNAP_ID_BYTES)) return SNAP_INVALID;
    if (memcmp(old_id, new_id, 4)) return SNAP_WRONG;
    if (!snap_word_count(old_id) || snap_word_count(old_id) != snap_word_count(new_id)) return SNAP_UNSUPPORTED;
    snap_result_t overall = SNAP_EMPTY;
    for (unsigned slot = 1; slot <= SNAP_SLOT_COUNT; ++slot) {
        unsigned copied = 0;
        snap_result_t result = import_slot(directory, old_id, new_id, slot, &copied);
        printf("{\"snapshot\":\"import\",\"slot\":%u,\"copied\":%u,\"skipped\":%d,\"result\":%u}\n",
               slot, copied, result == SNAP_BUSY, result);
        if (result == SNAP_OK || result == SNAP_BUSY) {
            if (overall == SNAP_EMPTY) overall = SNAP_OK;
        } else if (result != SNAP_EMPTY && (overall == SNAP_EMPTY || overall == SNAP_OK)) overall = result;
    }
    return overall;
}
