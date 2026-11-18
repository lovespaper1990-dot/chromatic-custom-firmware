#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* One synchronous standard-SPI transaction; the owner arbitrates the shared bus. */
typedef bool (*SnapshotSPITransfer)(bool read, uint8_t *packet, size_t bytes);
void Snapshot_AttachSPI(SnapshotSPITransfer transfer);
void Snapshot_Init(void);
void Snapshot_Start(bool load);
bool Snapshot_Busy(void);
unsigned Snapshot_Percent(void);
uint32_t Snapshot_ElapsedMs(void);
uint32_t Snapshot_PhaseElapsedMs(void);
const char *Snapshot_Status(void);
void Snapshot_OnReply(const uint8_t payload[10]);
void Snapshot_PrintDiagnostics(void);
