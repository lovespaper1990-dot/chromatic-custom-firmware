#include "snapshot_menu.h"
#include "snapshot.h"
#include "osd.h"
#include "osd_language.h"
#include <stdio.h>
#include <string.h>

static lv_obj_t *label;
static unsigned selected_slot = 1;
static bool confirm_load;
static bool show_result;
static bool switched_this_frame;

OSD_Result_t SnapshotMenu_Draw(void *screen)
{
    switched_this_frame = false;
    if (!OSD_IsVisible()) {
        confirm_load = false;
        show_result = false;
    }
    if (!label) {
        label = lv_label_create(screen);
        lv_obj_set_width(label, 68);
        lv_obj_align(label, LV_ALIGN_TOP_LEFT, 77, 42);
        lv_obj_add_style(label, OSD_GetStyleTextWhite(), 0);
        lv_obj_set_style_text_line_space(label, 1, 0);
    }
    const char *status = Snapshot_StatusForSlot(selected_slot);
    const char *help = OSD_Text("A: Save\nB: Load");
    char body[96], text[128];
    if (Snapshot_Busy()) {
        // A test request can also be started from USB. Display its actual slot.
        selected_slot = Snapshot_OperationSlot();
        status = Snapshot_StatusForSlot(selected_slot);
        confirm_load = false;
        show_result = true;
        snprintf(body, sizeof body, "%s\n%u%%", OSD_Text(status), Snapshot_Percent());
    } else if (confirm_load) {
        snprintf(body, sizeof body, "%s\n%s", OSD_Text("B: Confirm"), OSD_Text("A: Back"));
    } else if (show_result && strcmp(status, "A: Save\nB: Load") != 0) {
        snprintf(body, sizeof body, "%s\n%s\n%s", OSD_Text(status), OSD_Text("START: Next"), help);
    } else {
        snprintf(body, sizeof body, "%s\n%s", OSD_Text("START: Next"), help);
    }
    snprintf(text, sizeof text, "%s %u/%u\n%s", OSD_Text("Slot"), selected_slot,
             (unsigned)SNAP_SLOT_COUNT, body);
    if (strcmp(text, lv_label_get_text(label))) lv_label_set_text(label, text);
    return kOSD_Result_Ok;
}

OSD_Result_t SnapshotMenu_Button(Button_t button, ButtonState_t state, void *arg)
{
    (void)arg;
    if (state != kButtonState_Pressed || !OSD_IsVisible() || Snapshot_Busy() || switched_this_frame)
        return kOSD_Result_Ok;
    if (button == kButton_Start) {
        selected_slot = selected_slot % SNAP_SLOT_COUNT + 1;
        switched_this_frame = true;
        confirm_load = false;
        show_result = false;
    } else if (button == kButton_A) {
        if (confirm_load) confirm_load = false;
        else {
            show_result = true;
            Snapshot_StartSlot(false, selected_slot);
        }
    } else if (button == kButton_B) {
        if (confirm_load) {
            show_result = true;
            Snapshot_StartSlot(true, selected_slot);
        }
        confirm_load = !confirm_load;
    }
    return kOSD_Result_Ok;
}

OSD_Result_t SnapshotMenu_Leave(void *arg)
{
    (void)arg;
    if (label) lv_obj_del(label);
    label = NULL;
    confirm_load = false;
    show_result = false;
    switched_this_frame = false;
    return kOSD_Result_Ok;
}
