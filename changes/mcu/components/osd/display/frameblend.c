#include "osd_language.h"
#include "frameblend.h"

#include "esp_log.h"
#include "osd_shared.h"
#include "lvgl.h"
#include "mutex.h"
#include "settings.h"

LV_IMG_DECLARE(img_toggle_on);
LV_IMG_DECLARE(img_toggle_off);

enum {
    kToggleBtnX_px = 77,
    kToggleBtnY_px = 55,

    kToggleHalfCenterOffset_px = 16,
};

typedef struct FrameBlend {
    lv_obj_t* pImgToggleOffObj;
    lv_obj_t* pImgToggleOnObj;
    FrameBlendState_t eCurrentState;
    fnOnUpdateCb_t fnOnUpdateCb;
} FrameBlend_t;

static const char* TAG = "FrameBlend";
static FrameBlend_t _Ctx;

static void SaveToSettings(const uint8_t eNewState);

OSD_Result_t FrameBlend_Draw(void* arg)
{
    if (arg == NULL)
    {
        return kOSD_Result_Err_NullDataPtr;
    }

    lv_obj_t *const pScreen = (lv_obj_t *const) arg;

    const bool on = _Ctx.eCurrentState == kFrameBlendState_On;
    lv_obj_t **image = on ? &_Ctx.pImgToggleOnObj : &_Ctx.pImgToggleOffObj;
    if (*image == NULL)
    {
        *image = lv_img_create(pScreen);
        lv_img_set_src(*image, on ? &img_toggle_on : &img_toggle_off);
        lv_obj_set_pos(*image, kToggleBtnX_px, kToggleBtnY_px);

        lv_obj_t *state = lv_label_create(*image);
        lv_obj_add_style(state, OSD_GetStyleTextBlack(), 0);
        lv_label_set_text_static(state, OSD_Text(on ? "ON" : "OFF"));
        lv_obj_align(state, LV_ALIGN_CENTER, on ? -kToggleHalfCenterOffset_px : kToggleHalfCenterOffset_px, 0);
        if (on)
        {
            lv_obj_t *ratio = lv_label_create(*image);
            lv_obj_add_style(ratio, OSD_GetStyleTextBlack(), 0);
            lv_label_set_text_static(ratio, "1:1");
            lv_obj_align(ratio, LV_ALIGN_CENTER, kToggleHalfCenterOffset_px, 0);
        }
    }

    return kOSD_Result_Ok;
}

void FrameBlend_Update(const FrameBlendState_t eNewState)
{
    if ((unsigned)eNewState >= kNumFrameBlendState)
    {
        return;
    }

    if (_Ctx.pImgToggleOffObj != NULL)
    {
        lv_obj_del(_Ctx.pImgToggleOffObj);
        _Ctx.pImgToggleOffObj = NULL;
    }

    if (_Ctx.pImgToggleOnObj != NULL)
    {
        lv_obj_del(_Ctx.pImgToggleOnObj);
        _Ctx.pImgToggleOnObj = NULL;
    }

    if (Mutex_Take(kMutexKey_FrameBlend) == kMutexResult_Ok)
    {
        const FrameBlendState_t eCurrentState = _Ctx.eCurrentState;
        _Ctx.eCurrentState = eNewState;

        if (eNewState != eCurrentState)
        {
            SaveToSettings(eNewState);
        }

        (void) Mutex_Give(kMutexKey_FrameBlend);
    }

    if (_Ctx.fnOnUpdateCb != NULL)
    {
        _Ctx.fnOnUpdateCb();
    }
}

OSD_Result_t FrameBlend_OnButton(const Button_t Button, const ButtonState_t State, void *arg)
{
    (void)arg;

    switch (Button)
    {
        case kButton_A:
        {
            if (State == kButtonState_Pressed)
            {
                FrameBlendState_t NewState = _Ctx.eCurrentState + 1;
                NewState %= kNumFrameBlendState;

                FrameBlend_Update(NewState);
            }
            break;
        }
        case kButton_B:
        {
            if (State == kButtonState_Pressed)
            {
                FrameBlendState_t NewState = _Ctx.eCurrentState;

                if (NewState > 0)
                {
                    NewState--;
                }
                else
                {
                    NewState = kNumFrameBlendState - 1;
                }

                FrameBlend_Update(NewState);
            }
            break;
        }
        default:
            break;
    }
    return kOSD_Result_Ok;
}

OSD_Result_t FrameBlend_OnTransition(void* arg)
{
    (void)arg;

    lv_obj_t** ToDelete[] = {
        &_Ctx.pImgToggleOffObj,
        &_Ctx.pImgToggleOnObj,
    };

    for (size_t i = 0; i < ARRAY_SIZE(ToDelete); i++)
    {
        if (*ToDelete[i] != NULL)
        {
            lv_obj_del(*ToDelete[i]);
            *(ToDelete[i]) = NULL;
        }
    }

    return kOSD_Result_Ok;
}

FrameBlendState_t FrameBlend_GetState(void)
{
    return _Ctx.eCurrentState;
}

OSD_Result_t FrameBlend_ApplySetting(SettingValue_t const *const pValue)
{
    if (pValue == NULL)
    {
        return kOSD_Result_Err_NullDataPtr;
    }

    if (pValue->eType == kSettingDataType_U8)
    {
        const FrameBlendState_t eState = (pValue->U8 == 0) ? kFrameBlendState_Off: kFrameBlendState_On;
        _Ctx.eCurrentState = eState;
    }
    else
    {
        return kOSD_Result_Err_UnexpectedSettingDataType;
    }

    return kOSD_Result_Ok;
}

void FrameBlend_RegisterOnUpdateCb(fnOnUpdateCb_t fnOnUpdate)
{
    _Ctx.fnOnUpdateCb = fnOnUpdate;
}

static void SaveToSettings(const uint8_t eNewState)
{
    OSD_Result_t eResult;
    if ((eResult = Settings_Update(kSettingKey_FrameBlend, eNewState)) != kOSD_Result_Ok)
    {
        ESP_LOGE(TAG, "Frame blend save failed: %d", eResult);
    }
}
