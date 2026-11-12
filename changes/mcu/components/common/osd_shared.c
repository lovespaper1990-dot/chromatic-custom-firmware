#include "osd_shared.h"
#include "osd_language.h"
#include "color.h"
#include "lvgl.h"

LV_FONT_DECLARE(fingfai);
LV_FONT_DECLARE(jf_dot_k14);
LV_FONT_DECLARE(osd_cjk);

enum { WHITE, GREY, BLACK, LARGE_WHITE, STYLE_COUNT };
static lv_style_t styles[2][STYLE_COUNT];

OSD_Result_t OSD_Common_Init(void)
{
    const uint32_t colors[] = {kColor_White, kColor_Grey, kColor_Black, kColor_White};
    for (size_t lang = 0; lang < 2; lang++) {
        for (size_t i = 0; i < STYLE_COUNT; i++) {
            lv_style_t *style = &styles[lang][i];
            const lv_font_t *font = i == LARGE_WHITE ? &jf_dot_k14 : &fingfai;
            // The large style is reserved for numbers and hardware identifiers.
            if (lang && i != LARGE_WHITE) font = &osd_cjk;
            lv_style_init(style);
            // Keep inactive Chinese labels legible on the black menu background.
            uint32_t color = lang && i == GREY ? 0xAAAAAA : colors[i];
            lv_style_set_text_color(style, lv_color_hex(color));
            lv_style_set_text_font(style, font);
        }
    }
    return kOSD_Result_Ok;
}

lv_style_t* OSD_GetStyleTextWhite(void)
{
    return &styles[OSD_IsChinese()][WHITE];
}

lv_style_t* OSD_GetStyleTextGrey(void)
{
    return &styles[OSD_IsChinese()][GREY];
}

lv_style_t* OSD_GetStyleTextBlack(void)
{
    return &styles[OSD_IsChinese()][BLACK];
}

lv_style_t* OSD_GetStyleTextWhite_L(void)
{
    return &styles[OSD_IsChinese()][LARGE_WHITE];
}
