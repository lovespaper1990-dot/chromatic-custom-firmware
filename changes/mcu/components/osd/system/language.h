#pragma once

#include "settings.h"

OSD_Result_t Language_Draw(void *screen);
OSD_Result_t Language_OnTransition(void *arg);
OSD_Result_t Language_OnButton(Button_t button, ButtonState_t state, void *arg);
OSD_Result_t Language_ApplySetting(const SettingValue_t *value);
