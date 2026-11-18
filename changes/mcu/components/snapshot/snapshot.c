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
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

enum { RX_BYTES = 10, CONTROL = 0x20, READ_WORD = 0x21, WRITE_WORD = 0x22,
       PREPARE_BLOCK = 0x23, COMMIT_BLOCK = 0x24, BLOCK_WORDS = 128 };
enum { STATUS, CAPTURE, RESTORE, IDENTITY, DIAGNOSTICS, CAPABILITY };
static QueueHandle_t replies;
static atomic_bool busy;
static atomic_uint transferred;
static atomic_uint word_count = SNAP_WORDS;
static _Atomic(const char *) phase = "idle";
_Static_assert(sizeof(TickType_t) == sizeof(uint32_t), "Snapshot timing requires 32-bit RTOS ticks");
static _Atomic(TickType_t) started_tick, phase_started_tick;
static atomic_uint elapsed_ms, phase_elapsed_ms;
static atomic_uint fpga_result;
static _Atomic(const char *) message = "A: Save\nB: Load";
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
    const char *status = Snapshot_Status();
    if (strchr(status, '\n')) status = "Idle";
    printf("{\"snapshot\":\"%s\",\"busy\":%d,\"progress\":%u,\"words\":%u,\"total\":%u,\"phase\":\"%s\",\"elapsed_ms\":%u,\"phase_elapsed_ms\":%u,\"fpga_result\":%u,"
           "\"sd_mount\":\"%s\",\"sd_command\":%u,\"sd_error\":\"%s\",\"sd_responded\":%d}\n",
           status, Snapshot_Busy(), Snapshot_Percent(), atomic_load(&transferred),
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
    if (replies && atomic_load(&busy)) xQueueSend(replies, payload, 0);
}
bool Snapshot_Busy(void)
{
    return atomic_load(&busy);
}
unsigned Snapshot_Percent(void)
{
    return 100 * atomic_load(&transferred) / atomic_load(&word_count);
}
const char *Snapshot_Status(void)
{
    return atomic_load(&message);
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
    uint16_t crc = 0xffff;
    while (length--) {
        crc ^= (uint16_t)*bytes++ << 8;
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = crc & 0x8000 ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
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
    if (!spi_transfer(true, block_packet, bytes + 2)) return SNAP_LINK;
    uint16_t received_crc = (uint16_t)block_packet[bytes] << 8 | block_packet[bytes + 1];
    if (received_crc != block_crc16(block_packet, bytes)) {
        printf("SNAPSHOT block CRC error index=%u words=%u\n", first, count);
        return SNAP_LINK;
    }
    block_first = first;
    block_count = count;
    block_cached = true;
    return SNAP_OK;
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
    do {
        uint8_t prefix[] = {0xff, 0xf0, op}, reply[RX_BYTES];
        snap_result_t rc = exchange(CONTROL, &op, 1, prefix, sizeof prefix, reply);
        if (rc != SNAP_OK) {
            printf("SNAPSHOT control op=%u link_result=%u\n",op,rc);
            return rc;
        }
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

static snap_result_t run(bool load)
{
    uint8_t id[SNAP_ID_BYTES], current[SNAP_ID_BYTES];
    start_phase("identity");
    snap_result_t rc = identity(id);
    if (rc != SNAP_OK) return rc;
    atomic_store(&word_count, snap_word_count(id));
    start_phase("transport");
    rc = select_transport();
    if (rc != SNAP_OK) return rc;
    const char *dir = "/sd/SNAP";
    if (mkdir(dir, 0777) != 0 && errno != EEXIST) return SNAP_IO;
    if (!load) {
        start_phase("capture");
        rc = command_wait(CAPTURE);
        printf("SNAPSHOT capture result=%u\n",rc);
        if (rc != SNAP_OK) return rc;
    }
    start_phase(load ? "stage" : "fetch");
    rc = snap_slot(dir, id, load, load ? stage_word : fetch_word);
    printf("SNAPSHOT file result=%u words=%u\n",rc,atomic_load(&transferred));
    if (rc == SNAP_OK && load) {
        start_phase("verify");
        rc = identity(current);
        if (rc != SNAP_OK) return rc;
        if (memcmp(id, current, sizeof id)) return SNAP_WRONG;
        start_phase("restore");
        rc = command_wait(RESTORE);
    }
    return rc;
}

static void worker(void *arg)
{
    bool load = (uintptr_t)arg != 0;
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
    const char *result;
    if (mount != ESP_OK) {
        bool no_response = !atomic_load(&sd_responded);
        result = no_response && (mount == ESP_ERR_TIMEOUT || mount == ESP_ERR_NOT_FOUND) ? "No SD card" : "Card error";
        finish_phase(xTaskGetTickCount());
    } else {
        snap_result_t rc = run(load);
        finish_phase(xTaskGetTickCount());
        TickType_t unmount_start = xTaskGetTickCount();
        if (esp_vfs_fat_sdcard_unmount("/sd", card) != ESP_OK && rc == SNAP_OK) rc = SNAP_IO;
        printf("SNAPSHOT timing phase=unmount elapsed_ms=%u\n",
               (unsigned)ticks_elapsed_ms(xTaskGetTickCount(), unmount_start));
        static const char *const errors[] = {
            [SNAP_EMPTY] = "No snapshot", [SNAP_INVALID] = "Bad file",
            [SNAP_IO] = "Card error", [SNAP_LINK] = "FPGA timeout",
            [SNAP_UNSUPPORTED] = "Unsupported", [SNAP_WRONG] = "Wrong game",
            [SNAP_BUSY] = "Busy", [SNAP_HW] = "FPGA error"
        };
        result = rc == SNAP_OK ? (load ? "Restored" : "Saved") : errors[rc];
    }
    atomic_store(&elapsed_ms, ticks_elapsed_ms(xTaskGetTickCount(), atomic_load(&started_tick)));
    atomic_store(&message, result);
    atomic_store(&busy, false);
    Snapshot_PrintDiagnostics();
    vTaskDelete(NULL);
}
void Snapshot_Start(bool load)
{
    if (!replies) { atomic_store(&message, "Busy"); return; }
    if (atomic_exchange(&busy, true)) return;
    TickType_t now = xTaskGetTickCount();
    atomic_store(&started_tick, now);
    atomic_store(&phase_started_tick, now);
    atomic_store(&elapsed_ms, 0);
    atomic_store(&phase_elapsed_ms, 0);
    atomic_store(&phase, "mount");
    atomic_store(&transferred, 0);
    atomic_store(&fpga_result, 0);
    atomic_store(&message, load ? "Loading..." : "Saving...");
    if (xTaskCreate(worker, "snapshot", 4608, (void *)(uintptr_t)load, 4, NULL) != pdPASS) {
        finish_phase(xTaskGetTickCount());
        atomic_store(&elapsed_ms, ticks_elapsed_ms(xTaskGetTickCount(), now));
        atomic_store(&message, "Busy");
        atomic_store(&busy, false);
    }
}
