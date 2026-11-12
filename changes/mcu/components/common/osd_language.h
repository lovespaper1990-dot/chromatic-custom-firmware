#pragma once

#include <stdbool.h>

// Untranslated identifiers and device-provided strings are returned unchanged.
const char *OSD_Text(const char *english);
bool OSD_IsChinese(void);
void OSD_SetChinese(bool enabled);
