#!/usr/bin/env python3
"""Compile the production cache/CRC functions with deterministic UART/SPI peers.

ESP-IDF hardware headers are omitted; the function bodies come directly from
snapshot.c, so this exercises production framing, cache and failure branches.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "components/snapshot/snapshot.c").read_text()
def function(name, source_text=source):
    match = re.search(r"^(?:static )?[\w *]+\b" + name + r"\([^;]*?\)\s*\{", source_text, re.M)
    if not match:
        raise RuntimeError("Production function missing: " + name)
    first = source_text.index("{", match.start())
    depth = 1
    end = first + 1
    while depth:
        depth += (source_text[end] == "{") - (source_text[end] == "}")
        end += 1
    return source_text[match.start():end] + "\n"

prefix = r'''
#include "snapshot.h"
#include "slot.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t TickType_t;
#define portTICK_PERIOD_MS 10
#define RX_BYTES 10
#define CONTROL 0x20
#define READ_WORD 0x21
#define WRITE_WORD 0x22
#define PREPARE_BLOCK 0x23
#define COMMIT_BLOCK 0x24
#define CAPABILITY 5
#define CAPTURE 1
#define RESTORE 2
#define STATUS 0
#define pdMS_TO_TICKS(ms) ((ms) / portTICK_PERIOD_MS)
#define BLOCK_WORDS 128
static atomic_uint word_count, transferred, fpga_result;
static SnapshotSPITransfer spi_transfer;
static uint8_t block_packet[BLOCK_WORDS * SNAP_WORD_BYTES + 4];
static bool block_transport, block_cached;
static uint16_t block_first, block_count, block_filled;
static int capability_mode, fail_prepare, fail_spi, reject_commit, corrupt_read;
static int corrupt_once;
static unsigned reads, writes, prepares, commits, legacy_calls;
static uint16_t prepared_first;
static bool prepared_write, wrote;
static TickType_t mock_tick;
static unsigned poll_failures, polls, starts;
static bool lost_start;
static TickType_t xTaskGetTickCount(void) { return mock_tick; }
static void vTaskDelay(TickType_t ticks) { mock_tick+=ticks; }
static void print_capture_diagnostics(void) { assert(false); }
static uint8_t byte_at(uint16_t word, unsigned lane) { return word * 13u + lane * 7u; }
static snap_result_t exchange(uint8_t command, const uint8_t *data, size_t length,
                             const uint8_t *prefix, size_t prefix_len, uint8_t reply[RX_BYTES]) {
    memset(reply, 0, RX_BYTES);
    if (command == CONTROL && data[0] != CAPABILITY) {
        assert(length == 1 && prefix_len == 3 && prefix[2] == data[0]);
        if (data[0] == STATUS) {
            if (++polls <= poll_failures) return SNAP_LINK;
        } else {
            assert(data[0] == RESTORE || data[0] == CAPTURE);
            ++starts;
            if (lost_start) return SNAP_LINK;
            reply[3]=1;
        }
        return SNAP_OK;
    }
    if (command == CONTROL) {
        assert(length == 1 && data[0] == CAPABILITY && prefix_len == RX_BYTES);
        if (capability_mode == 1) {
            memcpy(reply, (uint8_t[]){0xff,0xf0,CAPABILITY,3}, 4);
            return SNAP_HW;
        }
        if (capability_mode == 2) return SNAP_LINK;
        if (capability_mode == 3) return SNAP_UNSUPPORTED;
        memcpy(reply, (uint8_t[]){0xff,0xf3,0x42,0x4c,0x4b,0x31,0,0,0,0}, RX_BYTES);
        assert(!memcmp(prefix, reply, RX_BYTES));
        return SNAP_OK;
    }
    if (command == READ_WORD || command == WRITE_WORD) { ++legacy_calls; return SNAP_LINK; }
    assert(length == 4 && data[0] <= 1 && data[3] == 0 && prefix_len == 3);
    assert(prefix[0] == 0xff && prefix[1] == 0xf0 && prefix[2] == command);
    uint16_t first = (uint16_t)data[1] << 8 | data[2];
    assert(first % BLOCK_WORDS == 0 && first < atomic_load(&word_count));
    reply[0] = 0xff; reply[1] = 0xf0; reply[2] = command;
    if (command == PREPARE_BLOCK) {
        ++prepares; prepared_first = first; prepared_write = data[0]; wrote = false;
        return fail_prepare ? SNAP_LINK : SNAP_OK;
    }
    assert(command == COMMIT_BLOCK && prepared_write && wrote && first == prepared_first);
    ++commits;
    return reject_commit ? SNAP_HW : SNAP_OK;
}
'''
functions = "\n".join(function(n) for n in (
    "ticks_elapsed_ms", "hardware_error", "block_words", "block_crc16", "block_control",
    "select_transport", "fetch_block", "fetch_word", "stage_word", "command_wait"))
tests = r'''
// Serial bit oracle matches the FPGA's wire calculation independently of the
// driver's nibble lookup; use it for both peer packets and host assertions.
static uint16_t wire_crc(const uint8_t *data, size_t length) {
    uint16_t crc = 0xffff;
    for (size_t i = 0; i < length; ++i) {
        for (unsigned mask = 0x80; mask; mask >>= 1) {
            bool feedback = ((crc & 0x8000) != 0) != ((data[i] & mask) != 0);
            crc = (uint16_t)(crc << 1);
            if (feedback) crc ^= 0x1021;
        }
    }
    return crc;
}
static bool spi(bool read, uint8_t *packet, size_t bytes) {
    assert(read != prepared_write);
    unsigned count = block_words(prepared_first);
    assert(bytes == count * SNAP_WORD_BYTES + 2 && bytes <= sizeof block_packet);
    if (read) {
        ++reads;
        for (unsigned i = 0; i < count; ++i)
            for (unsigned j = 0; j < SNAP_WORD_BYTES; ++j)
                packet[i*SNAP_WORD_BYTES+j] = byte_at(prepared_first+i, j);
        uint16_t crc = wire_crc(packet, bytes - 2);
        packet[bytes-2] = crc >> 8; packet[bytes-1] = crc ^ (corrupt_read || corrupt_once);
        corrupt_once = 0;
    } else {
        ++writes;
        for (unsigned i = 0; i < count; ++i)
            for (unsigned j = 0; j < SNAP_WORD_BYTES; ++j)
                assert(packet[i*SNAP_WORD_BYTES+j] == byte_at(prepared_first+i, j));
        uint16_t crc = wire_crc(packet, bytes - 2);
        assert(packet[bytes-2] == (crc >> 8) && packet[bytes-1] == (crc & 0xff));
        wrote = true;
    }
    return !fail_spi;
}
static void reset(unsigned count) {
    atomic_store(&word_count, count); atomic_store(&transferred, 0);
    capability_mode = fail_prepare = fail_spi = reject_commit = corrupt_read = corrupt_once = 0;
    reads = writes = prepares = commits = legacy_calls = 0;
    spi_transfer = spi; block_cached = false;
    assert(select_transport() == SNAP_OK && block_transport);
}
static void word_at(uint16_t i, uint8_t word[8]) {
    for (unsigned j = 0; j < 8; ++j) word[j] = byte_at(i,j);
}
int main(void) {
    assert(block_crc16((const uint8_t *)"123456789", 9) == 0x29b1);
    assert(block_crc16((const uint8_t *)"", 0) == 0xffff);
    uint8_t probe[BLOCK_WORDS * SNAP_WORD_BYTES];
    for (unsigned i=0; i<sizeof probe; ++i)
        probe[i]=(uint8_t)(i*97u + (i>>8)*39u);
    for (unsigned length=0; length<=sizeof probe; ++length)
        assert(block_crc16(probe,length)==wire_crc(probe,length));
    assert(ticks_elapsed_ms(0x15, 0xfffffff0u) == 370);
    for (unsigned geometry = 0; geometry < 3; ++geometry) {
        unsigned total = (unsigned[]){6309,7269,10341}[geometry];
        unsigned blocks = (total + 127) / 128;
        reset(total);
        uint8_t word[8], expected[8];
        assert(!block_words(1) && !block_words(total));
        for (uint16_t i = 0; i < total; ++i) {
            assert(fetch_word(i, word) == SNAP_OK); word_at(i, expected);
            assert(!memcmp(word, expected, 8));
        }
        assert(reads == blocks && prepares == blocks && !writes && !commits && !legacy_calls);
        assert(atomic_load(&transferred) == total);
        assert(fetch_word(total, word) == SNAP_INVALID);
        reset(total);
        for (uint16_t i = 0; i < total; ++i) {
            word_at(i, word); assert(stage_word(i, word) == SNAP_OK);
        }
        assert(writes == blocks && prepares == blocks && commits == blocks && !reads && !legacy_calls);
        assert(!block_cached && atomic_load(&transferred) == total);
    }
    uint8_t word[8];
    reset(6309); corrupt_read=1;
    assert(fetch_word(0,word)==SNAP_LINK && !block_cached && block_transport && !legacy_calls);
    assert(reads==2 && prepares==1);
    reset(6309); corrupt_once=1;
    assert(fetch_word(0,word)==SNAP_OK && reads==2 && prepares==1);
    for(unsigned j=0;j<8;++j) assert(word[j]==byte_at(0,j));
    reset(6309); fail_prepare=1;
    assert(fetch_word(0,word)==SNAP_LINK && !reads && !legacy_calls);
    reset(6309); fail_spi=1;
    for(uint16_t i=0;i<128;++i) { word_at(i,word); assert(stage_word(i,word)==(i==127?SNAP_LINK:SNAP_OK)); }
    assert(writes==1 && !commits && block_transport && !legacy_calls);
    reset(6309); reject_commit=1;
    for(uint16_t i=0;i<128;++i) { word_at(i,word); assert(stage_word(i,word)==(i==127?SNAP_HW:SNAP_OK)); }
    assert(commits==1 && !legacy_calls);
    reset(6309); word_at(0,word);
    assert(stage_word(1,word)==SNAP_INVALID);
    assert(stage_word(0,word)==SNAP_OK && stage_word(2,word)==SNAP_INVALID && !writes);
    capability_mode=1;
    assert(select_transport()==SNAP_OK && !block_transport);
    assert(fetch_word(0,word)==SNAP_LINK && legacy_calls==1);
    capability_mode=2;
    assert(select_transport()==SNAP_LINK && !block_transport && legacy_calls==1);
    capability_mode=3;
    assert(select_transport()==SNAP_UNSUPPORTED && !block_transport);
    capability_mode=0; spi_transfer=NULL;
    assert(select_transport()==SNAP_LINK && !block_transport);
    poll_failures=1; mock_tick=0xfffffffeu;
    assert(command_wait(RESTORE)==SNAP_OK && starts==1 && polls==2);
    polls=0; starts=0; poll_failures=3;
    assert(command_wait(CAPTURE)==SNAP_LINK && starts==1 && polls==2);
    polls=0; starts=0; lost_start=true;
    assert(command_wait(RESTORE)==SNAP_LINK && starts==1 && polls==0);
    puts("PASS control timeout recovery: a lost status reply is retried once, capture and restore commands are never replayed");
    puts("PASS production SPI cache: independent wire CRC16 for lengths 0..1024, one-shot/persistent CRC faults, 3 geometries, ordered commit, no fallback after partial failure, explicit legacy capability, 32-bit tick wrap");
}
'''
# Use production operation ordering with fault-injectable media and cartridge.
operation_stubs = r'''
#include "slot.h"
#include <assert.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
typedef int sdmmc_card_t;
enum { ESP_OK, CAPTURE, RESTORE };
static atomic_uint word_count, transferred;
static char trace[32];
static unsigned calls, expected_slot, made_dirs;
static bool swapped, absent, unmount_fails;
static snap_result_t capture_status, file_status;
static void event(char c) { size_t i = strlen(trace); assert(i+1<sizeof trace); trace[i]=c; trace[i+1]=0; }
static void start_phase(const char *phase) { (void)phase; }
static uint8_t original_id[SNAP_ID_BYTES] = {1,1,0,1,2,3,4,5};
uint16_t snap_word_count(const uint8_t *id) { (void)id; return 6309; }
static snap_result_t identity(uint8_t *id) {
    event('I'); memcpy(id,original_id,SNAP_ID_BYTES);
    if (++calls == 2) {
        if (absent) return SNAP_UNSUPPORTED;
        if (swapped) id[7] ^= 1;
    }
    return SNAP_OK;
}
static snap_result_t select_transport(void) { event('T'); return SNAP_OK; }
static int mkdir(const char *path, int mode) { (void)path; (void)mode; ++made_dirs; return 0; }
static snap_result_t command_wait(uint8_t op) {
    assert(op==CAPTURE || op==RESTORE); event(op==CAPTURE?'C':'R');
    return op==CAPTURE?capture_status:SNAP_OK;
}
static snap_result_t fetch_word(uint16_t i, uint8_t *word) { (void)i; (void)word; return SNAP_OK; }
static snap_result_t stage_word(uint16_t i, uint8_t *word) { (void)i; (void)word; return SNAP_OK; }
snap_result_t snap_slot_for_number(const char *dir, const uint8_t *id, unsigned number, bool load, snap_word_fn fn) {
    (void)dir; assert(!memcmp(id,original_id,SNAP_ID_BYTES));
    assert(number==expected_slot);
    assert(fn==(load?stage_word:fetch_word)); event('F'); return file_status;
}
static int esp_vfs_fat_sdcard_unmount(const char *path, sdmmc_card_t *card) {
    (void)path; (void)card; event('U'); return unmount_fails?-1:ESP_OK;
}
'''
operation_tests = r'''
static void check(bool load, const char *expected, snap_result_t result) {
    trace[0]=0; calls=made_dirs=0;
    assert(run(load,expected_slot,NULL)==result);
    assert(!strcmp(trace,expected));
    assert(made_dirs==(load?0u:1u));
    swapped=absent=unmount_fails=false;
    capture_status=file_status=SNAP_OK;
}
int main(void) {
    for (expected_slot=1; expected_slot<=SNAP_SLOT_COUNT; ++expected_slot) {
        check(false,"ITCIFU",SNAP_OK);
        check(true,"ITFUIR",SNAP_OK);
    }
    expected_slot=2;
    swapped=true; check(false,"ITCIU",SNAP_WRONG);
    absent=true; check(false,"ITCIU",SNAP_UNSUPPORTED);
    swapped=true; check(true,"ITFUI",SNAP_WRONG);
    absent=true; check(true,"ITFUI",SNAP_UNSUPPORTED);
    capture_status=SNAP_HW; check(false,"ITCU",SNAP_HW);
    unmount_fails=true; check(true,"ITFU",SNAP_IO);
    file_status=SNAP_INVALID; unmount_fails=true; check(true,"ITFU",SNAP_INVALID);
    puts("PASS production save/load ordering: cartridge changed or missing after capture/at restore, unmount failure, file and capture errors");
}
'''
operations = "\n".join(function(n) for n in ("check_identity", "prepare_snapshot", "run"))
# Run the real request and worker entry points with a parked FreeRTOS task.
# Competing UI/console requests can arrive before we let the worker start.
request_stubs = r'''
#include "snapshot.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
enum { pdPASS=1, ESP_OK=0, ESP_ERR_TIMEOUT=1, ESP_ERR_NOT_FOUND=2,
       SDMMC_SLOT_FLAG_INTERNAL_PULLUP=1, GPIO_NUM_13=13 };
typedef int TickType_t, esp_err_t, sdmmc_card_t, sdmmc_command_t;
typedef esp_err_t (*transaction_fn)(int, sdmmc_command_t *);
typedef struct { transaction_fn do_transaction; } sdmmc_host_t;
typedef struct { int width, flags; } sdmmc_slot_config_t;
typedef struct { bool format_if_mount_failed; int max_files; } esp_vfs_fat_sdmmc_mount_config_t;
#define SDMMC_HOST_DEFAULT() ((sdmmc_host_t){0})
#define SDMMC_SLOT_CONFIG_DEFAULT() ((sdmmc_slot_config_t){0})
static transaction_fn sd_native_transaction;
static int replies=1, create_ok=1;
static atomic_uint transferred, started_tick, phase_started_tick, elapsed_ms, phase_elapsed_ms, fpga_result;
static atomic_uint sd_last_command, sd_last_error, sd_mount_error;
static atomic_bool sd_responded;
static _Atomic(const char *) phase;
static esp_err_t sd_transaction(int slot, sdmmc_command_t *cmd) { (void)slot; (void)cmd; return 0; }
static void gpio_pullup_en(int n) { (void)n; }
static esp_err_t fake_mount;
static esp_err_t esp_vfs_fat_sdmmc_mount(const char *path, sdmmc_host_t *host, sdmmc_slot_config_t *slot,
    esp_vfs_fat_sdmmc_mount_config_t *options, sdmmc_card_t **card) {
    (void)path; (void)host; (void)slot; (void)options; (void)card; return fake_mount;
}
static const char *esp_err_to_name(esp_err_t err) { (void)err; return "test"; }
static TickType_t xTaskGetTickCount(void) { return 10; }
static unsigned ticks_elapsed_ms(TickType_t now, TickType_t before) { return now-before; }
static void finish_phase(TickType_t now) { (void)now; }
static void vTaskDelete(void *task) { (void)task; }
void Snapshot_PrintDiagnostics(void) {}
static void (*parked_worker)(void *);
static void *parked_arg;
static int xTaskCreate(void (*fn)(void *), const char *name, int stack, void *arg, int priority, void *handle) {
    (void)name; (void)stack; (void)priority; (void)handle;
    if (!create_ok) return 0;
    assert(!parked_worker); parked_worker=fn; parked_arg=arg; return pdPASS;
}
static unsigned received_slot;
static bool received_load;
static snap_result_t mock_result;
static snap_result_t run(bool load,unsigned slot,sdmmc_card_t *card) {
    (void)card; received_load=load; received_slot=slot; return mock_result;
}
'''
request_tests = r'''
static void finish(void) { assert(parked_worker); parked_worker(parked_arg); parked_worker=NULL; }
static void *contend(void *arg) {
    unsigned slot=(uintptr_t)arg;
    return (void *)(uintptr_t)Snapshot_StartSlot(slot==3,slot);
}
int main(void) {
    assert(!Snapshot_Busy() && Snapshot_OperationSlot()==1);
    for(unsigned slot=1;slot<=SNAP_SLOT_COUNT;++slot) {
        assert(!strcmp(Snapshot_StatusForSlot(slot),"A: Save\nB: Load"));
        bool load=slot!=2; assert(Snapshot_StartSlot(load,slot));
        assert(Snapshot_Busy() && Snapshot_OperationSlot()==slot);
        assert(!strcmp(Snapshot_StatusForSlot(slot),load?"Loading...":"Saving..."));
        assert(!Snapshot_StartSlot(!load,slot%3+1)); finish();
        assert(!Snapshot_Busy() && received_load==load && received_slot==slot);
        assert(!strcmp(Snapshot_StatusForSlot(slot),load?"Restored":"Saved"));
        assert(!strcmp(Snapshot_StatusForSlot(slot%3+1),"A: Save\nB: Load"));
    }
    assert(!Snapshot_StartSlot(false,0) && !Snapshot_StartSlot(true,4) && !parked_worker);
    pthread_t a,b; void *left,*right;
    assert(!pthread_create(&a,NULL,contend,(void *)2)); assert(!pthread_create(&b,NULL,contend,(void *)3));
    assert(!pthread_join(a,&left)); assert(!pthread_join(b,&right));
    assert((uintptr_t)left+(uintptr_t)right==1); finish();
    assert(received_slot==(left?2u:3u) && received_load==!left);
    Snapshot_Start(false); finish(); assert(received_slot==1 && !received_load);
    create_ok=0; assert(!Snapshot_StartSlot(false,2) && !Snapshot_Busy());
    assert(!strcmp(Snapshot_StatusForSlot(2),"Busy")); create_ok=1;
    fake_mount=ESP_ERR_TIMEOUT; assert(Snapshot_StartSlot(true,3)); finish();
    assert(!strcmp(Snapshot_StatusForSlot(3),"No SD card")); fake_mount=ESP_OK;
    mock_result=SNAP_EMPTY; assert(Snapshot_StartSlot(true,2)); finish();
    assert(!strcmp(Snapshot_StatusForSlot(2),"No snapshot")); mock_result=SNAP_OK;
    char *cmd[]={"snapshot","save","3",NULL};
    assert(!report_snapshot(1,cmd) && !parked_worker);
    assert(!report_snapshot(2,cmd)); finish(); assert(received_slot==1 && !received_load);
    assert(!report_snapshot(3,cmd)); finish(); assert(received_slot==3 && !received_load);
    cmd[2]="0"; assert(report_snapshot(3,cmd)==1 && !parked_worker);
    cmd[2]="22"; assert(report_snapshot(3,cmd)==1 && !parked_worker);
    cmd[2]=""; assert(report_snapshot(3,cmd)==1 && !parked_worker);
    cmd[1]="load"; assert(report_snapshot(2,cmd)==1 && !parked_worker);
    puts("PASS slot dispatch: competing starts accept one immutable target, worker results bound to slot, default slot 1, valid/invalid console requests, SD/task errors");
}
'''
state_definition = source[source.index("enum { MSG_SAVING"):source.index("static atomic_uint transferred")]
entry_points = "\n".join(function(n) for n in (
    "Snapshot_Busy", "Snapshot_Status", "Snapshot_OperationSlot", "Snapshot_StatusForSlot",
    "worker", "Snapshot_StartSlot", "Snapshot_Start"))
command = function("report_snapshot", (root / "main/main.c").read_text())
for harness in (prefix + functions + tests, operation_stubs + operations + operation_tests,
                request_stubs + state_definition + entry_points + command + request_tests):
    with tempfile.TemporaryDirectory(prefix="chromatic-snapshot-") as directory:
        path = Path(directory)
        (path / "test.c").write_text(harness)
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                        "-I" + str(root / "components/snapshot"), str(path / "test.c"),
                        "-o", str(path / "test")], check=True)
        subprocess.run([str(path / "test")], check=True)
