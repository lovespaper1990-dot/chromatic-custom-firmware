#include "headphone_volume.h"
#include <stdatomic.h>
#include <string.h>

// The board reads seven bits from codec register 117. Both analog outputs
// mute above 0x76; smaller values turn the wheel up. Start muted until read.
enum { WheelMute = 0x77, UnityGain = 32768 };
static _Atomic uint32_t uart_gain;
static _Atomic int direct_gain = -1;
static _Atomic int wheel = -1;
static _Atomic int stream_wheel = -1;

int HeadphoneVolume_GetWheel(void)
{
    int direct = atomic_load_explicit(&stream_wheel, memory_order_relaxed);
    return direct >= 0 ? direct : atomic_load_explicit(&wheel, memory_order_relaxed);
}

static uint32_t wheel_gain(uint8_t position)
{
    uint32_t level = position < WheelMute ? WheelMute - position : 0;
    // Taper the amplitude so the quiet end can be adjusted in small steps.
    return level * level * UnityGain / (WheelMute * WheelMute);
}

void HeadphoneVolume_SetWheel(uint8_t position)
{
    atomic_store_explicit(&wheel, position, memory_order_relaxed);
    atomic_store_explicit(&uart_gain, wheel_gain(position), memory_order_relaxed);
}

void HeadphoneVolume_SetStreamWheel(uint8_t position)
{
    atomic_store_explicit(&stream_wheel, position, memory_order_relaxed);
    atomic_store_explicit(&direct_gain, wheel_gain(position), memory_order_relaxed);
}

void HeadphoneVolume_Apply(uint8_t *pcm, size_t length)
{
    int direct = atomic_load_explicit(&direct_gain, memory_order_relaxed);
    uint32_t gain = direct >= 0 ? (uint32_t)direct : atomic_load_explicit(&uart_gain, memory_order_relaxed);
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
