#include "headphone_volume.h"
#include <stdatomic.h>
#include <string.h>

// The board reads seven bits from codec register 117. Both analog outputs
// mute above 0x76; smaller values turn the wheel up. Start muted until read.
enum { WheelMute = 0x77, UnityGain = 32768 };
static _Atomic uint32_t gain_q15;

void HeadphoneVolume_SetWheel(uint8_t position)
{
    uint32_t level = position < WheelMute ? WheelMute - position : 0;
    // Taper the amplitude so the quiet end can be adjusted in small steps.
    uint32_t gain = level * level * UnityGain / (WheelMute * WheelMute);
    atomic_store_explicit(&gain_q15, gain, memory_order_relaxed);
}

void HeadphoneVolume_Apply(uint8_t *pcm, size_t length)
{
    uint32_t gain = atomic_load_explicit(&gain_q15, memory_order_relaxed);
    if (gain == UnityGain) return;
    if (gain == 0) {
        memset(pcm, 0, length);
        return;
    }

    // Interleaved S16_LE, with no alignment requirement on the A2DP buffer.
    for (size_t i = 0; i + sizeof(int16_t) <= length; i += sizeof(int16_t)) {
        int16_t sample;
        memcpy(&sample, pcm + i, sizeof(sample));
        sample = (int32_t)sample * (int32_t)gain / UnityGain;
        memcpy(pcm + i, &sample, sizeof(sample));
    }
}
