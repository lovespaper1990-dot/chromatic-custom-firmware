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
def function(name):
    match = re.search(r"^static [^;\n]+\b" + name + r"\([^;]*?\)\s*\{", source, re.M)
    if not match:
        raise RuntimeError("Production function missing: " + name)
    first = source.index("{", match.start())
    depth = 1
    end = first + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end] + "\n"

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
#define BLOCK_WORDS 128
static atomic_uint word_count, transferred, fpga_result;
static SnapshotSPITransfer spi_transfer;
static uint8_t block_packet[BLOCK_WORDS * SNAP_WORD_BYTES + 4];
static bool block_transport, block_cached;
static uint16_t block_first, block_count, block_filled;
static int capability_mode, fail_prepare, fail_spi, reject_commit, corrupt_read;
static unsigned reads, writes, prepares, commits, legacy_calls;
static uint16_t prepared_first;
static bool prepared_write, wrote;
static uint8_t byte_at(uint16_t word, unsigned lane) { return word * 13u + lane * 7u; }
static snap_result_t exchange(uint8_t command, const uint8_t *data, size_t length,
                             const uint8_t *prefix, size_t prefix_len, uint8_t reply[RX_BYTES]) {
    memset(reply, 0, RX_BYTES);
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
    "select_transport", "fetch_block", "fetch_word", "stage_word"))
tests = r'''
static bool spi(bool read, uint8_t *packet, size_t bytes) {
    assert(read != prepared_write);
    unsigned count = block_words(prepared_first);
    assert(bytes == count * SNAP_WORD_BYTES + 2 && bytes <= sizeof block_packet);
    if (read) {
        ++reads;
        for (unsigned i = 0; i < count; ++i)
            for (unsigned j = 0; j < SNAP_WORD_BYTES; ++j)
                packet[i*SNAP_WORD_BYTES+j] = byte_at(prepared_first+i, j);
        uint16_t crc = block_crc16(packet, bytes - 2);
        packet[bytes-2] = crc >> 8; packet[bytes-1] = crc ^ corrupt_read;
    } else {
        ++writes;
        for (unsigned i = 0; i < count; ++i)
            for (unsigned j = 0; j < SNAP_WORD_BYTES; ++j)
                assert(packet[i*SNAP_WORD_BYTES+j] == byte_at(prepared_first+i, j));
        uint16_t crc = block_crc16(packet, bytes - 2);
        assert(packet[bytes-2] == (crc >> 8) && packet[bytes-1] == (crc & 0xff));
        wrote = true;
    }
    return !fail_spi;
}
static void reset(unsigned count) {
    atomic_store(&word_count, count); atomic_store(&transferred, 0);
    capability_mode = fail_prepare = fail_spi = reject_commit = corrupt_read = 0;
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
    puts("PASS production SPI cache: CRC16 vector/corruption, 3 geometries, 128-word boundaries/tails, ordered commit, no fallback after partial failure, explicit legacy capability, 32-bit tick wrap");
}
'''
with tempfile.TemporaryDirectory(prefix="chromatic-spi-cache-") as directory:
    path = Path(directory)
    (path / "test.c").write_text(prefix + functions + tests)
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-I" + str(root / "components/snapshot"), str(path / "test.c"),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
