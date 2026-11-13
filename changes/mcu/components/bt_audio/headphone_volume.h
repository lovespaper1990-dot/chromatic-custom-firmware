#pragma once

#include <stddef.h>
#include <stdint.h>

void HeadphoneVolume_SetWheel(uint8_t position);
void HeadphoneVolume_SetStreamWheel(uint8_t position);
int HeadphoneVolume_GetWheel(void);
void HeadphoneVolume_Apply(uint8_t *pcm, size_t length);
