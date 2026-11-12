#pragma once
#include <stdbool.h>
#include <stdint.h>

void Snapshot_Init(void);
void Snapshot_Start(bool load);
bool Snapshot_Busy(void);
unsigned Snapshot_Percent(void);
const char *Snapshot_Status(void);
void Snapshot_OnReply(const uint8_t payload[10]);
