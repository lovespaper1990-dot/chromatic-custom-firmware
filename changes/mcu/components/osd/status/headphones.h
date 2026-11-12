#pragma once
#include "osd_shared.h"

OSD_Result_t Headphones_Draw(void *screen);
OSD_Result_t Headphones_OnTransition(void *arg);
OSD_Result_t Headphones_OnButton(Button_t button, ButtonState_t state, void *arg);
