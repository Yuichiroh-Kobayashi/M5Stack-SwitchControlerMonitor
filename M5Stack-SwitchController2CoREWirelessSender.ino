#include <M5Unified.h>
// Do not include <Usb.h> directly: on Windows it can resolve case-insensitively
// to ESP32 core's USB.h. usbhub.h includes USB Host Shield's local "Usb.h".
#include <usbhub.h>
#include <hiduniversal.h>
#include <esp_system.h>

#ifndef USB_HID_RAW_LOG
#define USB_HID_RAW_LOG 0
#endif

#ifndef USB_TEST_DURATION_MS
#define USB_TEST_DURATION_MS 0
#endif

#ifndef USB_MODULE_SS_CH
#define USB_MODULE_SS_CH 1
#endif

#ifndef USB_MODULE_INT_CH
#define USB_MODULE_INT_CH 1
#endif

#ifndef USB_HOST_SHIELD_SS_GPIO
#define USB_HOST_SHIELD_SS_GPIO 19
#endif

#ifndef USB_HOST_SHIELD_INT_GPIO
#define USB_HOST_SHIELD_INT_GPIO 35
#endif

#ifndef SERIAL2_RX_PIN
#if defined(BUILD_TARGET_CORES3SE)
// M5Unified CoreS3 SE Port C definition: pin 1=RX(GPIO18), pin 2=TX(GPIO17).
#define SERIAL2_RX_PIN 18
#define SERIAL2_TX_PIN 17
#elif defined(ARDUINO_M5STACK_CORE2) || defined(ARDUINO_M5STACK_Core2)
#define SERIAL2_RX_PIN 13
#define SERIAL2_TX_PIN 14
#else
#define SERIAL2_RX_PIN 16
#define SERIAL2_TX_PIN 17
#endif
#endif

// USB Host global objects
USB Usb;
USBHub Hub(&Usb);
class DiagnosticHIDUniversal : public HIDUniversal {
public:
    explicit DiagnosticHIDUniversal(USB* usb) : HIDUniversal(usb) {}
    uint16_t vid() const { return VID; }
    uint16_t pid() const { return PID; }
};
DiagnosticHIDUniversal Hid(&Usb);
char lastTxData[21] = "00,00,00,80,80,80,80";
M5Canvas uiCanvas(&M5.Display);
bool uiCanvasReady = false;

struct BatteryStatus {
    int level = -1;
    uint32_t lastUpdateMs = 0;
} batteryStatus;

const char* boardName() {
#if defined(BUILD_TARGET_CORES3SE)
    return "M5 CoreS3 SE";
#elif defined(ARDUINO_M5STACK_CORE2) || defined(ARDUINO_M5STACK_Core2)
    return "M5Stack Core2";
#else
    return "M5Stack Core";
#endif
}

// Data structure to hold controller state
struct ControllerState {
    uint8_t raw[64];
    uint8_t rawLen;

    bool btnA, btnB, btnX, btnY;
    bool btnL, btnR, btnZL, btnZR;
    bool btnMinus, btnPlus, btnHome, btnCapture;
    bool btnLStick, btnRStick;
    uint8_t dpad;  // Hat switch value (0-7, 8=center)
    uint8_t lX, lY;
    uint8_t rX, rY;
} padState;

struct UsbDiagnostics {
    uint32_t testStartMs = 0;
    uint32_t lastSummaryMs = 0;
    uint32_t lastHidSnapshot = 0;
    uint32_t hidReportTotal = 0;
    uint32_t hidReportDelta = 0;
    uint32_t lastHidMs = 0;
    uint32_t usbTaskCount = 0;
    uint32_t lastUsbTaskSnapshot = 0;
    uint32_t usbTaskPerSec = 0;
    uint32_t lastUsbServiceUs = 0;
    uint32_t maxUsbTaskUs = 0;
    uint32_t maxUsbGapUs = 0;
    uint32_t dropMs = 0;
    uint32_t stopMs = 0;
    uint8_t previousState = USB_STATE_DETACHED;
    bool previousHidReady = false;
    bool everRunning = false;
    bool everHidReady = false;
    bool dropDetected = false;
    bool testStopped = false;
} usbDiagnostics;

// HID report parser implementation
class ControllerParser : public HIDReportParser {
public:
    void Parse(USBHID* hid, bool is_rpt_id, uint8_t len, uint8_t* buf) override {
        (void)hid;
        (void)is_rpt_id;

        if (len > 64) len = 64;
        ++usbDiagnostics.hidReportTotal;
        usbDiagnostics.lastHidMs = millis();
#if USB_HID_RAW_LOG
        Serial.printf("HID_RAW LEN=%u DATA=", len);
        for (uint8_t index = 0; index < len; ++index) {
            Serial.printf("%02X", buf[index]);
            if (index + 1 < len) Serial.print(' ');
        }
        Serial.println();
#endif
        memcpy(padState.raw, buf, len);
        padState.rawLen = len;

        if (len < 7) return;

        padState.btnY = (buf[0] & 0x01);
        padState.btnB = (buf[0] & 0x02);
        padState.btnA = (buf[0] & 0x04);
        padState.btnX = (buf[0] & 0x08);
        padState.btnL = (buf[0] & 0x10);
        padState.btnR = (buf[0] & 0x20);
        padState.btnZL = (buf[0] & 0x40);
        padState.btnZR = (buf[0] & 0x80);

        padState.btnMinus = (buf[1] & 0x01);
        padState.btnPlus = (buf[1] & 0x02);
        padState.btnLStick = (buf[1] & 0x04);
        padState.btnRStick = (buf[1] & 0x08);
        padState.btnHome = (buf[1] & 0x10);
        padState.btnCapture = (buf[1] & 0x20);

        padState.dpad = buf[2] & 0x0F;
        padState.lX = buf[3];
        padState.lY = buf[4];
        padState.rX = buf[5];
        padState.rY = buf[6];
    }
} parser;

// Communication and UI update intervals
unsigned long lastSendTime = 0;
unsigned long lastDraw = 0;
unsigned long lastDebugPoll = 0;
const unsigned long SEND_INTERVAL_MS = 200;
const unsigned long DRAW_INTERVAL_MS = 33;
const unsigned long DEBUG_POLL_INTERVAL_MS = 200;
const int16_t UI_TOP_Y = 15;
const uint32_t BATTERY_UPDATE_INTERVAL_MS = 10000;
const int16_t BATTERY_TEXT_X = 190;
const int16_t BATTERY_TEXT_Y = 215;

uint8_t usbTaskState = USB_STATE_DETACHED;
int usbIntLevel = -1;
uint8_t max3421Revision = 0;

const char* resetReasonText() {
    switch (esp_reset_reason()) {
        case ESP_RST_POWERON: return "POWERON";
        case ESP_RST_SW: return "SOFTWARE";
        case ESP_RST_PANIC: return "PANIC";
        case ESP_RST_INT_WDT:
        case ESP_RST_TASK_WDT:
        case ESP_RST_WDT: return "WDT";
        case ESP_RST_BROWNOUT: return "BROWNOUT";
        case ESP_RST_USB: return "USB";
        default: return "OTHER";
    }
}

void stopWithResult(const char* result) {
    Serial.printf("TEST_RESULT=%s\n", result);
    Serial.flush();
    while (true) delay(1000);
}

void resetPadState() {
    memset(&padState, 0, sizeof(padState));
    padState.dpad = 8;
    padState.lX = 0x80;
    padState.lY = 0x80;
    padState.rX = 0x80;
    padState.rY = 0x80;
}

void setup() {
    auto cfg = M5.config();
    M5.begin(cfg);
    Serial.begin(115200);
    delay(1500);

    resetPadState();

    M5.Display.setRotation(1);
    uiCanvas.setColorDepth(8);
    uiCanvasReady = uiCanvas.createSprite(
        M5.Display.width(), M5.Display.height() - UI_TOP_Y) != nullptr;
    if (uiCanvasReady) {
        uiCanvas.setTextSize(1);
    }

    M5.Display.setTextSize(2);
    M5.Display.println("M5 Switch2CoRE Sender");
    M5.Display.setTextSize(1);
    M5.Display.printf("Board: %s\n", boardName());
    M5.Display.println("Boot mode: USB Host");
    Serial.println("Boot mode: USB Host");
    M5.Display.println("Init USB Host...");
    M5.Display.printf("DIP: SS CH%d(GPIO%d) / INT CH%d(GPIO%d)\n",
                      USB_MODULE_SS_CH, USB_HOST_SHIELD_SS_GPIO,
                      USB_MODULE_INT_CH, USB_HOST_SHIELD_INT_GPIO);

    if (Usb.Init() == -1) {
        M5.Display.setTextColor(RED);
        M5.Display.println("OSC did not start.");
        Serial.println("OSC did not start.");
        stopWithResult("OSC_INIT_FAILED");
    }
    M5.Display.setTextColor(GREEN);
    M5.Display.println("USB Host Init OK");
    Serial.println("USB Host Init OK");
    M5.Display.setTextColor(WHITE);

    if (!Hid.SetReportParser(0, &parser)) {
        M5.Display.println("SetReportParser Error");
        Serial.println("SetReportParser Error");
        stopWithResult("SET_REPORT_PARSER_ERROR");
    }

    Serial2.begin(115200, SERIAL_8N1, SERIAL2_RX_PIN, SERIAL2_TX_PIN);
    M5.Display.printf("Serial2 Started (115200) RX:%d TX:%d\n", SERIAL2_RX_PIN,
                      SERIAL2_TX_PIN);
    M5.Display.println("Waiting for 5 seconds...");
    delay(5000);
    usbTaskState = Usb.getUsbTaskState();
    usbDiagnostics.previousState = usbTaskState;
    usbDiagnostics.previousHidReady = Hid.isReady();
    usbDiagnostics.testStartMs = millis();
    usbDiagnostics.lastSummaryMs = usbDiagnostics.testStartMs;
    Serial.printf("WIRELESS_SENDER_TEST_START RAW_LOG=%d DURATION_MS=%lu RESET_REASON=%s\n",
                  USB_HID_RAW_LOG, (unsigned long)USB_TEST_DURATION_MS,
                  resetReasonText());
}

uint16_t getBatteryTextColor(int level);

template <typename DisplayType>
void drawBatteryStatus(DisplayType& target, int16_t yOffset) {
    char batteryText[11];
    if (batteryStatus.level < 0) {
        snprintf(batteryText, sizeof(batteryText), "BAT:  --%%");
    } else {
        snprintf(batteryText, sizeof(batteryText), "BAT: %3d%%", batteryStatus.level);
    }

    target.setTextSize(1);
    target.setCursor(BATTERY_TEXT_X, BATTERY_TEXT_Y - yOffset);
    target.setTextColor(getBatteryTextColor(batteryStatus.level), BLACK);
    target.print(batteryText);
    target.setTextColor(WHITE, BLACK);
}

template <typename DisplayType>
void drawControllerInfoTo(DisplayType& target, int16_t yOffset) {
    const int16_t textY = UI_TOP_Y - yOffset;

    target.setCursor(0, textY);
    target.printf("ST:%02X INT:%d REV:%02X\n", usbTaskState, usbIntLevel,
                  max3421Revision);

    target.setCursor(0, 30 - yOffset);
    target.setTextColor(YELLOW);
    target.print("RAW: ");
    for (int i = 0; i < 8 && i < padState.rawLen; i++) {
        target.printf("%02X ", padState.raw[i]);
    }
    target.println();
    target.setTextColor(WHITE);

    target.setCursor(0, 50 - yOffset);
    target.printf("A:%d B:%d X:%d Y:%d\n", padState.btnA, padState.btnB,
                  padState.btnX, padState.btnY);
    target.printf("L:%d R:%d ZL:%d ZR:%d\n", padState.btnL, padState.btnR,
                  padState.btnZL, padState.btnZR);
    target.printf("-:%d +:%d H:%d C:%d\n", padState.btnMinus,
                  padState.btnPlus, padState.btnHome, padState.btnCapture);

    const char* dpadStr = "CENTER";
    int dx = 0, dy = 0;
    switch (padState.dpad) {
        case 0:
            dpadStr = "UP";
            dy = -1;
            break;
        case 1:
            dpadStr = "UP-R";
            dx = 1;
            dy = -1;
            break;
        case 2:
            dpadStr = "RIGHT";
            dx = 1;
            break;
        case 3:
            dpadStr = "DW-R";
            dx = 1;
            dy = 1;
            break;
        case 4:
            dpadStr = "DOWN";
            dy = 1;
            break;
        case 5:
            dpadStr = "DW-L";
            dx = -1;
            dy = 1;
            break;
        case 6:
            dpadStr = "LEFT";
            dx = -1;
            break;
        case 7:
            dpadStr = "UP-L";
            dx = -1;
            dy = -1;
            break;
        default:
            break;
    }
    target.printf("LS:%d RS:%d DP:%s\n", padState.btnLStick,
                  padState.btnRStick, dpadStr);

    target.setCursor(0, 100 - yOffset);
    target.printf("L Stick: X=%3d Y=%3d\n", padState.lX, padState.lY);
    target.printf("R Stick: X=%3d Y=%3d\n", padState.rX, padState.rY);

    int cx = 60, cy = 160 - yOffset, r = 25;
    target.drawRect(cx - r, cy - r, r * 2, r * 2, DARKGREY);
    int lx = map(padState.lX, 0, 255, -r, r);
    int ly = map(padState.lY, 0, 255, -r, r);
    target.fillCircle(cx + lx, cy + ly, 4, GREEN);
    target.setCursor(cx - 10, cy + r + 5);
    target.print("LS");

    cx = 160;
    target.drawRect(cx - r, cy - r, r * 2, r * 2, DARKGREY);
    int rx = map(padState.rX, 0, 255, -r, r);
    int ry = map(padState.rY, 0, 255, -r, r);
    target.fillCircle(cx + rx, cy + ry, 4, GREEN);
    target.setCursor(cx - 10, cy + r + 5);
    target.print("RS");

    cx = 260;
    target.drawRect(cx - r, cy - r, r * 2, r * 2, DARKGREY);
    target.drawLine(cx - r, cy, cx + r, cy, DARKGREY);
    target.drawLine(cx, cy - r, cx, cy + r, DARKGREY);

    if (padState.dpad != 8) {
        target.fillCircle(cx + (dx * 15), cy + (dy * 15), 6, YELLOW);
    } else {
        target.fillCircle(cx, cy, 4, DARKGREY);
    }
    target.setCursor(cx - 15, cy + r + 5);
    target.print("DPAD");

    target.setCursor(0, 215 - yOffset);
    target.setTextColor(CYAN);
    target.printf("TX: %s", lastTxData);
    target.setTextColor(WHITE);
    drawBatteryStatus(target, yOffset);
}

void drawControllerInfo() {
    if (uiCanvasReady) {
        uiCanvas.fillSprite(BLACK);
        drawControllerInfoTo(uiCanvas, UI_TOP_Y);
        uiCanvas.pushSprite(0, UI_TOP_Y);
    } else {
        M5.Display.fillRect(0, UI_TOP_Y, M5.Display.width(),
                            M5.Display.height() - UI_TOP_Y, BLACK);
        drawControllerInfoTo(M5.Display, 0);
    }
}

void sendControllerState() {
    while (Serial2.available()) {
        Serial2.read();
    }

    uint8_t byte0 = 0;
    if (padState.btnA) byte0 |= 0x01;
    if (padState.btnB) byte0 |= 0x02;
    if (padState.btnX) byte0 |= 0x04;
    if (padState.btnY) byte0 |= 0x08;
    if (padState.btnL) byte0 |= 0x10;
    if (padState.btnR) byte0 |= 0x20;
    if (padState.btnZL) byte0 |= 0x40;
    if (padState.btnZR) byte0 |= 0x80;

    uint8_t byte1 = 0;
    if (padState.btnMinus) byte1 |= 0x01;
    if (padState.btnPlus) byte1 |= 0x02;
    if (padState.btnHome) byte1 |= 0x04;
    if (padState.btnCapture) byte1 |= 0x08;
    if (padState.btnLStick) byte1 |= 0x10;
    if (padState.btnRStick) byte1 |= 0x20;

    uint8_t byte2 = 0;
    if (padState.dpad == 0x0F || padState.dpad == 8) {
        byte2 = 0;
    } else {
        byte2 = (padState.dpad & 0x0F) + 1;
    }

    snprintf(lastTxData, sizeof(lastTxData), "%02X,%02X,%02X,%02X,%02X,%02X,%02X", byte0,
             byte1, byte2, padState.lX, padState.lY, padState.rX, padState.rY);
    Serial2.print(lastTxData);
    Serial2.print("\r\n");
}

void updateBatteryStatus() {
    const uint32_t now = millis();
    if (batteryStatus.lastUpdateMs != 0 &&
        now - batteryStatus.lastUpdateMs < BATTERY_UPDATE_INTERVAL_MS) {
        return;
    }

    batteryStatus.lastUpdateMs = now;
    const int level = M5.Power.getBatteryLevel();
    batteryStatus.level = (level >= 0 && level <= 100) ? level : -1;
}

uint16_t getBatteryTextColor(int level) {
    if (level >= 51) return WHITE;
    if (level >= 26) return YELLOW;
    if (level >= 0) return RED;
    return WHITE;
}

void serviceUsbTaskWithDiagnostics() {
    const uint8_t stateBefore = Usb.getUsbTaskState();
    const bool hidBefore = Hid.isReady();
    const uint16_t vidBefore = hidBefore ? Hid.vid() : 0;
    const uint16_t pidBefore = hidBefore ? Hid.pid() : 0;
    const uint32_t startUs = micros();
    if (usbDiagnostics.lastUsbServiceUs != 0) {
        const uint32_t gapUs = startUs - usbDiagnostics.lastUsbServiceUs;
        if (gapUs > usbDiagnostics.maxUsbGapUs) usbDiagnostics.maxUsbGapUs = gapUs;
    }
    usbDiagnostics.lastUsbServiceUs = startUs;
    Usb.Task();
    const uint32_t durationUs = micros() - startUs;
    if (durationUs > usbDiagnostics.maxUsbTaskUs) usbDiagnostics.maxUsbTaskUs = durationUs;
    ++usbDiagnostics.usbTaskCount;

    const uint8_t stateAfter = Usb.getUsbTaskState();
    const bool hidAfter = Hid.isReady();
    const uint16_t vidAfter = hidAfter ? Hid.vid() : 0;
    const uint16_t pidAfter = hidAfter ? Hid.pid() : 0;
    usbTaskState = stateAfter;
    if (stateAfter == USB_STATE_RUNNING) usbDiagnostics.everRunning = true;
    if (hidAfter) usbDiagnostics.everHidReady = true;

    if (durationUs > 20000) {
        Serial.printf("USB_TASK_SLOW DURATION_US=%lu STATE_BEFORE=%02X STATE_AFTER=%02X "
                      "HID_BEFORE=%u HID_AFTER=%u VID_BEFORE=%04X PID_BEFORE=%04X "
                      "VID_AFTER=%04X PID_AFTER=%04X\n",
                      (unsigned long)durationUs, stateBefore, stateAfter,
                      hidBefore, hidAfter, vidBefore, pidBefore, vidAfter, pidAfter);
        if (durationUs > 100000) {
            const uint8_t revision = Usb.regRd(rREVISION);
            const uint8_t hrsl = Usb.regRd(rHRSL);
            const uint8_t mode = Usb.regRd(rMODE);
            const uint8_t hctl = Usb.regRd(rHCTL);
            const uint8_t hirq = Usb.regRd(rHIRQ);
            const uint8_t usbirq = Usb.regRd(rUSBIRQ);
            const uint8_t pinctl = Usb.regRd(rPINCTL);
            Serial.printf("USB_TASK_SLOW_SNAPSHOT REV=%02X HRSL=%02X MODE=%02X HCTL=%02X "
                          "HIRQ=%02X USBIRQ=%02X PINCTL=%02X\n",
                          revision, hrsl, mode, hctl, hirq, usbirq, pinctl);
        }
    }

    if (stateAfter != usbDiagnostics.previousState) {
        Serial.printf("USB_STATE_TRANSITION=%02X->%02X MILLIS=%lu MICROS=%lu\n",
                      usbDiagnostics.previousState, stateAfter,
                      (unsigned long)millis(), (unsigned long)micros());
        if (usbDiagnostics.previousState == USB_STATE_RUNNING &&
            stateAfter == USB_DETACHED_SUBSTATE_WAIT_FOR_DEVICE &&
            !usbDiagnostics.dropDetected) {
            usbDiagnostics.dropDetected = true;
            usbDiagnostics.dropMs = millis();
            usbDiagnostics.stopMs = usbDiagnostics.dropMs + 30000;
        }
        usbDiagnostics.previousState = stateAfter;
    }
    usbDiagnostics.previousHidReady = hidAfter;
}

void printUsbSummary(uint32_t now) {
    const uint32_t elapsedMs = now - usbDiagnostics.lastSummaryMs;
    if (elapsedMs == 0) return;
    usbDiagnostics.hidReportDelta =
        usbDiagnostics.hidReportTotal - usbDiagnostics.lastHidSnapshot;
    usbDiagnostics.usbTaskPerSec =
        ((usbDiagnostics.usbTaskCount - usbDiagnostics.lastUsbTaskSnapshot) * 1000UL) /
        elapsedMs;
    usbDiagnostics.lastHidSnapshot = usbDiagnostics.hidReportTotal;
    usbDiagnostics.lastUsbTaskSnapshot = usbDiagnostics.usbTaskCount;
    usbDiagnostics.lastSummaryMs = now;
    const bool hidReady = Hid.isReady();
    const uint16_t vid = hidReady ? Hid.vid() : 0;
    const uint16_t pid = hidReady ? Hid.pid() : 0;
    Serial.printf("USB_SUMMARY UPTIME_MS=%lu USB_STATE=%02X HID_READY=%u VID=%04X PID=%04X "
                  "HID_REPORT_TOTAL=%lu HID_REPORT_DELTA=%lu USB_TASK_PER_SEC=%lu "
                  "MAX_USB_TASK_US=%lu MAX_USB_GAP_US=%lu RESET_REASON=%s\n",
                  (unsigned long)(now - usbDiagnostics.testStartMs), usbTaskState,
                  hidReady, vid, pid,
                  (unsigned long)usbDiagnostics.hidReportTotal,
                  (unsigned long)usbDiagnostics.hidReportDelta,
                  (unsigned long)usbDiagnostics.usbTaskPerSec,
                  (unsigned long)usbDiagnostics.maxUsbTaskUs,
                  (unsigned long)usbDiagnostics.maxUsbGapUs,
                  resetReasonText());
}

void finishUsbTest(uint32_t now, bool durationReached) {
    if (usbDiagnostics.testStopped) return;
    const bool hidReady = Hid.isReady();
    const bool passed = durationReached && !usbDiagnostics.dropDetected &&
        usbDiagnostics.everRunning && usbDiagnostics.everHidReady && hidReady &&
        usbTaskState == USB_STATE_RUNNING && usbDiagnostics.hidReportTotal > 0;
    usbDiagnostics.testStopped = true;
    const uint16_t vid = hidReady ? Hid.vid() : 0;
    const uint16_t pid = hidReady ? Hid.pid() : 0;
    const uint32_t lastHidAgeMs = usbDiagnostics.lastHidMs == 0
        ? 0xFFFFFFFFUL : now - usbDiagnostics.lastHidMs;
    Serial.printf("TEST_COMPLETE=%s DURATION_MS=%lu DROP_TIME_MS=%lu USB_STATE=%02X "
                  "HID_READY=%u VID=%04X PID=%04X HID_REPORT_TOTAL=%lu "
                  "LAST_HID_AGE_MS=%lu MAX_USB_TASK_US=%lu MAX_USB_GAP_US=%lu\n",
                  passed ? "PASS" : "FAIL",
                  (unsigned long)(now - usbDiagnostics.testStartMs),
                  usbDiagnostics.dropDetected
                      ? (unsigned long)(usbDiagnostics.dropMs - usbDiagnostics.testStartMs)
                      : 0UL,
                  usbTaskState, hidReady, vid, pid,
                  (unsigned long)usbDiagnostics.hidReportTotal,
                  (unsigned long)lastHidAgeMs,
                  (unsigned long)usbDiagnostics.maxUsbTaskUs,
                  (unsigned long)usbDiagnostics.maxUsbGapUs);
}

void loop() {
    if (usbDiagnostics.testStopped) {
        delay(10);
        return;
    }
    serviceUsbTaskWithDiagnostics();
    M5.update();
    updateBatteryStatus();

    const uint32_t now = millis();
    if (now - usbDiagnostics.lastSummaryMs >= 1000) printUsbSummary(now);

    if (millis() - lastDebugPoll >= DEBUG_POLL_INTERVAL_MS) {
        lastDebugPoll = millis();
        usbTaskState = Usb.getUsbTaskState();
        usbIntLevel = digitalRead(USB_HOST_SHIELD_INT_GPIO);
        max3421Revision = Usb.regRd(rREVISION);
    }

    if (millis() - lastDraw > DRAW_INTERVAL_MS) {
        drawControllerInfo();
        lastDraw = millis();
    }

    if (millis() - lastSendTime >= SEND_INTERVAL_MS) {
        lastSendTime = millis();
        sendControllerState();
    }

    if (usbDiagnostics.dropDetected &&
        static_cast<int32_t>(now - usbDiagnostics.stopMs) >= 0) {
        finishUsbTest(now, false);
    } else if (USB_TEST_DURATION_MS > 0 &&
               now - usbDiagnostics.testStartMs >= USB_TEST_DURATION_MS) {
        finishUsbTest(now, true);
    }
}
