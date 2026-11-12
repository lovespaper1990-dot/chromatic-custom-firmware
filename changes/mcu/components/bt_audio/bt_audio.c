// Local A2DP source for the Chromatic's FPGA PCM stream.
#include "bt_audio.h"
#include "esp_a2dp_api.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_gap_bt_api.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/event_groups.h"
#include "freertos/timers.h"
#include <stdio.h>
#include <string.h>

typedef struct {
    esp_bd_addr_t address;
    char name[40];
} Peer;

static portMUX_TYPE lock = portMUX_INITIALIZER_UNLOCKED;
static Peer peers[10];
static Peer selected;
static unsigned count;
static BTState state;
static BTReadPCM pcm;
static void (*notify_route)(void);
static bool streaming;
static bool media_requested;
static StaticTimer_t retry_storage;
static TimerHandle_t retry_timer;
static StaticEventGroup_t event_storage;
static EventGroupHandle_t events;
enum { PROFILE_READY = BIT0, PROFILE_STOPPED = BIT1 };

static void set_state(BTState value)
{
    portENTER_CRITICAL(&lock);
    state = value;
    portEXIT_CRITICAL(&lock);
}

static void retry_media(TimerHandle_t timer)
{
    (void)timer;
    portENTER_CRITICAL(&lock);
    bool retry = state == BT_CONNECTED && media_requested && !streaming;
    portEXIT_CRITICAL(&lock);
    if (retry) esp_a2d_media_ctrl(ESP_A2D_MEDIA_CTRL_CHECK_SRC_RDY);
}

static void set_streaming(bool active)
{
    portENTER_CRITICAL(&lock);
    bool changed = streaming != active;
    streaming = active;
    portEXIT_CRITICAL(&lock);
    if (changed) notify_route();
}

bool BT_IsStreaming(void)
{
    portENTER_CRITICAL(&lock);
    bool active = streaming;
    portEXIT_CRITICAL(&lock);
    return active;
}

void BT_AttachAudio(BTReadPCM read_pcm, void (*route_changed)(void))
{
    pcm = read_pcm;
    notify_route = route_changed;
    retry_timer = xTimerCreateStatic("bt-media", pdMS_TO_TICKS(1000), pdTRUE, NULL, retry_media, &retry_storage);
    events = xEventGroupCreateStatic(&event_storage);
}

bool BT_Busy(void)
{
    return esp_bt_controller_get_status() == ESP_BT_CONTROLLER_STATUS_ENABLED;
}

void BT_GetSelection(unsigned index, BTSelection *view)
{
    portENTER_CRITICAL(&lock);
    view->state = state;
    view->count = count;
    view->name[0] = 0;
    if (state == BT_CONNECTING || state == BT_CONNECTED)
        memcpy(view->name, selected.name, sizeof(view->name));
    else if (index && index <= count)
        memcpy(view->name, peers[index - 1].name, sizeof(view->name));
    portEXIT_CRITICAL(&lock);
    view->powered = BT_Busy();
}

static void discovery_result(esp_bt_gap_cb_param_t *p)
{
    const char *name = NULL;
    uint8_t len = 0;
    uint32_t cod = 0;
    for (int i = 0; i < p->disc_res.num_prop; ++i) {
        esp_bt_gap_dev_prop_t *prop = &p->disc_res.prop[i];
        if (prop->type == ESP_BT_GAP_DEV_PROP_COD && prop->len == sizeof(cod))
            memcpy(&cod, prop->val, sizeof(cod));
        if (prop->type == ESP_BT_GAP_DEV_PROP_BDNAME && prop->len > 0) {
            name = prop->val;
            len = prop->len > 39 ? 39 : prop->len;
        } else if (prop->type == ESP_BT_GAP_DEV_PROP_EIR && !name) {
            name = (const char *)esp_bt_gap_resolve_eir_data(prop->val, ESP_BT_EIR_TYPE_CMPL_LOCAL_NAME, &len);
            if (!name)
                name = (const char *)esp_bt_gap_resolve_eir_data(prop->val, ESP_BT_EIR_TYPE_SHORT_LOCAL_NAME, &len);
        }
    }
    if (cod && esp_bt_gap_get_cod_major_dev(cod) != ESP_BT_COD_MAJOR_DEV_AV &&
        !(esp_bt_gap_get_cod_srvc(cod) & ESP_BT_COD_SRVC_RENDERING)) return;
    Peer entry = {0};
    memcpy(entry.address, p->disc_res.bda, sizeof(entry.address));
    if (name && len) {
        size_t n = len < sizeof(entry.name) ? len : sizeof(entry.name) - 1;
        memcpy(entry.name, name, n);
        entry.name[n] = 0;
    } else {
        snprintf(entry.name, sizeof(entry.name), "%02X:%02X:%02X:%02X:%02X:%02X",
                 entry.address[0], entry.address[1], entry.address[2], entry.address[3], entry.address[4], entry.address[5]);
    }
    portENTER_CRITICAL(&lock);
    unsigned i = 0;
    while (i < count && memcmp(peers[i].address, entry.address, sizeof(entry.address))) ++i;
    if (state == BT_SCANNING && i < sizeof(peers) / sizeof(*peers) && (i == count || name)) {
        peers[i] = entry;
        if (i == count) ++count;
    }
    portEXIT_CRITICAL(&lock);
}

static void gap_event(esp_bt_gap_cb_event_t event, esp_bt_gap_cb_param_t *p)
{
    if (event == ESP_BT_GAP_DISC_RES_EVT) discovery_result(p);
    if (event == ESP_BT_GAP_DISC_STATE_CHANGED_EVT && p->disc_st_chg.state == ESP_BT_GAP_DISCOVERY_STOPPED) {
        portENTER_CRITICAL(&lock);
        if (state == BT_SCANNING) state = BT_IDLE;
        portEXIT_CRITICAL(&lock);
    }
    if (event == ESP_BT_GAP_PIN_REQ_EVT) {
        esp_bt_pin_code_t pin = {'0', '0', '0', '0'};
        portENTER_CRITICAL(&lock);
        bool allow = state == BT_CONNECTING && !memcmp(selected.address, p->pin_req.bda, sizeof(selected.address));
        portEXIT_CRITICAL(&lock);
        bool accept = allow && !p->pin_req.min_16_digit;
        esp_bt_gap_pin_reply(p->pin_req.bda, accept, accept ? 4 : 0, pin);
    }
    if (event == ESP_BT_GAP_CFM_REQ_EVT) {
        portENTER_CRITICAL(&lock);
        bool paired = state == BT_CONNECTING && !memcmp(selected.address, p->cfm_req.bda, sizeof(selected.address));
        portEXIT_CRITICAL(&lock);
        esp_bt_gap_ssp_confirm_reply(p->cfm_req.bda, paired);
    }
}

static void audio_event(esp_a2d_cb_event_t event, esp_a2d_cb_param_t *p)
{
    switch (event) {
    case ESP_A2D_PROF_STATE_EVT:
        xEventGroupSetBits(events, p->a2d_prof_stat.init_state == ESP_A2D_INIT_SUCCESS ? PROFILE_READY : PROFILE_STOPPED);
        break;
    case ESP_A2D_CONNECTION_STATE_EVT:
        if (p->conn_stat.state == ESP_A2D_CONNECTION_STATE_CONNECTED) {
            portENTER_CRITICAL(&lock);
            state = BT_CONNECTED;
            media_requested = true;
            portEXIT_CRITICAL(&lock);
            xTimerStart(retry_timer, 0);
            esp_a2d_media_ctrl(ESP_A2D_MEDIA_CTRL_CHECK_SRC_RDY);
        } else if (p->conn_stat.state == ESP_A2D_CONNECTION_STATE_DISCONNECTED) {
            xTimerStop(retry_timer, 0);
            set_streaming(false);
            set_state(p->conn_stat.disc_rsn == ESP_A2D_DISC_RSN_NORMAL ? BT_IDLE : BT_FAILED);
        }
        break;
    case ESP_A2D_AUDIO_STATE_EVT: {
        bool active = p->audio_stat.state == ESP_A2D_AUDIO_STATE_STARTED;
        portENTER_CRITICAL(&lock);
        media_requested = false; // Respect a subsequent suspend from the headset.
        portEXIT_CRITICAL(&lock);
        set_streaming(active);
        xTimerStop(retry_timer, 0);
        break;
    }
    case ESP_A2D_MEDIA_CTRL_ACK_EVT:
        if (p->media_ctrl_stat.cmd == ESP_A2D_MEDIA_CTRL_CHECK_SRC_RDY &&
            p->media_ctrl_stat.status == ESP_A2D_MEDIA_CTRL_ACK_SUCCESS)
            esp_a2d_media_ctrl(ESP_A2D_MEDIA_CTRL_START);
        break;
    default: break;
    }
}

// Called on the menu task; all Bluedroid callbacks only update state.
void BT_PowerOff(void)
{
    if (xEventGroupGetBits(events) & PROFILE_READY) {
        if (esp_a2d_source_deinit() != ESP_OK ||
            !(xEventGroupWaitBits(events, PROFILE_STOPPED, pdTRUE, pdFALSE, pdMS_TO_TICKS(2000)) & PROFILE_STOPPED)) {
            set_state(BT_FAILED);
            return;
        }
        xEventGroupClearBits(events, PROFILE_READY);
    }
    if ((esp_bluedroid_get_status() == ESP_BLUEDROID_STATUS_ENABLED && esp_bluedroid_disable() != ESP_OK) ||
        (esp_bluedroid_get_status() == ESP_BLUEDROID_STATUS_INITIALIZED && esp_bluedroid_deinit() != ESP_OK) ||
        (esp_bt_controller_get_status() == ESP_BT_CONTROLLER_STATUS_ENABLED && esp_bt_controller_disable() != ESP_OK) ||
        (esp_bt_controller_get_status() == ESP_BT_CONTROLLER_STATUS_INITED && esp_bt_controller_deinit() != ESP_OK)) {
        set_state(BT_FAILED);
        return;
    }
    xTimerStop(retry_timer, 0);
    set_streaming(false);
    portENTER_CRITICAL(&lock);
    count = 0;
    state = BT_IDLE;
    portEXIT_CRITICAL(&lock);
}

static esp_err_t start_radio(void)
{
    if (xEventGroupGetBits(events) & PROFILE_READY) return ESP_OK;
    esp_bt_controller_config_t controller = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    esp_bluedroid_config_t host = BT_BLUEDROID_INIT_CONFIG_DEFAULT();
    esp_err_t e = esp_bt_controller_init(&controller);
    if (e == ESP_OK) e = esp_bt_controller_enable(ESP_BT_MODE_CLASSIC_BT);
    if (e == ESP_OK) e = esp_bluedroid_init_with_cfg(&host);
    if (e == ESP_OK) e = esp_bluedroid_enable();
    if (e == ESP_OK) e = esp_bt_gap_register_callback(gap_event);
    uint8_t io = ESP_BT_IO_CAP_NONE;
    if (e == ESP_OK) e = esp_bt_gap_set_security_param(ESP_BT_SP_IOCAP_MODE, &io, sizeof(io));
    if (e == ESP_OK) e = esp_a2d_register_callback(audio_event);
    if (e == ESP_OK) e = esp_a2d_source_register_data_callback(pcm);
    if (e == ESP_OK) e = esp_a2d_source_init();
    if (e == ESP_OK && !(xEventGroupWaitBits(events, PROFILE_READY, pdFALSE, pdFALSE,
                                             pdMS_TO_TICKS(2000)) & PROFILE_READY)) e = ESP_ERR_TIMEOUT;
    if (e != ESP_OK) {
        ESP_LOGE("Headphones", "Bluetooth initialization: %s", esp_err_to_name(e));
        BT_PowerOff();
    }
    return e;
}

void BT_Scan(void)
{
    portENTER_CRITICAL(&lock);
    count = 0;
    state = BT_SCANNING;
    portEXIT_CRITICAL(&lock);
    if (start_radio() != ESP_OK ||
        esp_bt_gap_start_discovery(ESP_BT_INQ_MODE_GENERAL_INQUIRY, 8, 0) != ESP_OK)
        set_state(BT_FAILED);
}

void BT_Connect(unsigned index)
{
    portENTER_CRITICAL(&lock);
    bool valid = index > 0 && index <= count;
    if (valid) { selected = peers[index - 1]; state = BT_CONNECTING; }
    portEXIT_CRITICAL(&lock);
    if (valid && esp_a2d_source_connect(selected.address) != ESP_OK) set_state(BT_FAILED);
}

void BT_Disconnect(void)
{
    if (esp_a2d_source_disconnect(selected.address) != ESP_OK) set_state(BT_FAILED);
}
