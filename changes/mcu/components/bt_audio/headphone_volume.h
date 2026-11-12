#pragma once

#include <stddef.h>
#include <stdint.h>

void HeadphoneVolume_SetWheel(uint8_t position);
void HeadphoneVolume_Apply(uint8_t *pcm, size_t length);
