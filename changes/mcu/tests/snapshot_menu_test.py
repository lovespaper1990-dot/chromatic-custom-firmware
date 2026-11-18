"""Exercise the real snapshot page and translation table with sampled button frames."""
from pathlib import Path
import re
import subprocess
import tempfile

mcu = Path(__file__).resolve().parents[1]
components = mcu / "components"
menu = components / "osd/status"

# The page sees the production button enum and snapshot API. Replace only device
# calls and the LVGL surface, retaining exactly the text and width sent to the label.
header = r"""
#pragma once
#include "button.h"
typedef struct { char text[192]; int width, top, space; } lv_obj_t;
typedef enum { kOSD_Result_Ok } OSD_Result_t;
enum { LV_ALIGN_TOP_LEFT };
lv_obj_t *lv_label_create(void *screen);
void lv_obj_set_width(lv_obj_t *obj, int width);
void lv_obj_align(lv_obj_t *obj, int align, int x, int y);
void lv_obj_add_style(lv_obj_t *obj, void *style, int selector);
void lv_obj_set_style_text_line_space(lv_obj_t *obj, int space, int selector);
const char *lv_label_get_text(lv_obj_t *obj);
void lv_label_set_text(lv_obj_t *obj, const char *text);
void lv_obj_del(lv_obj_t *obj);
void *OSD_GetStyleTextWhite(void);
bool OSD_IsVisible(void);
"""
test = r"""
#include "snapshot_menu.h"
#include "snapshot.h"
#include "osd_language.h"
#include <stdio.h>
#include <assert.h>
#include <string.h>
#define KEY(b) (1U << kButton_##b)
static lv_obj_t label;
static bool visible = true, busy, last_load;
static unsigned op = 1, calls, percent;
static const char *idle = "A: Save\nB: Load", *status[4];

lv_obj_t *lv_label_create(void *screen) { (void)screen; return &label; }
void lv_obj_set_width(lv_obj_t *o, int w) { o->width = w; }
void lv_obj_align(lv_obj_t *o, int a, int x, int y) {
    assert(o == &label && a == LV_ALIGN_TOP_LEFT && x >= 77 && y >= 42 && x+o->width <= 145);
    o->top = y;
}
void lv_obj_add_style(lv_obj_t *o, void *s, int selector) {(void)o;(void)s;(void)selector;}
void lv_obj_set_style_text_line_space(lv_obj_t *o, int space, int selector) {o->space=space;(void)selector;}
void lv_obj_del(lv_obj_t *o) { o->text[0]=0; }
const char *lv_label_get_text(lv_obj_t *o) { return o->text; }
void lv_label_set_text(lv_obj_t *o, const char *t) {
    assert(strlen(t) < sizeof o->text); strcpy(o->text,t);
}
void *OSD_GetStyleTextWhite(void) { return NULL; }
bool OSD_IsVisible(void) { return visible; }
bool Snapshot_Busy(void) { return busy; }
unsigned Snapshot_Percent(void) { return percent; }
unsigned Snapshot_OperationSlot(void) { return op; }
const char *Snapshot_StatusForSlot(unsigned n) { assert(n >= 1 && n <= 3); return status[n]; }
bool Snapshot_StartSlot(bool load, unsigned n) {
    assert(!busy && n >= 1 && n <= 3);
    ++calls; busy=true; last_load=load; op=n; status[n]=load ? "Loading..." : "Saving..."; return true;
}
static void frame(unsigned buttons) {
    // OSD_HandleInputs visits enum values in order, then gfx redraws the page.
    for (unsigned b=0; b<kNumButtons; ++b)
        if (buttons & (1u << b)) SnapshotMenu_Button((Button_t)b, kButtonState_Pressed, NULL);
    SnapshotMenu_Draw(&label);
    printf("%d|%d|%d|%d|%s%c", OSD_IsChinese(), label.width, label.top, label.space, label.text, 30);
}
static void slot(unsigned n) {
    char title[40]; snprintf(title, sizeof title, "%s %u/3\n", OSD_Text("Slot"), n);
    assert(!strncmp(title,label.text,strlen(title)));
}
static void confirm(bool pending) { assert((strstr(label.text,OSD_Text("B: Confirm")) != NULL) == pending); }
int main(void) {
    for (unsigned i=1;i<=3;++i) status[i]=idle;
    frame(0); slot(1);
    frame(KEY(Start)|KEY(A)|KEY(B)); slot(2); assert(!calls); confirm(false);
    frame(KEY(Start)); slot(3); frame(KEY(Start)); slot(1);
    frame(KEY(Start)); frame(KEY(A)); slot(2); assert(calls==1 && op==2 && !last_load);
    frame(KEY(Start)|KEY(B)|KEY(A)); slot(2); assert(calls==1);
    busy=false; status[2]="Saved"; frame(0);
    frame(KEY(B)); confirm(true);
    frame(KEY(A)); confirm(false); assert(calls==1);
    frame(KEY(B)); frame(KEY(Start)); slot(3); confirm(false);
    frame(KEY(B)); confirm(true);
    visible=false; frame(KEY(B)); visible=true; frame(0); confirm(false); assert(calls==1);
    frame(KEY(B)); confirm(true); SnapshotMenu_Leave(NULL); frame(0); confirm(false);
    frame(KEY(B)); frame(KEY(B)); assert(calls==2 && last_load && op==3);
    busy=false;
    const char *results[] = {"Saved","Restored","No SD card","Card error","No snapshot",
        "Bad file","Wrong game","Unsupported","FPGA error","FPGA timeout","Busy"};
    for (int lang=0;lang<=1;++lang) {
        OSD_SetChinese(lang);
        // Open at a different slot, then observe progress started from USB.
        SnapshotMenu_Leave(NULL); frame(0); frame(KEY(Start));
        op=3; busy=true;
        for (unsigned load=0;load<=1;++load) {
            status[op]=load ? "Loading..." : "Saving...";
            for(percent=0;percent<=100;++percent) { frame(0); slot(3); }
        }
        busy=false;
        for (unsigned i=0;i<sizeof results/sizeof *results;++i) {
            status[op]=results[i]; frame(0);
            assert(strstr(label.text,OSD_Text(results[i])));
        }
        frame(KEY(B)); confirm(true); frame(KEY(A)); confirm(false);
    }
}
"""
with tempfile.TemporaryDirectory() as temp:
    d = Path(temp)
    (d / "osd_shared.h").write_text(header)
    (d / "osd.h").write_text('#include "osd_shared.h"\n')
    (d / "exercise.c").write_text(test)
    command = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror"]
    for include in (d, menu, components / "common", components / "snapshot", components / "button"):
        command += ["-I", str(include)]
    subprocess.run(command + [str(d / "exercise.c"), str(menu / "snapshot_menu.c"),
                   str(components / "common/osd_language.c"), "-o", str(d / "exercise")], check=True)
    frames = subprocess.check_output([d / "exercise"]).decode().split("\x1e")[:-1]

# Both emitted fonts are unkerned; LVGL rounds their 1/16-pixel advances to pixels.
fonts = components / "fonts"
latin = (fonts / "fingfai.c").read_text()
cjk = (fonts / "osd_cjk.c").read_text()
def advances(font):
    return [(int(width)+8)//16 for width in re.findall(r"\.adv_w\s*=\s*(\d+)", font)]
def line_height(font):
    return int(re.search(r"\.line_height\s*=\s*(\d+)", font)[1])

ascii_width = advances(latin)
width = {chr(i+32): w for i,w in enumerate(ascii_width[1:])}
assert len(width) == 95 and ".kern_dsc = NULL" in latin
start = int(re.search(r"\.range_start\s*=\s*(\d+)", cjk)[1])
relative = re.search(r"codepoints\[\] = \{([^}]+)", cjk)[1]
points = [start+int(n) for n in re.findall(r"\d+",relative)]
cjk_width = advances(cjk)
assert len(points) == len(cjk_width) and ".fallback = &fingfai" in cjk
width.update({chr(cp): w for cp,w in zip(points,cjk_width)})
maxima = [[0,0], [0,0]]
for frame in frames:
    lang,limit,top,space,text = frame.split("|",4)
    lang,limit,top,space = int(lang),int(limit),int(top),int(space)
    lines = text.split("\n")
    w = max(sum(width[char] for char in line) for line in lines)
    h = len(lines) * line_height((latin,cjk)[lang]) + (len(lines)-1)*space
    assert 0 < w <= limit <= 68 and top + h <= 107, (lang,w,h,text)
    maxima[lang] = [max(maxima[lang][0],w), max(maxima[lang][1],h)]
print(f"PASS snapshot menu input, confirmation and busy states; max English {maxima[0]}, Chinese {maxima[1]} px")
