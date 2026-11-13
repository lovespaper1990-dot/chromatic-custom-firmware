#include "headphone_volume.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
    const int16_t source[] = {INT16_MIN, INT16_MAX, -1234, 2345, 0, 0};
    uint8_t pcm[sizeof(source) + 2] = {0x5a};
    pcm[sizeof(pcm) - 1] = 0xa5;
    memcpy(pcm + 1, source, sizeof(source));
    HeadphoneVolume_Apply(pcm + 1, sizeof(source));
    for (size_t i = 1; i <= sizeof(source); ++i) assert(pcm[i] == 0);

    int previous_peak = INT16_MAX;
    for (int raw = 0; raw <= 127; ++raw) {
        int16_t out[sizeof(source) / sizeof(source[0])];
        memcpy(pcm + 1, source, sizeof(source));
        HeadphoneVolume_SetWheel(raw);
        HeadphoneVolume_Apply(pcm + 1, sizeof(source));
        memcpy(out, pcm + 1, sizeof(out));
        assert(pcm[0] == 0x5a && pcm[sizeof(pcm) - 1] == 0xa5);
        assert(out[0] <= 0 && out[1] >= 0 && out[1] <= previous_peak);
        assert(out[2] >= -1234 && out[2] <= 0 && out[3] >= 0 && out[3] <= 2345);
        assert(out[4] == 0 && out[5] == 0);
        if (!raw) assert(memcmp(out, source, sizeof(source)) == 0);
        if (raw > 0 && raw <= 118) assert(out[1] < previous_peak && out[1] > 0);
        if (raw >= 119)
            for (size_t i = 0; i < sizeof(out) / sizeof(out[0]); ++i) assert(out[i] == 0);
        previous_peak = out[1];
    }
    HeadphoneVolume_SetStreamWheel(0);
    HeadphoneVolume_SetWheel(127);
    assert(HeadphoneVolume_GetWheel() == 0);
    memcpy(pcm + 1, source, sizeof(source));
    HeadphoneVolume_Apply(pcm + 1, sizeof(source));
    assert(!memcmp(pcm + 1, source, sizeof(source)));
    HeadphoneVolume_SetStreamWheel(127);
    HeadphoneVolume_Apply(pcm + 1, sizeof(source));
    for (size_t i = 1; i <= sizeof(source); ++i) assert(pcm[i] == 0);
    puts("PASS Bluetooth PCM wheel range, stereo polarity, startup mute, full scale and unaligned buffers");
    return 0;
}
