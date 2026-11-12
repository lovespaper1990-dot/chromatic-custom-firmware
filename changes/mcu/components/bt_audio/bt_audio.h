#pragma once

#include <stdbool.h>
#include <stdint.h>

typedef enum {
    BT_IDLE,
    BT_SCANNING,
    BT_CONNECTING,
    BT_CONNECTED,
    BT_FAILED
} BTState;

typedef struct {
    BTState state;
    unsigned count;
    bool powered;
    bool has_saved;
    bool auto_reconnect;
    char name[40];        // selected headset, or connected peer
} BTSelection;

typedef int32_t (*BTReadPCM)(uint8_t *data, int32_t length);

void BT_AttachAudio(BTReadPCM read_pcm, void (*route_changed)(void));
void BT_Restore(void);
void BT_Service(void);
bool BT_IsStreaming(void);
void BT_GetSelection(unsigned index, BTSelection *selection);
void BT_Scan(void);
void BT_Connect(unsigned index);
void BT_Disconnect(void);
void BT_PowerOff(void);
bool BT_Busy(void);
