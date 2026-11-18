#include "snapshot.h"
#include "slot.h"
#include "crc8_sae_j1850.h"
#include "driver/uart.h"
#include "driver/gpio.h"
#include "driver/sdmmc_host.h"
#include "esp_err.h"
#include "esp_attr.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "sdmmc_cmd.h"
#include <errno.h>
#include <dirent.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

enum { RX_BYTES = 10, CONTROL = 0x20, READ_WORD = 0x21, WRITE_WORD = 0x22,
       PREPARE_BLOCK = 0x23, COMMIT_BLOCK = 0x24, BLOCK_WORDS = 128 };
enum { STATUS, CAPTURE, RESTORE, IDENTITY, DIAGNOSTICS, CAPABILITY };
static QueueHandle_t replies;
enum { MSG_SAVING = SNAP_HW + 1, MSG_LOADING, MSG_SAVED, MSG_RESTORED, MSG_NO_SD, MSG_LISTING, MSG_IMPORTING, MSG_COUNT };
static const char *const messages[MSG_COUNT] = {
    [SNAP_OK] = "A: Save\nB: Load", [SNAP_EMPTY] = "No snapshot", [SNAP_INVALID] = "Bad file",
    [SNAP_IO] = "Card error", [SNAP_LINK] = "FPGA timeout", [SNAP_UNSUPPORTED] = "Unsupported",
    [SNAP_WRONG] = "Wrong game", [SNAP_BUSY] = "Busy", [SNAP_HW] = "FPGA error",
    [MSG_SAVING] = "Saving...", [MSG_LOADING] = "Loading...", [MSG_SAVED] = "Saved",
    [MSG_RESTORED] = "Restored", [MSG_NO_SD] = "No SD card", [MSG_LISTING] = "Busy", [MSG_IMPORTING] = "Busy"
};
// Publish the busy flag, target slot and message in a single state change.
// Zero initializes to the help text for slot 1.
static atomic_uint operation;
static unsigned operation_state(unsigned slot_number, unsigned message)
{
    return (slot_number - 1) * MSG_COUNT + message;
}
static unsigned operation_slot(unsigned state)
{
    return state / MSG_COUNT + 1;
}
static bool operation_busy(unsigned state)
{
    unsigned message = state % MSG_COUNT;
    return message == MSG_SAVING || message == MSG_LOADING || message == MSG_LISTING || message == MSG_IMPORTING;
}
static atomic_uint transferred;
static atomic_uint word_count = SNAP_WORDS;
static _Atomic(const char *) phase = "idle";
_Static_assert(sizeof(TickType_t) == sizeof(uint32_t), "Snapshot timing requires 32-bit RTOS ticks");
static _Atomic(TickType_t) started_tick, phase_started_tick;
static atomic_uint elapsed_ms, phase_elapsed_ms;
static atomic_uint fpga_result;
static atomic_uint sd_mount_error = ESP_ERR_INVALID_STATE;
static atomic_uint sd_last_command, sd_last_error;
static atomic_bool sd_responded;
static esp_err_t (*sd_native_transaction)(int slot, sdmmc_command_t *command);
static SnapshotSPITransfer spi_transfer;
// The extra four bytes cover the CRC16 and DMA alignment padding. The driver
// may bounce a non-word-sized transaction; it must never overrun this buffer.
static DMA_ATTR uint8_t block_packet[BLOCK_WORDS * SNAP_WORD_BYTES + 4];
static bool block_transport, block_cached;
static uint16_t block_first, block_count, block_filled;
static uint8_t import_source[SNAP_ID_BYTES];

void Snapshot_AttachSPI(SnapshotSPITransfer transfer)
{
    spi_transfer = transfer;
}

static uint32_t ticks_elapsed_ms(TickType_t now, TickType_t start)
{
    // Unsigned subtraction also handles one tick-counter wrap during an operation.
    return (uint32_t)(TickType_t)(now - start) * (uint32_t)portTICK_PERIOD_MS;
}
uint32_t Snapshot_ElapsedMs(void)
{
    return Snapshot_Busy() ? ticks_elapsed_ms(xTaskGetTickCount(), atomic_load(&started_tick))
                           : atomic_load(&elapsed_ms);
}
uint32_t Snapshot_PhaseElapsedMs(void)
{
    return Snapshot_Busy() ? ticks_elapsed_ms(xTaskGetTickCount(), atomic_load(&phase_started_tick))
                           : atomic_load(&phase_elapsed_ms);
}
static void finish_phase(TickType_t now)
{
    uint32_t duration = ticks_elapsed_ms(now, atomic_load(&phase_started_tick));
    atomic_store(&phase_elapsed_ms, duration);
    printf("SNAPSHOT timing phase=%s elapsed_ms=%u words=%u\n",
           atomic_load(&phase), (unsigned)duration, atomic_load(&transferred));
}
static void start_phase(const char *next)
{
    TickType_t now = xTaskGetTickCount();
    finish_phase(now);
    atomic_store(&phase, next);
    atomic_store(&phase_started_tick, now);
    atomic_store(&phase_elapsed_ms, 0);
}

static esp_err_t sd_transaction(int slot, sdmmc_command_t *command)
{
    atomic_store(&sd_last_command, command->opcode);
    esp_err_t error = sd_native_transaction(slot, command);
    esp_err_t effective = error == ESP_OK ? command->error : error;
    atomic_store(&sd_last_error, effective);
    if (effective == ESP_OK && (command->flags & SCF_RSP_PRESENT))
        atomic_store(&sd_responded, true);
    return error;
}

void Snapshot_PrintDiagnostics(void)
{
    unsigned state = atomic_load(&operation);
    const char *status = messages[state % MSG_COUNT];
    if (strchr(status, '\n')) status = "Idle";
    printf("{\"snapshot\":\"%s\",\"slot\":%u,\"busy\":%d,\"progress\":%u,\"words\":%u,\"total\":%u,\"phase\":\"%s\",\"elapsed_ms\":%u,\"phase_elapsed_ms\":%u,\"fpga_result\":%u,"
           "\"sd_mount\":\"%s\",\"sd_command\":%u,\"sd_error\":\"%s\",\"sd_responded\":%d}\n",
           status, operation_slot(state), operation_busy(state), Snapshot_Percent(), atomic_load(&transferred),
           atomic_load(&word_count), atomic_load(&phase),
           (unsigned)Snapshot_ElapsedMs(), (unsigned)Snapshot_PhaseElapsedMs(), atomic_load(&fpga_result),
           esp_err_to_name(atomic_load(&sd_mount_error)), atomic_load(&sd_last_command),
           esp_err_to_name(atomic_load(&sd_last_error)), atomic_load(&sd_responded));
}

void Snapshot_Init(void)
{
    replies = xQueueCreate(2, RX_BYTES);
}
void Snapshot_OnReply(const uint8_t payload[10])
{
    if (replies && Snapshot_Busy()) xQueueSend(replies, payload, 0);
}
bool Snapshot_Busy(void)
{
    return operation_busy(atomic_load(&operation));
}
unsigned Snapshot_Percent(void)
{
    return 100 * atomic_load(&transferred) / atomic_load(&word_count);
}
const char *Snapshot_Status(void)
{
    return messages[atomic_load(&operation) % MSG_COUNT];
}
unsigned Snapshot_OperationSlot(void)
{
    return operation_slot(atomic_load(&operation));
}
const char *Snapshot_StatusForSlot(unsigned slot_number)
{
    unsigned state = atomic_load(&operation);
    return messages[operation_slot(state) == slot_number ? state % MSG_COUNT : SNAP_OK];
}

/* The stock UART parser validates the CRC before putting a response in replies.
 * Match the opcode/word index so unrelated or late traffic cannot advance a transfer. */
static snap_result_t hardware_error(uint8_t result)
{
    switch (result) {
    case 2: return SNAP_UNSUPPORTED;
    case 4: return SNAP_INVALID;
    case 5: return SNAP_BUSY;
    default: return SNAP_HW;
    }
}

static snap_result_t exchange(uint8_t address, const uint8_t *data, size_t len,
                              const uint8_t *prefix, size_t prefix_len, uint8_t reply[RX_BYTES])
{
    uint8_t packet[14] = {0x8f, address, (uint8_t)len};
    memcpy(packet + 3, data, len);
    size_t bytes = crc8_sae_j1850_encode(packet, len + 3, packet);
    xQueueReset(replies);
    if (uart_write_bytes(UART_NUM_1, packet, bytes) != (int)bytes) return SNAP_LINK;
    TickType_t start = xTaskGetTickCount(), budget = pdMS_TO_TICKS(750);
    while (xTaskGetTickCount() - start < budget) {
        TickType_t elapsed = xTaskGetTickCount() - start;
        if (elapsed >= budget || xQueueReceive(replies, reply, budget - elapsed) != pdTRUE) break;
        if (!memcmp(reply, prefix, prefix_len)) return SNAP_OK;
        uint8_t operation = address == CONTROL ? data[0] : address;
        if (reply[0] == 0xff && reply[1] == 0xf0 && reply[2] == operation && reply[3] >= 2) {
            atomic_store(&fpga_result, reply[3]);
            printf("SNAPSHOT reply command=%02x operation=%u result=%u\n", address, operation, reply[3]);
            return hardware_error(reply[3]);
        }
    }
    return SNAP_LINK;
}

static uint16_t block_words(uint16_t first)
{
    unsigned words = atomic_load(&word_count);
    if (first >= words || first % BLOCK_WORDS) return 0;
    unsigned remaining = words - first;
    return remaining < BLOCK_WORDS ? remaining : BLOCK_WORDS;
}
static uint16_t block_crc16(const uint8_t *bytes, size_t length)
{
    // Four MSB-first CCITT steps per lookup, using 32 bytes of read-only data.
    static const uint16_t nibble[16] = {
        0x0000, 0x1021, 0x2042, 0x3063, 0x4084, 0x50a5, 0x60c6, 0x70e7,
        0x8108, 0x9129, 0xa14a, 0xb16b, 0xc18c, 0xd1ad, 0xe1ce, 0xf1ef
    };
    uint16_t crc = 0xffff;
    while (length--) {
        crc ^= (uint16_t)*bytes++ << 8;
        crc = (uint16_t)(crc << 4) ^ nibble[crc >> 12];
        crc = (uint16_t)(crc << 4) ^ nibble[crc >> 12];
    }
    return crc;
}
static snap_result_t block_control(uint8_t command, bool write, uint16_t first)
{
    uint8_t data[4] = {write, first >> 8, first, 0};
    uint8_t prefix[3] = {0xff, 0xf0, command}, reply[RX_BYTES];
    snap_result_t rc = exchange(command, data, sizeof data, prefix, sizeof prefix, reply);
    if (rc != SNAP_OK) return rc;
    atomic_store(&fpga_result, reply[3]);
    if (reply[3])
        printf("SNAPSHOT block command=%02x index=%u result=%u\n", command, first, reply[3]);
    return reply[3] == 0 ? SNAP_OK : reply[3] == 1 ? SNAP_BUSY : hardware_error(reply[3]);
}
static snap_result_t select_transport(void)
{
    static const uint8_t capability[RX_BYTES] = {0xff,0xf3,0x42,0x4c,0x4b,0x31,0,0,0,0};
    const uint8_t op = CAPABILITY;
    uint8_t reply[RX_BYTES] = {0};
    block_transport = false;
    block_cached = false;
    block_filled = 0;
    snap_result_t rc = exchange(CONTROL, &op, 1, capability, sizeof capability, reply);
    // Only an explicit legacy "unknown op5" response admits the original
    // transport. A lost reply or a failed block must never silently downgrade.
    if (rc == SNAP_HW && reply[0] == 0xff && reply[1] == 0xf0 &&
        reply[2] == CAPABILITY && reply[3] == 3) {
        atomic_store(&fpga_result, 0);
        printf("SNAPSHOT transport=uart-word\n");
        return SNAP_OK;
    }
    if (rc != SNAP_OK) return rc;
    if (!spi_transfer) return SNAP_LINK;
    block_transport = true;
    printf("SNAPSHOT transport=spi-block words=%u\n", BLOCK_WORDS);
    return SNAP_OK;
}
static snap_result_t fetch_block(uint16_t first)
{
    uint16_t count = block_words(first);
    if (!count) return SNAP_INVALID;
    block_cached = false;
    snap_result_t rc = block_control(PREPARE_BLOCK, false, first);
    if (rc != SNAP_OK) return rc;
    size_t bytes = count * SNAP_WORD_BYTES;
    // The prepared buffer is read-only until the next mailbox command.
    // A fresh CS frame can safely read it again after a failed transfer.
    for (unsigned attempt = 0; attempt < 2; ++attempt) {
        if (spi_transfer(true, block_packet, bytes + 2)) {
            uint16_t received_crc = (uint16_t)block_packet[bytes] << 8 | block_packet[bytes + 1];
            if (received_crc == block_crc16(block_packet, bytes)) {
                block_first = first;
                block_count = count;
                block_cached = true;
                return SNAP_OK;
            }
        }
        printf("SNAPSHOT block read failed index=%u attempt=%u\n", first, attempt + 1);
    }
    return SNAP_LINK;
}

static snap_result_t identity(uint8_t id[SNAP_ID_BYTES])
{
    const uint8_t op = IDENTITY, prefix[] = {0xff, 0xf1};
    uint8_t reply[RX_BYTES];
    snap_result_t rc = exchange(CONTROL, &op, 1, prefix, sizeof prefix, reply);
    if (rc != SNAP_OK) return rc;
    memcpy(id, reply + 2, SNAP_ID_BYTES);
    printf("SNAPSHOT identity=%02x%02x%02x%02x%02x%02x%02x%02x\n",
           id[0],id[1],id[2],id[3],id[4],id[5],id[6],id[7]);
    return snap_word_count(id) ? SNAP_OK : SNAP_UNSUPPORTED;
}
static void print_capture_diagnostics(void)
{
    const uint8_t op = DIAGNOSTICS, prefix[] = {0xff, 0xf2};
    uint8_t reply[RX_BYTES];
    snap_result_t rc = exchange(CONTROL, &op, 1, prefix, sizeof prefix, reply);
    if (rc != SNAP_OK) {
        printf("SNAPSHOT diagnostic query result=%u\n", rc);
        return;
    }
    uint64_t bits = 0;
    for (unsigned i = 2; i < RX_BYTES; ++i) bits = (bits << 8) | reply[i];
    if (!bits) {
        printf("SNAPSHOT diagnostic storage disabled in FPGA build\n");
        return;
    }
    printf("SNAPSHOT diagnostic flags=%04x seen=%04x index=%u operation=%u owner=%u "
           "busy_seen=%u busy=%u pending=%u header=%u req_seen=%u req=%u read=%u loaded=%u toggle=%u ack=%u\n",
           (unsigned)(bits >> 48), (unsigned)((bits >> 32) & 0xffff),
           (unsigned)((bits >> 18) & 0x3fff), (unsigned)((bits >> 16) & 3),
           (unsigned)((bits >> 13) & 7), (unsigned)((bits >> 12) & 1),
           (unsigned)((bits >> 11) & 1), (unsigned)((bits >> 10) & 1),
           (unsigned)((bits >> 9) & 1), (unsigned)((bits >> 8) & 1),
           (unsigned)((bits >> 7) & 1), (unsigned)((bits >> 6) & 1),
           (unsigned)((bits >> 5) & 1), (unsigned)((bits >> 4) & 1),
           (unsigned)((bits >> 3) & 1));
}
static snap_result_t command_wait(uint8_t op)
{
    TickType_t start = xTaskGetTickCount();
    bool retried_poll = false;
    do {
        uint8_t prefix[] = {0xff, 0xf0, op}, reply[RX_BYTES];
        snap_result_t rc = exchange(CONTROL, &op, 1, prefix, sizeof prefix, reply);
        if (rc != SNAP_OK) {
            printf("SNAPSHOT control op=%u link_result=%u\n",op,rc);
            // Once the state-changing command was acknowledged, a lost
            // status reply can be polled again within the same deadline.
            if (op == STATUS && rc == SNAP_LINK && !retried_poll) {
                retried_poll = true;
                vTaskDelay(pdMS_TO_TICKS(20));
                continue;
            }
            return rc;
        }
        retried_poll = false;
        atomic_store(&fpga_result, reply[3]);
        if (reply[3] != 1) {
            printf("SNAPSHOT control op=%u result=%u elapsed_ms=%u\n",op,reply[3],
                   (unsigned)ticks_elapsed_ms(xTaskGetTickCount(), start));
            if (reply[3] == 3) print_capture_diagnostics();
            return reply[3] == 0 ? SNAP_OK : hardware_error(reply[3]);
        }
        op = STATUS;
        vTaskDelay(pdMS_TO_TICKS(20));
    } while (xTaskGetTickCount() - start < pdMS_TO_TICKS(5000));
    return SNAP_LINK;
}

static snap_result_t fetch_word(uint16_t index, uint8_t *word)
{
    if (block_transport) {
        uint16_t first = index / BLOCK_WORDS * BLOCK_WORDS;
        if (index >= atomic_load(&word_count)) return SNAP_INVALID;
        if (!block_cached || block_first != first) {
            snap_result_t rc = fetch_block(first);
            if (rc != SNAP_OK) return rc;
        }
        memcpy(word, block_packet + (index - first) * SNAP_WORD_BYTES, SNAP_WORD_BYTES);
        atomic_store(&transferred, index + 1u);
        return SNAP_OK;
    }
    uint8_t address[2] = {index >> 8, index}, reply[RX_BYTES];
    snap_result_t rc = exchange(READ_WORD, address, 2, address, 2, reply);
    if (rc != SNAP_OK) printf("SNAPSHOT fetch index=%u result=%u\n",index,rc);
    if (rc == SNAP_OK) {
        memcpy(word, reply + 2, SNAP_WORD_BYTES);
        atomic_store(&transferred, index + 1u);
    }
    return rc;
}
static snap_result_t stage_word(uint16_t index, uint8_t *word)
{
    if (block_transport) {
        if (!block_cached) {
            block_count = block_words(index);
            if (!block_count) return SNAP_INVALID;
            block_first = index;
            block_filled = 0;
            block_cached = true;
        }
        if (index != block_first + block_filled) return SNAP_INVALID;
        memcpy(block_packet + block_filled * SNAP_WORD_BYTES, word, SNAP_WORD_BYTES);
        if (++block_filled == block_count) {
            block_cached = false;
            snap_result_t rc = block_control(PREPARE_BLOCK, true, block_first);
            if (rc != SNAP_OK) return rc;
            size_t bytes = block_count * SNAP_WORD_BYTES;
            uint16_t crc = block_crc16(block_packet, bytes);
            block_packet[bytes] = crc >> 8;
            block_packet[bytes + 1] = crc;
            if (!spi_transfer(false, block_packet, bytes + 2)) return SNAP_LINK;
            rc = block_control(COMMIT_BLOCK, true, block_first);
            if (rc != SNAP_OK) return rc;
        }
        atomic_store(&transferred, index + 1u);
        return SNAP_OK;
    }
    uint8_t packet[RX_BYTES] = {index >> 8, index}, reply[RX_BYTES];
    memcpy(packet + 2, word, SNAP_WORD_BYTES);
    snap_result_t rc = exchange(WRITE_WORD, packet, sizeof packet, packet, sizeof packet, reply);
    if (rc == SNAP_OK) atomic_store(&transferred, index + 1u);
    return rc;
}

static snap_result_t check_identity(const uint8_t expected[SNAP_ID_BYTES])
{
    uint8_t current[SNAP_ID_BYTES];
    snap_result_t rc = identity(current);
    if (rc != SNAP_OK) return rc;
    return memcmp(expected, current, sizeof current) == 0 ? SNAP_OK : SNAP_WRONG;
}

static snap_result_t prepare_snapshot(bool load, unsigned slot_number, uint8_t id[SNAP_ID_BYTES])
{
    start_phase("identity");
    snap_result_t rc = identity(id);
    if (rc != SNAP_OK) return rc;
    atomic_store(&word_count, snap_word_count(id));
    start_phase("transport");
    rc = select_transport();
    if (rc != SNAP_OK) return rc;
    const char *dir = "/sd/SNAP";
    if (!load) {
        if (mkdir(dir, 0777) != 0 && errno != EEXIST) return SNAP_IO;
        start_phase("capture");
        rc = command_wait(CAPTURE);
        printf("SNAPSHOT capture result=%u\n",rc);
        if (rc != SNAP_OK) return rc;
        // Cartridge selection can change between the initial probe and capture.
        // Check before opening a destination generation under the original ID.
        start_phase("verify");
        rc = check_identity(id);
        if (rc != SNAP_OK) return rc;
    }
    start_phase(load ? "stage" : "fetch");
    rc = snap_slot_for_number(dir, id, slot_number, load, load ? stage_word : fetch_word);
    printf("SNAPSHOT file result=%u words=%u\n",rc,atomic_load(&transferred));
    return rc;
}

static snap_result_t run(bool load, unsigned slot_number, sdmmc_card_t *card)
{
    uint8_t id[SNAP_ID_BYTES];
    snap_result_t rc = prepare_snapshot(load, slot_number, id);
    start_phase("unmount");
    if (esp_vfs_fat_sdcard_unmount("/sd", card) != ESP_OK && rc == SNAP_OK) rc = SNAP_IO;
    if (rc == SNAP_OK && load) {
        start_phase("verify");
        rc = check_identity(id);
        if (rc != SNAP_OK) return rc;
        start_phase("restore");
        rc = command_wait(RESTORE);
    }
    return rc;
}

typedef struct {
    unsigned entries, files;
    bool limited;
} file_listing_t;

static bool hexadecimal_name(const char *name, size_t length)
{
    if (strlen(name) != length) return false;
    return strspn(name, "0123456789ABCDEFabcdef") == length;
}

static bool snapshot_filename(const char *name)
{
    return strlen(name) == 11 && strspn(name, "0123456789ABCDEFabcdef") == 8 &&
           name[8] == '.' && (name[9] == 'S' || name[9] == 's') &&
           (name[10] == '0' || name[10] == '1');
}

static snap_result_t print_snapshot_file(const char *path, const char *relative)
{
    struct stat metadata;
    if (stat(path, &metadata) || !S_ISREG(metadata.st_mode)) return SNAP_IO;
    FILE *file = fopen(path, "rb");
    if (!file) return SNAP_IO;
    uint8_t header[16] = {0};
    size_t bytes = fread(header, 1, sizeof header, file);
    bool failed = ferror(file);
    if (fclose(file)) failed = true;
    if (failed) return SNAP_IO;
    bool css2 = bytes == sizeof header && memcmp(header, "CSS\2", 4) == 0;
    uint32_t generation = (uint32_t)header[12] << 24 | (uint32_t)header[13] << 16 |
                          (uint32_t)header[14] << 8 | header[15];
    printf("{\"snapshot\":\"file\",\"path\":\"%s\",\"bytes\":%lu,\"css2_header\":%d,"
           "\"identity\":\"%02x%02x%02x%02x%02x%02x%02x%02x\",\"generation\":%lu}\n",
           relative, (unsigned long)metadata.st_size, css2,
           header[4], header[5], header[6], header[7], header[8], header[9], header[10], header[11],
           (unsigned long)generation);
    return SNAP_OK;
}

static snap_result_t list_snapshot_directory(const char *base, const char *relative, file_listing_t *listing)
{
    char path[96];
    int length = snprintf(path, sizeof path, "%s/%s", base, relative);
    if (length < 0 || (size_t)length >= sizeof path) return SNAP_IO;
    DIR *directory = opendir(path);
    if (!directory) return errno == ENOENT ? SNAP_OK : SNAP_IO;
    snap_result_t result = SNAP_OK;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry) { if (errno) result = SNAP_IO; break; }
        if (++listing->entries > 512 || listing->files >= 128) {
            listing->limited = true;
            break;
        }
        if (!snapshot_filename(entry->d_name)) continue;
        char filename[96], display[48];
        int size = snprintf(filename, sizeof filename, "%s/%s", path, entry->d_name);
        int shown = snprintf(display, sizeof display, "%s%s%s", relative,
                             *relative ? "/" : "", entry->d_name);
        if (size < 0 || (size_t)size >= sizeof filename || shown < 0 || (size_t)shown >= sizeof display) {
            result = SNAP_IO;
            break;
        }
        result = print_snapshot_file(filename, display);
        if (result != SNAP_OK) break;
        ++listing->files;
    }
    if (closedir(directory)) result = SNAP_IO;
    return result;
}

static snap_result_t list_snapshot_files(const char *base)
{
    file_listing_t listing = {0};
    snap_result_t result = list_snapshot_directory(base, "", &listing);
    for (unsigned slot = 2; slot <= SNAP_SLOT_COUNT && result == SNAP_OK && !listing.limited; ++slot) {
        char path[96], relative[24], games[32][9];
        unsigned count = 0;
        int length = snprintf(path, sizeof path, "%s/SLOT%u", base, slot);
        if (length < 0 || (size_t)length >= sizeof path) { result = SNAP_IO; break; }
        DIR *directory = opendir(path);
        if (!directory) {
            if (errno != ENOENT) result = SNAP_IO;
            continue;
        }
        for (;;) {
            errno = 0;
            struct dirent *entry = readdir(directory);
            if (!entry) { if (errno) result = SNAP_IO; break; }
            if (++listing.entries > 512) { listing.limited = true; break; }
            if (!hexadecimal_name(entry->d_name, 8)) continue;
            if (count == 32) { listing.limited = true; break; }
            memcpy(games[count++], entry->d_name, 9);
        }
        if (closedir(directory)) result = SNAP_IO;
        for (unsigned game = 0; game < count && result == SNAP_OK && !listing.limited; ++game) {
            snprintf(relative, sizeof relative, "SLOT%u/%s", slot, games[game]);
            result = list_snapshot_directory(base, relative, &listing);
        }
    }
    printf("{\"snapshot\":\"files\",\"files\":%u,\"entries\":%u,\"limited\":%d,\"result\":%u}\n",
           listing.files, listing.entries, listing.limited, result);
    return result;
}

static void worker(void *arg)
{
    unsigned request = (uintptr_t)arg;
    unsigned slot_number = operation_slot(request);
    bool load = request % MSG_COUNT == MSG_LOADING;
    bool listing = request % MSG_COUNT == MSG_LISTING;
    bool importing = request % MSG_COUNT == MSG_IMPORTING;
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    sd_native_transaction = host.do_transaction;
    host.do_transaction = sd_transaction;
    atomic_store(&sd_responded, false);
    atomic_store(&sd_last_command, 0);
    atomic_store(&sd_last_error, ESP_OK);
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 1;
    slot.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;
    // ESP32 slot 1 uses DAT3=GPIO13. In 1-bit mode IDF pulls up only
    // CMD/DAT0; DAT3 must also stay high during CMD0 to select native SD.
    gpio_pullup_en(GPIO_NUM_13);
    esp_vfs_fat_sdmmc_mount_config_t options = {.format_if_mount_failed = false, .max_files = 2};
    sdmmc_card_t *card = NULL;
    esp_err_t mount = esp_vfs_fat_sdmmc_mount("/sd", &host, &slot, &options, &card);
    atomic_store(&sd_mount_error, mount);
    printf("SNAPSHOT SD mount=%s command=%u error=%s responded=%d\n",
           esp_err_to_name(mount), atomic_load(&sd_last_command),
           esp_err_to_name(atomic_load(&sd_last_error)), atomic_load(&sd_responded));
    unsigned result;
    if (mount != ESP_OK) {
        bool no_response = !atomic_load(&sd_responded);
        result = no_response && (mount == ESP_ERR_TIMEOUT || mount == ESP_ERR_NOT_FOUND) ? MSG_NO_SD : SNAP_IO;
        finish_phase(xTaskGetTickCount());
    } else {
        snap_result_t rc;
        if (listing || importing) {
            if (importing) {
                uint8_t current[SNAP_ID_BYTES];
                start_phase("identity");
                rc = identity(current);
                if (rc == SNAP_OK) {
                    start_phase("import");
                    rc = snap_import_slots("/sd/SNAP", import_source, current);
                }
            } else {
                start_phase("files");
                rc = list_snapshot_files("/sd/SNAP");
            }
            start_phase("unmount");
            if (esp_vfs_fat_sdcard_unmount("/sd", card) != ESP_OK && rc == SNAP_OK) rc = SNAP_IO;
        } else rc = run(load, slot_number, card);
        finish_phase(xTaskGetTickCount());
        result = rc == SNAP_OK ? (listing || importing ? SNAP_OK : load ? MSG_RESTORED : MSG_SAVED) : rc;
    }
    atomic_store(&elapsed_ms, ticks_elapsed_ms(xTaskGetTickCount(), atomic_load(&started_tick)));
    atomic_store(&operation, operation_state(slot_number, result));
    Snapshot_PrintDiagnostics();
    vTaskDelete(NULL);
}
void Snapshot_Start(bool load)
{
    (void)Snapshot_StartSlot(load, 1);
}
static bool start_operation(unsigned request, const uint8_t source_id[SNAP_ID_BYTES])
{
    unsigned slot_number = operation_slot(request);
    unsigned previous = atomic_load(&operation);
    if (operation_busy(previous) || !atomic_compare_exchange_strong(&operation, &previous, request))
        return false;
    if (!replies) {
        atomic_store(&operation, operation_state(slot_number, SNAP_BUSY));
        return false;
    }
    if (source_id) memcpy(import_source, source_id, sizeof import_source);
    TickType_t now = xTaskGetTickCount();
    atomic_store(&started_tick, now);
    atomic_store(&phase_started_tick, now);
    atomic_store(&elapsed_ms, 0);
    atomic_store(&phase_elapsed_ms, 0);
    atomic_store(&phase, "mount");
    atomic_store(&transferred, 0);
    atomic_store(&fpga_result, 0);
    if (xTaskCreate(worker, "snapshot", 4608, (void *)(uintptr_t)request, 4, NULL) != pdPASS) {
        finish_phase(xTaskGetTickCount());
        atomic_store(&elapsed_ms, ticks_elapsed_ms(xTaskGetTickCount(), now));
        atomic_store(&operation, operation_state(slot_number, SNAP_BUSY));
        return false;
    }
    return true;
}

bool Snapshot_StartSlot(bool load, unsigned slot_number)
{
    if (slot_number < 1 || slot_number > SNAP_SLOT_COUNT) return false;
    return start_operation(operation_state(slot_number, load ? MSG_LOADING : MSG_SAVING), NULL);
}

bool Snapshot_ListFiles(void)
{
    return start_operation(operation_state(Snapshot_OperationSlot(), MSG_LISTING), NULL);
}

bool Snapshot_Import(const uint8_t source_id[SNAP_ID_BYTES])
{
    if (!source_id) return false;
    return start_operation(operation_state(Snapshot_OperationSlot(), MSG_IMPORTING), source_id);
}
