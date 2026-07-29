#include <usbhub.h>
#include <PS5USB.h>
#include <M5Unified.h>
#include <esp_system.h>

#ifndef USB_HOST_SHIELD_SS_GPIO
#define USB_HOST_SHIELD_SS_GPIO 1
#endif

#ifndef USB_HOST_SHIELD_INT_GPIO
#define USB_HOST_SHIELD_INT_GPIO 14
#endif

#ifndef USB_TEST_DURATION_MS
#define USB_TEST_DURATION_MS 600000UL
#endif

#ifndef USB_TARGET_READY_TIMEOUT_MS
#define USB_TARGET_READY_TIMEOUT_MS 15000UL
#endif

#ifndef PS5USB_INIT_OUTPUT
#define PS5USB_INIT_OUTPUT 0
#endif

static_assert(USB_HOST_SHIELD_SS_GPIO == 1,
              "CoreS3 SE USB Module SS must be GPIO1");
static_assert(USB_HOST_SHIELD_INT_GPIO == 14,
              "CoreS3 SE USB Module INT must be GPIO14");
static_assert(PS5USB_INIT_OUTPUT == 0 || PS5USB_INIT_OUTPUT == 1,
              "PS5USB_INIT_OUTPUT must be 0 or 1");

class DiagnosticPS5USB : public PS5USB {
 public:
  explicit DiagnosticPS5USB(USB* usb) : PS5USB(usb) {}

  uint16_t vid() const { return HIDUniversal::VID; }
  uint16_t pid() const { return HIDUniversal::PID; }
  bool hidReady() { return HIDUniversal::isReady(); }
  uint32_t inputReportCount() const { return inputReportCount_; }

 protected:
  void ParseHIDData(USBHID* hid, bool isRptId, uint8_t len,
                    uint8_t* buf) override {
    ++inputReportCount_;
    PS5USB::ParseHIDData(hid, isRptId, len, buf);
  }

 private:
  uint32_t inputReportCount_ = 0;
};

USB Usb;
USBHub Hub(&Usb);
DiagnosticPS5USB Ps5(&Usb);

struct DiagnosticState {
  esp_reset_reason_t resetReason = ESP_RST_UNKNOWN;
  uint32_t testStartMs = 0;
  uint32_t lastSummaryMs = 0;
  uint32_t lastUsbStartUs = 0;
  uint32_t usbTaskCount = 0;
  uint32_t usbTaskCountWindow = 0;
  uint32_t lastInputReportTotal = 0;
  uint32_t dropTimeMs = 0;
  uint32_t postDropDeadlineMs = 0;
  uint32_t maxUsbTaskUs = 0;
  uint32_t maxUsbGapUs = 0;
  uint8_t usbState = 0;
  bool ps5Connected = false;
  bool everConnected = false;
  bool dropDetected = false;
  bool stopped = false;
} state;

void onPs5InitNoOutput() {
  Serial.println("PS5_INIT_CALLBACK=NO_OUTPUT");
}

const char* resetReasonText() {
  switch (state.resetReason) {
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

void releaseUsbChipSelect() {
  digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
}

uint8_t readMaxRegister(uint8_t reg) {
  const uint8_t value = Usb.regRd(reg);
  releaseUsbChipSelect();
  return value;
}

void printMaxSnapshot(const char* reason) {
  const uint8_t revA = readMaxRegister(rREVISION);
  const uint8_t revB = readMaxRegister(rREVISION);
  const uint8_t revC = readMaxRegister(rREVISION);
  const uint8_t hrsl = readMaxRegister(rHRSL);
  const uint8_t mode = readMaxRegister(rMODE);
  const uint8_t hctl = readMaxRegister(rHCTL);
  const uint8_t hirq = readMaxRegister(rHIRQ);
  const uint8_t usbirq = readMaxRegister(rUSBIRQ);
  const uint8_t pinctl = readMaxRegister(rPINCTL);
  Serial.printf(
      "MAX_SNAPSHOT REASON=%s REV_A=%02X REV_B=%02X REV_C=%02X "
      "HRSL=%02X MODE=%02X HCTL=%02X HIRQ=%02X USBIRQ=%02X "
      "PINCTL=%02X INT_GPIO=%d USB_STATE=%02X PS5_CONNECTED=%u "
      "VID=%04X PID=%04X MILLIS=%lu MICROS=%lu\n",
      reason, revA, revB, revC, hrsl, mode, hctl, hirq, usbirq, pinctl,
      digitalRead(USB_HOST_SHIELD_INT_GPIO), Usb.getUsbTaskState(),
      Ps5.connected(), Ps5.vid(), Ps5.pid(), millis(), micros());
}

void serviceUsbTask() {
  const uint32_t startUs = micros();
  if (state.lastUsbStartUs != 0) {
    const uint32_t gapUs = startUs - state.lastUsbStartUs;
    if (gapUs > state.maxUsbGapUs) state.maxUsbGapUs = gapUs;
  }
  state.lastUsbStartUs = startUs;

  const uint8_t stateBefore = Usb.getUsbTaskState();
  const bool hidBefore = Ps5.hidReady();
  const uint16_t vidBefore = Ps5.vid();
  const uint16_t pidBefore = Ps5.pid();

  Usb.Task();

  const uint32_t elapsedUs = micros() - startUs;
  if (elapsedUs > state.maxUsbTaskUs) state.maxUsbTaskUs = elapsedUs;
  ++state.usbTaskCount;

  const uint8_t stateAfter = Usb.getUsbTaskState();
  const bool hidAfter = Ps5.hidReady();
  const uint16_t vidAfter = Ps5.vid();
  const uint16_t pidAfter = Ps5.pid();

  if (elapsedUs > 20000UL) {
    Serial.printf(
        "USB_TASK_SLOW DURATION_US=%lu STATE_BEFORE=%02X STATE_AFTER=%02X "
        "HID_BEFORE=%u HID_AFTER=%u VID_BEFORE=%04X PID_BEFORE=%04X "
        "VID_AFTER=%04X PID_AFTER=%04X\n",
        elapsedUs, stateBefore, stateAfter, hidBefore, hidAfter,
        vidBefore, pidBefore, vidAfter, pidAfter);
    if (elapsedUs > 100000UL) printMaxSnapshot("USB_TASK_SLOW");
  }
}

void updateUsbState(uint32_t now) {
  const uint8_t previousState = state.usbState;
  const bool previousConnected = state.ps5Connected;
  const uint8_t currentState = Usb.getUsbTaskState();
  const bool currentConnected = Ps5.connected();
  const bool leftRunning = previousState == USB_STATE_RUNNING &&
                           currentState != USB_STATE_RUNNING;
  const bool lostTarget = previousConnected && !currentConnected;

  if (currentState != previousState) {
    Serial.printf("USB_STATE_TRANSITION=%02X->%02X MILLIS=%lu MICROS=%lu\n",
                  previousState, currentState, now, micros());
    if (previousState == USB_STATE_RUNNING &&
        currentState == USB_DETACHED_SUBSTATE_WAIT_FOR_DEVICE) {
      printMaxSnapshot("USB_STATE_90_TO_12");
    }
  }

  if (!state.dropDetected && (leftRunning || lostTarget)) {
    state.dropDetected = true;
    state.dropTimeMs = now - state.testStartMs;
    state.postDropDeadlineMs = now + 30000UL;
    const char* reason = leftRunning && lostTarget
                             ? "BOTH"
                             : (leftRunning ? "LEFT_RUNNING" : "LOST_TARGET");
    Serial.println("PS5_DROP");
    Serial.printf("REASON=%s\n", reason);
    Serial.printf("STATE_BEFORE=%02X\n", previousState);
    Serial.printf("STATE_AFTER=%02X\n", currentState);
    Serial.printf("CONNECTED_BEFORE=%u\n", previousConnected);
    Serial.printf("CONNECTED_AFTER=%u\n", currentConnected);
    Serial.printf("DROP_TIME_MS=%lu\n", state.dropTimeMs);
    printMaxSnapshot("PS5_DROP");
  }

  state.usbState = currentState;
  state.ps5Connected = currentConnected;
  if (currentConnected) state.everConnected = true;
}

void logSummary(uint32_t now) {
  if (now - state.lastSummaryMs < 1000UL) return;
  const uint32_t elapsedMs = now - state.lastSummaryMs;
  state.lastSummaryMs = now;
  const uint32_t reports = Ps5.inputReportCount();
  const uint32_t reportDelta = reports - state.lastInputReportTotal;
  state.lastInputReportTotal = reports;
  const uint32_t taskDelta = state.usbTaskCount - state.usbTaskCountWindow;
  state.usbTaskCountWindow = state.usbTaskCount;
  const uint32_t tasksPerSecond =
      elapsedMs > 0 ? static_cast<uint32_t>((taskDelta * 1000ULL) / elapsedMs)
                    : 0;

  Serial.printf(
      "PS5_DIAG UPTIME=%lu USB_STATE=%02X PS5_CONNECTED=%u HID_READY=%u "
      "VID=%04X PID=%04X INPUT_REPORT_COUNT=%lu INPUT_REPORT_DELTA=%lu "
      "USB_TASK_PER_SEC=%lu MAX_USB_TASK_US=%lu MAX_USB_GAP_US=%lu "
      "MAX_REV=%02X DROP_TIME=%lu RESET_REASON=%s\n",
      now - state.testStartMs, state.usbState, state.ps5Connected,
      Ps5.hidReady(), Ps5.vid(), Ps5.pid(), reports, reportDelta,
      tasksPerSecond, state.maxUsbTaskUs, state.maxUsbGapUs,
      readMaxRegister(rREVISION), state.dropTimeMs, resetReasonText());
}

void stopTest(const char* result, uint32_t now) {
  Serial.printf(
      "TEST_COMPLETE=%s DURATION_MS=%lu DROP_TIME_MS=%lu USB_STATE=%02X "
      "PS5_CONNECTED=%u HID_READY=%u VID=%04X PID=%04X "
      "INPUT_REPORT_COUNT=%lu MAX_USB_TASK_US=%lu MAX_USB_GAP_US=%lu "
      "RESET_REASON=%s\n",
      result, now - state.testStartMs, state.dropTimeMs, state.usbState,
      state.ps5Connected, Ps5.hidReady(), Ps5.vid(), Ps5.pid(),
      Ps5.inputReportCount(), state.maxUsbTaskUs, state.maxUsbGapUs,
      resetReasonText());
  state.stopped = true;
}

void setup() {
  auto cfg = M5.config();
  cfg.internal_spk = false;
  cfg.internal_mic = false;
  M5.begin(cfg);

  Serial.begin(115200);
  delay(1500);

  pinMode(USB_HOST_SHIELD_SS_GPIO, OUTPUT);
  digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
  pinMode(USB_HOST_SHIELD_INT_GPIO, INPUT_PULLUP);

  state.resetReason = esp_reset_reason();
  Serial.printf(
      "PS5_USB_DIAGNOSTIC_START DRIVER=PS5USB DURATION_MS=%lu "
      "TARGET_READY_TIMEOUT_MS=%lu RESET_REASON=%s\n",
      static_cast<uint32_t>(USB_TEST_DURATION_MS),
      static_cast<uint32_t>(USB_TARGET_READY_TIMEOUT_MS), resetReasonText());
#if PS5USB_INIT_OUTPUT == 0
  Serial.println("PS5_INIT_OUTPUT=NO_OUTPUT");
  Ps5.attachOnInit(onPs5InitNoOutput);
#else
  Serial.println("PS5_INIT_OUTPUT=DEFAULT");
#endif
  Serial.println("USB_INIT_BEGIN");
  const int initResult = Usb.Init();
  releaseUsbChipSelect();
  Serial.printf("USB_INIT_END RESULT=%d MAX_REV=%02X\n", initResult,
                readMaxRegister(rREVISION));
  if (initResult == -1) {
    Serial.println("TEST_RESULT=OSC_INIT_FAILED");
    state.stopped = true;
    return;
  }

  state.testStartMs = millis();
  state.lastSummaryMs = state.testStartMs;
  state.usbState = Usb.getUsbTaskState();
  Serial.printf("USB_INITIAL_STATE=%02X\n", state.usbState);
}

void loop() {
  if (state.stopped) {
    delay(10);
    return;
  }

  serviceUsbTask();
  const uint32_t now = millis();
  updateUsbState(now);
  logSummary(now);

  const uint32_t elapsedMs = now - state.testStartMs;
  if (!state.everConnected &&
      elapsedMs >= static_cast<uint32_t>(USB_TARGET_READY_TIMEOUT_MS)) {
    Serial.printf("TEST_RESULT=NO_TARGET_HID DURATION_MS=%lu\n", elapsedMs);
    state.stopped = true;
    return;
  }

  if (state.dropDetected &&
      static_cast<int32_t>(now - state.postDropDeadlineMs) >= 0) {
    stopTest("FAIL", now);
    return;
  }

  if (elapsedMs >= static_cast<uint32_t>(USB_TEST_DURATION_MS)) {
    const bool passed = state.usbState == USB_STATE_RUNNING &&
                        state.ps5Connected &&
                        Ps5.inputReportCount() > 0 &&
                        !state.dropDetected;
    stopTest(passed ? "PASS" : "FAIL", now);
  }
}
