"""Test explicit identity import against production A/B files and loading code."""
from pathlib import Path
import hashlib
import struct
import subprocess
import tempfile
import zlib

mcu = Path(__file__).resolve().parents[1]
source = r'''
#include "slot.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static const uint8_t old_id[8] = {0x1b,3,3,0xca,0xf6,0xb5,0x5a,0x79};
static const uint8_t new_id[8] = {0x1b,3,3,0xca,0xa1,0x37,0x8c,0x6b};
static unsigned pattern, words;
void import_test_fail(unsigned mode);
static uint8_t value(uint16_t index, unsigned lane) {
    static const uint8_t header[4] = {0,0,0xb0,0xca};
    if (index==0 && lane<4) return header[lane];
    if (index==64 && lane<2) return lane ? 7 : 0xc5;
    return (uint8_t)(pattern+index*13+lane);
}
static snap_result_t capture(uint16_t index, uint8_t word[8]) {
    for(unsigned lane=0;lane<8;++lane) word[lane]=value(index,lane);
    return SNAP_OK;
}
static snap_result_t restore(uint16_t index, uint8_t word[8]) {
    assert(index==words++);
    for(unsigned lane=0;lane<8;++lane) assert(word[lane]==value(index,lane));
    return SNAP_OK;
}
int main(int argc,char **argv) {
    assert(argc>=3);
    if (!strcmp(argv[1],"seed")) {
        for(unsigned slot=1;slot<=3;++slot)
            for(unsigned generation=0;generation<2;++generation) {
                pattern=slot*10+generation;
                assert(snap_slot_for_number(argv[2],old_id,slot,false,capture)==SNAP_OK);
            }
    } else if(!strcmp(argv[1],"target")) {
        pattern=99;
        assert(snap_slot_for_number(argv[2],new_id,3,false,capture)==SNAP_OK);
    } else if(!strcmp(argv[1],"fail")) {
        assert(argc==4); import_test_fail((unsigned)atoi(argv[3]));
        return snap_import_slots(argv[2],old_id,new_id);
    } else if(!strcmp(argv[1],"import")) {
        return snap_import_slots(argv[2],old_id,new_id);
    } else if(!strcmp(argv[1],"check")) {
        assert(argc==5); pattern=(unsigned)atoi(argv[4]);
        assert(snap_slot_for_number(argv[2],new_id,(unsigned)atoi(argv[3]),true,restore)==SNAP_OK);
        assert(words==snap_word_count(new_id));
    } else if(!strcmp(argv[1],"reject")) {
        uint8_t other[8]; memcpy(other,new_id,8); other[3]^=1;
        assert(snap_import_slots(argv[2],old_id,other)==SNAP_WRONG);
        assert(snap_import_slots(argv[2],old_id,old_id)==SNAP_INVALID);
    } else assert(0);
    return 0;
}
'''
old_crc = "F6B55A79"
new_crc = "A1378C6B"
old_id = bytes.fromhex("1b0303caf6b55a79")
new_id = bytes.fromhex("1b0303caa1378c6b")

with tempfile.TemporaryDirectory(prefix="si-", dir="/tmp") as directory:
    temp = Path(directory)
    harness = temp / "import.c"
    harness.write_text(source)
    binary = temp / "import"
    faults = temp / "faults.c"
    faults.write_text(r'''
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
static unsigned failure;
void import_test_fail(unsigned mode) { failure=mode; }
// ESP-IDF FatFs VFS has no fcntl callback, required by Newlib fdopen.
FILE *fdopen(int fd,const char *mode) { (void)fd; (void)mode; errno=ENOSYS; return NULL; }
int import_test_open(const char *path,int flags,...) {
    if(failure==4) { errno=EACCES; return -1; }
    return open(path,flags,0666);
}
ssize_t import_test_write(int fd,const void *data,size_t size) {
    if(failure==1 && size) return write(fd,data,size-1);
    if(failure==5) { errno=EINTR; return -1; }
    return write(fd,data,size);
}
int import_test_sync(int fd) {
    if(failure==2) { errno=EIO; return -1; }
    return fsync(fd);
}
int import_test_close(int fd) {
    int result=close(fd);
    if(failure==3) { errno=EIO; return -1; }
    return result;
}
''')
    flags = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
             "-I" + str(mcu / "components/snapshot")]
    slot_object = temp / "slot.o"
    subprocess.run(flags + ["-Dopen=import_test_open", "-Dwrite=import_test_write",
                            "-Dfsync=import_test_sync", "-Dclose=import_test_close",
                            "-c", str(mcu / "components/snapshot/slot.c"), "-o", str(slot_object)], check=True)
    subprocess.run(flags + [str(harness), str(faults), str(slot_object), "-o", str(binary)], check=True)

    def run(mode, folder, *args, result=0):
        completed = subprocess.run([str(binary), mode, str(folder), *map(str, args)],
                                   text=True, stdout=subprocess.PIPE)
        assert completed.returncode == result, completed.stdout
        return completed.stdout

    def file_at(folder, slot, crc, generation):
        base = folder if slot == 1 else folder / f"SLOT{slot}" / "1B0303CA"
        return base / f"{crc}.S{generation}"

    def originals(folder):
        return {f.relative_to(folder): hashlib.sha256(f.read_bytes()).digest()
                for f in folder.rglob(f"{old_crc}.S*")}

    def valid_file(path, identity):
        data = path.read_bytes()
        assert data[:12] == b"CSS\2" + identity
        assert struct.unpack(">I", data[-4:])[0] == zlib.crc32(data[:-4])
        return data

    for scenario in ("all", "existing", "corrupt", "fallback", "foreign", "wrap"):
        folder = temp / scenario
        folder.mkdir()
        run("seed", folder)
        if scenario == "existing":
            run("target", folder)
            existing = file_at(folder, 3, new_crc, 0).read_bytes()
        if scenario in ("corrupt", "fallback"):
            for generation in (range(2) if scenario == "corrupt" else (1,)):
                path = file_at(folder, 1 if scenario == "corrupt" else 2, old_crc, generation)
                data = bytearray(path.read_bytes()); data[-1] ^= 1; path.write_bytes(data)
        if scenario == "foreign":
            for generation in range(2):
                path = file_at(folder, 1, old_crc, generation)
                data = bytearray(path.read_bytes()); data[7] ^= 1
                data[-4:] = struct.pack(">I", zlib.crc32(data[:-4])); path.write_bytes(data)
        if scenario == "wrap":
            for generation in range(2):
                path = file_at(folder, 1, old_crc, generation)
                data = bytearray(path.read_bytes())
                data[12:16] = struct.pack(">I", 0xffffffff if generation == 0 else 0)
                data[-4:] = struct.pack(">I", zlib.crc32(data[:-4])); path.write_bytes(data)
        before = originals(folder)
        run("reject", folder)
        result = 2 if scenario == "corrupt" else 6 if scenario == "foreign" else 0
        run("import", folder, result=result)
        assert originals(folder) == before
        for slot in range(1, 4):
            if scenario in ("corrupt", "foreign") and slot == 1:
                assert not file_at(folder, slot, new_crc, 0).exists()
                assert not file_at(folder, slot, new_crc, 1).exists()
                continue
            expected = 99 if scenario == "existing" and slot == 3 else slot * 10 + 1
            if scenario == "fallback" and slot == 2:
                expected -= 1
                assert not file_at(folder, slot, new_crc, 1).exists()
            run("check", folder, slot, expected)
            for generation in range(2):
                target = file_at(folder, slot, new_crc, generation)
                if target.exists():
                    imported = valid_file(target, new_id)
                    if not (scenario == "existing" and slot == 3):
                        original = valid_file(file_at(folder, slot, old_crc, generation), old_id)
                        assert imported[12:-4] == original[12:-4]
        if scenario == "existing":
            assert file_at(folder, 3, new_crc, 0).read_bytes() == existing
            assert not file_at(folder, 3, new_crc, 1).exists()
        contents = {f.relative_to(folder): f.read_bytes() for f in folder.rglob("*") if f.is_file()}
        run("import", folder, result=result)
        assert {f.relative_to(folder): f.read_bytes() for f in folder.rglob("*") if f.is_file()} == contents
    for failure, stage in ((1,"target_header"),(2,"target_sync"),(3,"target_close"),
                           (4,"target_open"),(5,"target_header")):
        folder = temp / f"f{failure}"
        folder.mkdir()
        run("seed", folder)
        before = originals(folder)
        output = run("fail", folder, failure, result=3)
        assert f"stage={stage}" in output
        assert originals(folder) == before
        assert not list(folder.rglob(f"{new_crc}.S*"))
print("PASS explicit snapshot import: three slots/two generations, existing target skip, source bytes intact, full CRC rejection, foreign identity, newest selection, generation wrap, ESP-IDF fdopen failure, short-write/sync/close/open failures; ASan/UBSan")
