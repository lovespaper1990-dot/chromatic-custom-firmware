#include "snapshot_menu.h"
#include "snapshot.h"
#include <string.h>
#include <stdio.h>
#include "osd_language.h"

static lv_obj_t *label;
static bool confirm;

OSD_Result_t SnapshotMenu_Draw(void *screen)
{
    if (!label) {
        label = lv_label_create(screen);
        lv_obj_set_width(label, 81);
        lv_obj_align(label, LV_ALIGN_TOP_LEFT, 75, 44);
        lv_obj_add_style(label, OSD_GetStyleTextWhite(), 0);
    }
    const char *help = OSD_Text("A: Save\nB: Load");
    const char *status = OSD_Text(Snapshot_Status());
    char text[96];
    if (confirm) snprintf(text, sizeof text, "%s", OSD_Text("B: Confirm"));
    else if (Snapshot_Busy()) snprintf(text, sizeof text, "%s\n%u%%", status, Snapshot_Percent());
    else if (!strcmp(status, help)) snprintf(text, sizeof text, "%s", help);
    else snprintf(text, sizeof text, "%s\n%s", status, help);
    if (strcmp(text, lv_label_get_text(label))) lv_label_set_text(label, text);
    return kOSD_Result_Ok;
}
OSD_Result_t SnapshotMenu_Button(Button_t button, ButtonState_t state, void *arg)
{
    (void)arg;
    if (state != kButtonState_Pressed || Snapshot_Busy()) return kOSD_Result_Ok;
    if (button == kButton_A) {
        confirm = false;
        Snapshot_Start(false);
    } else if (button == kButton_B) {
        if (confirm) Snapshot_Start(true);
        confirm = !confirm;
    }
    return kOSD_Result_Ok;
}
OSD_Result_t SnapshotMenu_Leave(void *arg)
{
    (void)arg;
    if (label) lv_obj_del(label);
    label = NULL;
    confirm = false;
    return kOSD_Result_Ok;
}
