"""Exercise the production byte parser with adjacent and interrupted wire frames."""
from pathlib import Path
import subprocess
import tempfile

mcu = Path(__file__).resolve().parents[1]
parser = (mcu / "main/fpga_rx.c").read_text()
common = (mcu / "main/fpga_common.h").read_text()
declarations = common[common.index("typedef enum"):common.index("TaskHandle_t*")]
declarations += parser[parser.index("typedef enum {\n    kScanForHeaderMarker"):parser.index("static uint8_t RxBuffer")]
start = parser.index("static bool ReconstructMsg(uint8_t *pBuffer, RxMsg_t *pMsg)\n{")
functions = parser[start:parser.index("static void ProcessMessage", start)]
functions += parser[parser.rindex("static inline bool IsHeaderMarker"):]
source = r"""
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include "crc8_sae_j1850.h"
#define ESP_LOGE(tag, ...) ((void)(tag))
static inline bool IsHeaderMarker(uint8_t byte);
""" + declarations + functions + r"""
static unsigned feed(const uint8_t *p, size_t n, RxMsg_t *msg) {
    unsigned count = 0;
    for (size_t i = 0; i < n; ++i) count += ProcessByte(p[i], msg);
    return count;
}
int main(void) {
    RxMsg_t msg = {0};
    uint8_t empty[] = {0x8f, 0x0a, 0, 0};
    uint8_t snapshot[] = {0x8f, 0x0a, 10, 0xff, 0xf1, 0x8a, 0x8f, 0, 1, 2, 3, 4, 5, 0};
    const uint8_t legacy[] = {0x8a, 0x02, 0x8a, 0x05, 0x03, 0x07};
    crc8_sae_j1850_encode(empty, sizeof empty - 1, empty);
    crc8_sae_j1850_encode(snapshot, sizeof snapshot - 1, snapshot);
    assert(feed(empty, sizeof empty, &msg) == 1 && msg.Len == 0);
    assert(feed(snapshot, sizeof snapshot, &msg) == 1 && msg.Len == 10);
    assert(!memcmp(msg.Payload, snapshot + 3, msg.Len));
    empty[3] ^= 1;
    assert(feed(empty, sizeof empty, &msg) == 0);
    assert(feed(snapshot, sizeof snapshot, &msg) == 1 && msg.Len == 10);
    assert(feed(legacy, sizeof legacy, &msg) == 1 && msg.Len == 2);
    assert(msg.Header == 0x8a && msg.Addr == 5 && msg.Payload[0] == 7 && msg.Payload[1] == 3);
}
"""
with tempfile.TemporaryDirectory() as directory:
    harness = Path(directory) / "parser.c"
    binary = Path(directory) / "parser"
    harness.write_text(source)
    crc = mcu / "components/crc"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(crc),
                    str(harness), str(crc / "crc8_sae_j1850.c"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("PASS zero-length UART frames, bad CRC recovery, full snapshot reply, repeated V1 header")
