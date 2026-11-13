#include "snapshot.h"
#include "slot.h"
#include "crc8_sae_j1850.h"
#include "driver/uart.h"
#include "driver/sdmmc_host.h"
#include "esp_vfs_fat.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "sdmmc_cmd.h"
#include <errno.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/stat.h>

enum { RX_BYTES = 10, CONTROL = 0x20, READ_WORD = 0x21, WRITE_WORD = 0x22 };
enum { STATUS, CAPTURE, RESTORE, IDENTITY };
static QueueHandle_t replies;
static atomic_bool busy;
static atomic_uint transferred;
static atomic_uint word_count = SNAP_WORDS;
static _Atomic(const char *) message = "A: Save\nB: Load";

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
        if (reply[0] == 0xff && reply[1] == 0xf0 && reply[2] == operation && reply[3] >= 2)
            return hardware_error(reply[3]);
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
    return snap_word_count(id) ? SNAP_OK : SNAP_UNSUPPORTED;
}
static snap_result_t command_wait(uint8_t op)
{
    TickType_t start = xTaskGetTickCount();
    do {
        uint8_t prefix[] = {0xff, 0xf0, op}, reply[RX_BYTES];
        snap_result_t rc = exchange(CONTROL, &op, 1, prefix, sizeof prefix, reply);
        if (rc != SNAP_OK) return rc;
        if (reply[3] == 0) return SNAP_OK;
        if (reply[3] != 1) return hardware_error(reply[3]);
        op = STATUS;
        vTaskDelay(pdMS_TO_TICKS(20));
    } while (xTaskGetTickCount() - start < pdMS_TO_TICKS(5000));
    return SNAP_LINK;
}

static snap_result_t fetch_word(uint16_t index, uint8_t *word)
{
    uint8_t address[2] = {index >> 8, index}, reply[RX_BYTES];
    snap_result_t rc = exchange(READ_WORD, address, 2, address, 2, reply);
    if (rc == SNAP_OK) {
        memcpy(word, reply + 2, SNAP_WORD_BYTES);
        atomic_store(&transferred, index + 1u);
    }
    return rc;
}
static snap_result_t stage_word(uint16_t index, uint8_t *word)
{
    uint8_t packet[RX_BYTES] = {index >> 8, index}, reply[RX_BYTES];
    memcpy(packet + 2, word, SNAP_WORD_BYTES);
    snap_result_t rc = exchange(WRITE_WORD, packet, sizeof packet, packet, sizeof packet, reply);
    if (rc == SNAP_OK) atomic_store(&transferred, index + 1u);
    return rc;
}

static snap_result_t run(bool load)
{
    uint8_t id[SNAP_ID_BYTES], current[SNAP_ID_BYTES];
    snap_result_t rc = identity(id);
    if (rc != SNAP_OK) return rc;
    atomic_store(&word_count, snap_word_count(id));
    const char *dir = "/sd/SNAP";
    if (mkdir(dir, 0777) != 0 && errno != EEXIST) return SNAP_IO;
    if (!load && (rc = command_wait(CAPTURE)) != SNAP_OK) return rc;
    rc = snap_slot(dir, id, load, load ? stage_word : fetch_word);
    if (rc == SNAP_OK && load) {
        rc = identity(current);
        if (rc != SNAP_OK) return rc;
        if (memcmp(id, current, sizeof id)) return SNAP_WRONG;
        rc = command_wait(RESTORE);
    }
    return rc;
}

static void worker(void *arg)
{
    bool load = (uintptr_t)arg != 0;
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 1;
    slot.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;
    esp_vfs_fat_sdmmc_mount_config_t options = {.format_if_mount_failed = false, .max_files = 2};
    sdmmc_card_t *card = NULL;
    esp_err_t mount = esp_vfs_fat_sdmmc_mount("/sd", &host, &slot, &options, &card);
    const char *result;
    if (mount != ESP_OK) {
        result = mount == ESP_ERR_TIMEOUT || mount == ESP_ERR_NOT_FOUND ? "No SD card" : "Card error";
    } else {
        snap_result_t rc = run(load);
        if (esp_vfs_fat_sdcard_unmount("/sd", card) != ESP_OK && rc == SNAP_OK) rc = SNAP_IO;
        static const char *const errors[] = {
            [SNAP_EMPTY] = "No snapshot", [SNAP_INVALID] = "Bad file",
            [SNAP_IO] = "Card error", [SNAP_LINK] = "FPGA timeout",
            [SNAP_UNSUPPORTED] = "Unsupported", [SNAP_WRONG] = "Wrong game",
            [SNAP_BUSY] = "Busy", [SNAP_HW] = "FPGA error"
        };
        result = rc == SNAP_OK ? (load ? "Restored" : "Saved") : errors[rc];
    }
    atomic_store(&message, result);
    atomic_store(&busy, false);
    vTaskDelete(NULL);
}
void Snapshot_Start(bool load)
{
    if (!replies) { atomic_store(&message, "Busy"); return; }
    if (atomic_exchange(&busy, true)) return;
    atomic_store(&transferred, 0);
    atomic_store(&message, load ? "Loading..." : "Saving...");
    if (xTaskCreate(worker, "snapshot", 4608, (void *)(uintptr_t)load, 4, NULL) != pdPASS) {
        atomic_store(&message, "Busy");
        atomic_store(&busy, false);
    }
}
