#include "headphones.h"
#include "bt_audio.h"
#include "osd_language.h"
#include <stdio.h>
#include <string.h>

static unsigned cursor;
static lv_obj_t *label;
static bool scanned;
static BTState previous;

OSD_Result_t Headphones_Draw(void *screen)
{
    BTSelection view;
    BT_GetSelection(cursor, &view);
    if (previous == BT_SCANNING && view.state == BT_IDLE && view.count) {
        cursor = 1;
        BT_GetSelection(cursor, &view);
    }
    previous = view.state;
    if (!label) {
        label = lv_label_create(screen);
        lv_obj_add_style(label, OSD_GetStyleTextWhite(), 0);
        lv_obj_set_pos(label, 77, 43);
        lv_obj_set_width(label, 68);
        lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
    }
    const char *action;
    const char *detail = "";
    switch (view.state) {
    case BT_SCANNING:
        action = "SCANNING...";
        break;
    case BT_CONNECTING:
        action = "CONNECTING...";
        detail = view.name;
        break;
    case BT_CONNECTED:
        action = "A: DISCONNECT";
        detail = view.name;
        break;
    default:
        action = cursor && cursor <= view.count ? "A: CONNECT" : "A: SCAN";
        if (!cursor && view.has_saved) action = "A: RECONNECT";
        if ((view.powered || view.auto_reconnect) && cursor == view.count + 1 + view.has_saved) action = "A: POWER OFF";
        detail = view.name;
        if (!detail[0] && view.state == BT_FAILED) detail = OSD_Text("TRY AGAIN");
        else if (!detail[0] && scanned && view.powered && !view.count) detail = OSD_Text("NO HEADSETS");
        break;
    }
    const char *next = (view.powered || view.has_saved) && (view.state == BT_IDLE || view.state == BT_FAILED)
                       ? OSD_Text("B: NEXT") : "";
    char text[120];
    snprintf(text, sizeof(text), "%s\n%s\n%s", detail, OSD_Text(action), next);
    if (strcmp(lv_label_get_text(label), text)) lv_label_set_text(label, text);
    return kOSD_Result_Ok;
}

OSD_Result_t Headphones_OnTransition(void *arg)
{
    (void)arg;
    if (label) lv_obj_del(label);
    label = NULL;
    return kOSD_Result_Ok;
}

OSD_Result_t Headphones_OnButton(Button_t button, ButtonState_t state, void *arg)
{
    (void)arg;
    if (state != kButtonState_Pressed) return kOSD_Result_Ok;

    BTSelection view;
    BT_GetSelection(cursor, &view);
    if (view.state == BT_CONNECTED && button == kButton_A) {
        cursor = 0;
        BT_Disconnect();
    } else if (view.state == BT_IDLE || view.state == BT_FAILED) {
        bool can_disable = view.powered || view.auto_reconnect;
        if (button == kButton_B) cursor = (cursor + 1) % (view.count + 1 + view.has_saved + can_disable);
        if (button == kButton_A) {
            if ((!cursor && view.has_saved) || (cursor && cursor <= view.count)) BT_Connect(cursor);
            else if (can_disable && cursor == view.count + 1 + view.has_saved) { cursor = 0; BT_PowerOff(); }
            else { cursor = 0; scanned = true; BT_Scan(); }
        }
    }
    return kOSD_Result_Ok;
}
