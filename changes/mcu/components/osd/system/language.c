#include "language.h"
#include "osd_language.h"

static lv_obj_t *label;

OSD_Result_t Language_Draw(void *screen)
{
    if (!label) {
        label = lv_label_create(screen);
        lv_obj_add_style(label, OSD_GetStyleTextWhite(), 0);
        lv_obj_set_pos(label, 78, 58);
        lv_label_set_text_fmt(label, "%s\n%s", OSD_Text("English"), OSD_Text("A/B: SWITCH"));
    }
    return kOSD_Result_Ok;
}

OSD_Result_t Language_OnTransition(void *arg)
{
    (void)arg;
    if (label) {
        lv_obj_del(label);
        label = NULL;
    }
    return kOSD_Result_Ok;
}

OSD_Result_t Language_OnButton(Button_t button, ButtonState_t state, void *arg)
{
    (void)arg;
    if (state != kButtonState_Pressed || (button != kButton_A && button != kButton_B))
        return kOSD_Result_Ok;

    bool new_language = !OSD_IsChinese();
    OSD_Result_t result = Settings_Update(kSettingKey_Chinese, new_language);
    if (result == kOSD_Result_Ok) {
        OSD_SetChinese(new_language);
        Language_OnTransition(NULL);
    }
    return result;
}

OSD_Result_t Language_ApplySetting(const SettingValue_t *value)
{
    if (!value || value->eType != kSettingDataType_U8)
        return kOSD_Result_Err_UnexpectedSettingDataType;
    OSD_SetChinese(value->U8 == 1);
    return kOSD_Result_Ok;
}
