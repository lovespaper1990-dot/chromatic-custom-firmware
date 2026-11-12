#include "osd_language.h"

#include <stddef.h>
#include <string.h>

static bool chinese;
static const struct {
    const char *english;
    const char *translation;
} messages[] = {
    {"HOME", "主页"},
    {"DISPLAY", "显示"},
    {"CONTROLS", "操作"},
    {"PALETTE", "调色板"},
    {"SYSTEM", "系统"},
    {"LANGUAGE", "语言"},
    {"English", "简体中文"},
    {"A/B: SWITCH", "A/B 切换"},
    {"BRIGHTNESS", "亮度"},
    {"SILENT MODE", "静音"},
    {"FRAME BLEND", "帧混合"},
    {"LCD COLOR CORR.", "屏幕校色"},
    {"STREAMING", "视频输出"},
    {"TRANSITIONS", "画面过渡"},
    {"LOW BATTERY", "低电图标"},
    {"D-PAD", "方向键"},
    {"COLOR TEMP", "色温"},
    {"FIRMWARE", "固件"},
    {"PLAYER #", "玩家编号"},
    {"SERIAL #", "序列号"},
    {"POWER SAVE MODE ON,\nREPLACE BATTERIES.", "省电模式\n请更换电池"},
    {"SYSTEM    INFO", "系统信息"},
    {"OFF", "关"},
    {"ON", "开"},
    {"RAW COLOR", "原始颜色"},
    {"CORRECTED COLOR", "校正颜色"},
    {"CLASSIC", "经典"},
    {"SMOOTH", "平滑"},
    {"ALWAYS SHOW", "常显"},
    {"BLINK", "闪烁"},
    {"HIDE", "隐藏"},
    {"ALLOW ALL DIRECTIONS", "八向"},
    {"IGNORE DIAGONALS", "四向"},
    {"HOT KEYS", "热键"},
    {"PALETTE / COLOR TEMP", "调色板/色温"},
    {"CYCLE PALETTE (GB)", "切换调色板"},
    {"ADJUST COLOR TEMP (GBC)", "调节色温"},
    {"RESET EMULATION", "重启核心"},
    {"MENU + L/R ON DPAD", "菜单+左/右"},
    {"MENU + U/D ON DPAD", "菜单+上/下"},
    {"MENU + B + A + START + SELECT", "菜单+B+A\n+START+SELECT"},
    {"YOUR GAME DOES\nNOT SUPPORT\nCOLOR PALETTES", "游戏不支持\n调色板"},
    {"HOTKEY", "热键"},
    {"STANDBY", "待机"},
    {"HOLD MENU\nTAP TO WAKE", "长按菜单键\n短按唤醒"},
    {"DEFAULT", "默认"},
    {"BROWN", "棕色"},
    {"BLUE", "蓝色"},
    {"PASTEL", "淡彩"},
    {"GREEN", "绿色"},
    {"RED", "红色"},
    {"DARK BLUE", "深蓝"},
    {"ORANGE", "橙色"},
    {"DARK GREEN", "深绿"},
    {"DARK BROWN", "深棕"},
    {"GRAYSCALE", "灰阶"},
    {"YELLOW", "黄色"},
    {"NEGATIVE", "反色"},
    {"DMG1: GAMEBOY", "原机 1"},
    {"DMG2: GAMEBOY", "原机 2"},
    {"NEUTRAL", "中性"},
    {"WARM 1", "暖色 1"},
    {"WARM 2", "暖色 2"},
    {"WARM 3", "暖色 3"},
    {"WARM 4", "暖色 4"},
    {"WARM 5", "暖色 5"},
    {"BLUETOOTH", "蓝牙"},
    {"SCANNING...", "搜索中"},
    {"CONNECTING...", "连接中"},
    {"A: POWER OFF", "A: 关蓝牙"},
    {"A: DISCONNECT", "A: 断开"},
    {"A: CONNECT", "A: 连接"},
    {"A: RECONNECT", "A: 重连"},
    {"A: SCAN", "A: 搜索"},
    {"B: NEXT", "B: 下一项"},
    {"NO HEADSETS", "未找到耳机"},
    {"TRY AGAIN", "请重试"},
    {"SNAPSHOT", "即时存档"},
    {"A: Save\nB: Load", "A: 存档\nB: 读档"},
    {"B: Confirm", "B: 确认"},
    {"Saving...", "存档中"},
    {"Loading...", "读档中"},
    {"Saved", "已存档"},
    {"Restored", "已读档"},
    {"No SD card", "未插卡"},
    {"Card error", "卡出错"},
    {"No snapshot", "无存档"},
    {"Bad file", "文件损坏"},
    {"Wrong game", "游戏不符"},
    {"Unsupported", "不支持"},
    {"FPGA error", "硬件出错"},
    {"FPGA timeout", "硬件超时"},
    {"Busy", "忙碌"},
};

bool OSD_IsChinese(void)
{
    return chinese;
}

void OSD_SetChinese(bool enabled)
{
    chinese = enabled;
}

const char *OSD_Text(const char *english)
{
    if (chinese && english != NULL) {
        for (size_t i = 0; i < sizeof(messages) / sizeof(messages[0]); i++) {
            if (strcmp(english, messages[i].english) == 0)
                return messages[i].translation;
        }
    }
    return english;
}
