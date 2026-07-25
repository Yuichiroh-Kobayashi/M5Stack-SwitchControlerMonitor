#include <M5Unified.h>
#include <SPI.h>
#include <M5_Ethernet.h>
#include <esp_system.h>

// Do not include <Usb.h> directly: on Windows it can resolve case-insensitively
// to ESP32 core's USB.h. usbhub.h includes USB Host Shield's local "Usb.h".
#include <usbhub.h>
#include <hiduniversal.h>

#if !defined(BUILD_TARGET_CORES3SE)
#error "M5Stack-PS5CoRELanStackDiagnostic.ino supports only the cores3se build target."
#endif

#ifndef USB_MODULE_SS_CH
#define USB_MODULE_SS_CH 2
#endif

#ifndef USB_MODULE_INT_CH
#define USB_MODULE_INT_CH 2
#endif

#ifndef USB_HOST_SHIELD_SS_GPIO
#define USB_HOST_SHIELD_SS_GPIO 1
#endif

#ifndef USB_HOST_SHIELD_INT_GPIO
#define USB_HOST_SHIELD_INT_GPIO 14
#endif

#ifndef PIN_SPI_SCK
#define PIN_SPI_SCK 36
#endif

#ifndef PIN_SPI_MOSI
#define PIN_SPI_MOSI 37
#endif

#ifndef PIN_SPI_MISO
#define PIN_SPI_MISO 35
#endif

namespace DiagnosticConfig {

enum class InitializationOrder : uint8_t {
    UsbThenLan,
    LanThenUsb,
};

enum class DiagnosticMode : uint8_t {
    UsbOnlyWithLanHeldReset,
    LanInitializedNoRuntimeAccess,
    LanLinkStatusOnly,
    FullUdp,
};

// Change these two values independently to select the diagnostic case.
constexpr InitializationOrder kInitializationOrder = InitializationOrder::UsbThenLan;
constexpr DiagnosticMode kDiagnosticMode = DiagnosticMode::FullUdp;

constexpr uint8_t kLanCsPin = 13;     // M5-Bus pin 23 (CSN alternate)
constexpr uint8_t kLanIntPin = 10;    // M5-Bus pin 2
constexpr uint8_t kLanResetPin = 0;   // M5-Bus pin 24

constexpr uint32_t kUdpIntervalMs = 20;
constexpr uint32_t kInputValidWindowMs = 500;
constexpr uint32_t kLinkPollIntervalMs = 250;
constexpr uint32_t kDisplayIntervalMs = 250;
constexpr uint32_t kSerialIntervalMs = 1000;
constexpr uint16_t kLocalUdpPort = 50000;
constexpr uint16_t kDestinationUdpPort = 50000;

const IPAddress kLocalIp(192, 168, 50, 10);
const IPAddress kDns(192, 168, 50, 1);
const IPAddress kGateway(192, 168, 50, 1);
const IPAddress kSubnet(255, 255, 255, 0);
const IPAddress kDestinationIp(192, 168, 50, 20);

uint8_t kMacAddress[6] = {0x02, 0x4D, 0x35, 0x53, 0x45, 0x01};

}  // namespace DiagnosticConfig

using DiagnosticConfig::InitializationOrder;
using DiagnosticConfig::DiagnosticMode;

static_assert(DiagnosticConfig::kLanCsPin != USB_HOST_SHIELD_SS_GPIO,
              "LAN CS conflicts with USB SS");
static_assert(DiagnosticConfig::kLanCsPin != USB_HOST_SHIELD_INT_GPIO,
              "LAN CS conflicts with USB INT");
static_assert(DiagnosticConfig::kLanIntPin != USB_HOST_SHIELD_SS_GPIO,
              "LAN INT conflicts with USB SS");
static_assert(DiagnosticConfig::kLanIntPin != USB_HOST_SHIELD_INT_GPIO,
              "LAN INT conflicts with USB INT");
static_assert(DiagnosticConfig::kLanResetPin != USB_HOST_SHIELD_SS_GPIO,
              "LAN RESET conflicts with USB SS");
static_assert(DiagnosticConfig::kLanResetPin != USB_HOST_SHIELD_INT_GPIO,
              "LAN RESET conflicts with USB INT");
static_assert(DiagnosticConfig::kLanCsPin != DiagnosticConfig::kLanIntPin,
              "LAN CS conflicts with LAN INT");
static_assert(DiagnosticConfig::kLanCsPin != DiagnosticConfig::kLanResetPin,
              "LAN CS conflicts with LAN RESET");
static_assert(DiagnosticConfig::kLanIntPin != DiagnosticConfig::kLanResetPin,
              "LAN INT conflicts with LAN RESET");

struct ControllerState {
    bool btnA, btnB, btnX, btnY;
    bool btnL, btnR, btnZL, btnZR;
    bool btnMinus, btnPlus, btnHome, btnCapture;
    bool btnLStick, btnRStick;
    bool isPs5;
    bool rawHasReportId;
    uint8_t reportId;
    int ps5ButtonOffset;
    uint8_t dpad;
    uint8_t lX, lY;
    uint8_t rX, rY;
    uint8_t raw[64];
    uint8_t rawLen;
};

ControllerState padState;

struct DiagnosticState {
    bool usbInitOk = false;
    bool parserAttached = false;
    bool lanInitAttempted = false;
    bool w5500InitOk = false;
    bool udpSocketReady = false;
    bool hidReady = false;
    bool previousHidReady = false;
    bool hidReadyObserved = false;
    uint8_t usbTaskState = 0;
    uint8_t max3421eRevision = 0;
    uint32_t readyToNotReadyCount = 0;
    EthernetLinkStatus linkStatus = Unknown;
    String configuredIpText = "N/A";
    String actualIpText = "N/A";
    String ipText = "N/A";
    uint64_t hidReportCount = 0;
    uint32_t lastHidReportMs = 0;
    uint32_t udpSentCount = 0;
    uint32_t udpFailedCount = 0;
    uint32_t udpSkippedNoLinkCount = 0;
    uint32_t udpLastBeginUs = 0;
    uint32_t udpLastWriteUs = 0;
    uint32_t udpLastEndUs = 0;
    uint32_t udpLastTotalUs = 0;
    uint32_t udpMaxBeginUs = 0;
    uint32_t udpMaxWriteUs = 0;
    uint32_t udpMaxEndUs = 0;
    uint32_t udpMaxTotalUs = 0;
    uint32_t loopCount = 0;
    uint32_t usbTaskCallCount = 0;
    uint32_t lastLoopRateSampleMs = 0;
    uint32_t lastLoopCountSnapshot = 0;
    uint32_t lastUsbTaskCountSnapshot = 0;
    uint32_t loopsPerSecond = 0;
    uint32_t usbTasksPerSecond = 0;
    uint32_t nextSequence = 0;
    uint32_t lastSequence = 0;
    uint16_t vid = 0;
    uint16_t pid = 0;
    esp_reset_reason_t resetReason = ESP_RST_UNKNOWN;
};

DiagnosticState diagnostic;

bool isPs5ControllerReport(uint8_t* buf, uint8_t len, bool isRptId) {
    (void)isRptId;
    if (len < 10) return false;
    return buf[0] == 0x01 || buf[0] == 0x11;
}

void parsePs5ControllerReport(uint8_t* buf, bool isRptId) {
    padState.isPs5 = true;
    padState.rawHasReportId = isRptId || buf[0] == 0x01 || buf[0] == 0x11;
    padState.reportId = padState.rawHasReportId ? buf[0] : 0;
    padState.ps5ButtonOffset = -1;

    padState.btnA = padState.btnB = padState.btnX = padState.btnY = false;
    padState.btnL = padState.btnR = padState.btnZL = padState.btnZR = false;
    padState.btnMinus = padState.btnPlus = padState.btnHome = padState.btnCapture = false;
    padState.btnLStick = padState.btnRStick = false;
    padState.dpad = 8;

    const int base = 0;
    if (padState.rawLen < base + 10) {
        padState.isPs5 = false;
        return;
    }

    padState.lX = buf[base + 1];
    padState.lY = buf[base + 2];
    padState.rX = buf[base + 3];
    padState.rY = buf[base + 4];
    padState.btnZL = buf[base + 5] != 0;
    padState.btnZR = buf[base + 6] != 0;

    const int buttonOffset = base + 8;
    padState.ps5ButtonOffset = buttonOffset;
    const uint8_t buttons0 = buf[buttonOffset];
    const uint8_t buttons1 = buf[buttonOffset + 1];
    const uint8_t buttons2 =
        (buttonOffset + 2 < padState.rawLen) ? buf[buttonOffset + 2] : 0;

    padState.dpad = buttons0 & 0x0F;
    padState.btnX = buttons0 & 0x10;  // Square
    padState.btnA = buttons0 & 0x20;  // Cross
    padState.btnB = buttons0 & 0x40;  // Circle
    padState.btnY = buttons0 & 0x80;  // Triangle
    padState.btnL = buttons1 & 0x01;  // L1
    padState.btnR = buttons1 & 0x02;  // R1
    padState.btnMinus = buttons1 & 0x10;
    padState.btnPlus = buttons1 & 0x20;
    padState.btnLStick = buttons1 & 0x40;
    padState.btnRStick = buttons1 & 0x80;
    padState.btnHome = buttons2 & 0x01;
    padState.btnCapture = buttons2 & 0x02;
}

class ControllerParser : public HIDReportParser {
public:
    void Parse(USBHID* hid, bool isRptId, uint8_t len, uint8_t* buf) override {
        (void)hid;
        if (len > sizeof(padState.raw)) len = sizeof(padState.raw);
        memcpy(padState.raw, buf, len);
        padState.rawLen = len;

        ++diagnostic.hidReportCount;
        diagnostic.lastHidReportMs = millis();

        if (isPs5ControllerReport(buf, len, isRptId)) {
            parsePs5ControllerReport(buf, isRptId);
        }
    }
};

class DiagnosticHIDUniversal : public HIDUniversal {
public:
    explicit DiagnosticHIDUniversal(USB* usb) : HIDUniversal(usb) {}

    uint16_t vendorId() const { return VID; }
    uint16_t productId() const { return PID; }
};

USB Usb;
USBHub Hub(&Usb);
DiagnosticHIDUniversal Hid(&Usb);
ControllerParser parser;
EthernetUDP udp;

struct __attribute__((packed)) DiagnosticPacket {
    uint8_t magic[4];
    uint8_t version;
    uint8_t reserved0[3];
    uint32_t sequence;
    uint32_t uptimeMs;
    uint16_t buttonBits;
    uint8_t dpad;
    uint8_t leftX;
    uint8_t leftY;
    uint8_t rightX;
    uint8_t rightY;
    uint8_t inputValid;
};

static_assert(sizeof(DiagnosticPacket) == 24, "DiagnosticPacket must remain fixed at 24 bytes");

uint32_t lastUdpMs = 0;
uint32_t lastLinkPollMs = 0;
uint32_t lastDisplayMs = 0;
uint32_t lastSerialMs = 0;

void resetControllerState() {
    memset(&padState, 0, sizeof(padState));
    padState.dpad = 8;
    padState.lX = padState.lY = padState.rX = padState.rY = 0x80;
}

const char* resetReasonText(esp_reset_reason_t reason) {
    switch (reason) {
        case ESP_RST_POWERON: return "POWERON";
        case ESP_RST_EXT: return "EXTERNAL";
        case ESP_RST_SW: return "SOFTWARE";
        case ESP_RST_PANIC: return "PANIC";
        case ESP_RST_INT_WDT: return "INT_WDT";
        case ESP_RST_TASK_WDT: return "TASK_WDT";
        case ESP_RST_WDT: return "OTHER_WDT";
        case ESP_RST_DEEPSLEEP: return "DEEPSLEEP";
        case ESP_RST_BROWNOUT: return "BROWNOUT";
        case ESP_RST_SDIO: return "SDIO";
        case ESP_RST_USB: return "USB";
        case ESP_RST_JTAG: return "JTAG";
        case ESP_RST_EFUSE: return "EFUSE";
        case ESP_RST_PWR_GLITCH: return "PWR_GLITCH";
        case ESP_RST_CPU_LOCKUP: return "CPU_LOCKUP";
        default: return "UNKNOWN";
    }
}

const char* initializationOrderText() {
    return DiagnosticConfig::kInitializationOrder == InitializationOrder::UsbThenLan
               ? "USB->LAN"
               : "LAN->USB";
}

const char* diagnosticModeText() {
    switch (DiagnosticConfig::kDiagnosticMode) {
        case DiagnosticMode::UsbOnlyWithLanHeldReset: return "USB_ONLY_LAN_RESET";
        case DiagnosticMode::LanInitializedNoRuntimeAccess: return "LAN_INIT_NO_RUNTIME";
        case DiagnosticMode::LanLinkStatusOnly: return "LAN_LINK_ONLY";
        case DiagnosticMode::FullUdp: return "FULL_UDP";
        default: return "UNKNOWN";
    }
}

constexpr bool lanInitializationEnabled() {
    return DiagnosticConfig::kDiagnosticMode !=
           DiagnosticMode::UsbOnlyWithLanHeldReset;
}

constexpr bool lanLinkPollingEnabled() {
    return DiagnosticConfig::kDiagnosticMode == DiagnosticMode::LanLinkStatusOnly ||
           DiagnosticConfig::kDiagnosticMode == DiagnosticMode::FullUdp;
}

constexpr bool udpEnabled() {
    return DiagnosticConfig::kDiagnosticMode == DiagnosticMode::FullUdp;
}

const char* linkStatusText(EthernetLinkStatus status) {
    switch (status) {
        case LinkON: return "ON";
        case LinkOFF: return "OFF";
        default: return "UNKNOWN";
    }
}

const char* w5500StatusText() {
    if (!diagnostic.lanInitAttempted) return "SKIP";
    return diagnostic.w5500InitOk ? "OK" : "FAIL";
}

const char* udpSocketStatusText() {
    if (!udpEnabled()) return "SKIP";
    return diagnostic.udpSocketReady ? "OK" : "FAIL";
}

const char* diagnosticLinkStatusText() {
    if (!lanLinkPollingEnabled()) return "SKIP";
    return linkStatusText(diagnostic.linkStatus);
}

bool isDualSenseIdentity(uint16_t vid, uint16_t pid) {
    // Original DualSense USB identity. Unknown revisions are still shown by VID/PID,
    // but are not labelled connected until deliberately added here.
    return vid == 0x054C && pid == 0x0CE6;
}

bool dualSenseConnected() {
    return diagnostic.usbInitOk && diagnostic.parserAttached && diagnostic.hidReady &&
           isDualSenseIdentity(diagnostic.vid, diagnostic.pid);
}

bool inputIsValid(uint32_t now) {
    return dualSenseConnected() && diagnostic.hidReportCount > 0 &&
           now - diagnostic.lastHidReportMs <= DiagnosticConfig::kInputValidWindowMs;
}

uint16_t controllerButtonBits() {
    uint16_t bits = 0;
    if (padState.btnA) bits |= 1U << 0;
    if (padState.btnB) bits |= 1U << 1;
    if (padState.btnX) bits |= 1U << 2;
    if (padState.btnY) bits |= 1U << 3;
    if (padState.btnL) bits |= 1U << 4;
    if (padState.btnR) bits |= 1U << 5;
    if (padState.btnZL) bits |= 1U << 6;
    if (padState.btnZR) bits |= 1U << 7;
    if (padState.btnMinus) bits |= 1U << 8;
    if (padState.btnPlus) bits |= 1U << 9;
    if (padState.btnHome) bits |= 1U << 10;
    if (padState.btnCapture) bits |= 1U << 11;
    if (padState.btnLStick) bits |= 1U << 12;
    if (padState.btnRStick) bits |= 1U << 13;
    return bits;
}

inline void deselectExternalSpiDevices() {
    digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
    digitalWrite(DiagnosticConfig::kLanCsPin, HIGH);
}

void prepareSharedSpiPins() {
    // Set output latches before enabling outputs to avoid selecting either device.
    deselectExternalSpiDevices();
    pinMode(USB_HOST_SHIELD_SS_GPIO, OUTPUT);
    pinMode(DiagnosticConfig::kLanCsPin, OUTPUT);
    digitalWrite(DiagnosticConfig::kLanResetPin, LOW);
    pinMode(DiagnosticConfig::kLanResetPin, OUTPUT);
    pinMode(DiagnosticConfig::kLanIntPin, INPUT_PULLUP);
}

void initializeUsbHost() {
    deselectExternalSpiDevices();
    Serial.println("[INIT] USB Host start");
    const int result = Usb.Init();
    diagnostic.usbInitOk = result != -1;
    if (diagnostic.usbInitOk) {
        diagnostic.parserAttached = Hid.SetReportParser(0, &parser);
        diagnostic.max3421eRevision = Usb.regRd(rREVISION);
        diagnostic.usbTaskState = Usb.getUsbTaskState();
    }
    Serial.printf("[INIT] USB Host=%s parser=%s result=%d MAX_REV=0x%02X\n",
                  diagnostic.usbInitOk ? "OK" : "FAIL",
                  diagnostic.parserAttached ? "OK" : "FAIL", result,
                  diagnostic.max3421eRevision);
}

void initializeLan() {
    deselectExternalSpiDevices();
    if (!lanInitializationEnabled()) {
        digitalWrite(DiagnosticConfig::kLanResetPin, LOW);
        Serial.println("[INIT] W5500 skipped; LAN RESET held LOW");
        return;
    }
    diagnostic.lanInitAttempted = true;
    Serial.println("[INIT] W5500 start");

    // This is the only point where LAN RESET is released.
    digitalWrite(DiagnosticConfig::kLanResetPin, LOW);
    delay(50);
    digitalWrite(DiagnosticConfig::kLanResetPin, HIGH);
    delay(50);

    SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);
    Ethernet.init(DiagnosticConfig::kLanCsPin);
    Ethernet.begin(DiagnosticConfig::kMacAddress, DiagnosticConfig::kLocalIp,
                   DiagnosticConfig::kDns, DiagnosticConfig::kGateway,
                   DiagnosticConfig::kSubnet);

    diagnostic.w5500InitOk = Ethernet.hardwareStatus() == EthernetW5500;
    diagnostic.configuredIpText = DiagnosticConfig::kLocalIp.toString();
    if (diagnostic.w5500InitOk) {
        Ethernet.setRetransmissionTimeout(20);
        Ethernet.setRetransmissionCount(1);
    }
    diagnostic.actualIpText = Ethernet.localIP().toString();
    diagnostic.ipText = diagnostic.actualIpText;
    diagnostic.udpSocketReady = udpEnabled() && diagnostic.w5500InitOk &&
                                udp.begin(DiagnosticConfig::kLocalUdpPort) == 1;

    Serial.printf("[INIT] W5500=%s UDP socket=%s IP(cfg=%s actual=%s)\n",
                  w5500StatusText(),
                  udpSocketStatusText(),
                  diagnostic.configuredIpText.c_str(),
                  diagnostic.actualIpText.c_str());
}

void updateUsbIdentity() {
    diagnostic.usbTaskState = diagnostic.usbInitOk ? Usb.getUsbTaskState() : 0;
    diagnostic.hidReady = diagnostic.usbInitOk && Hid.isReady();
    if (diagnostic.hidReadyObserved && diagnostic.previousHidReady &&
        !diagnostic.hidReady) {
        ++diagnostic.readyToNotReadyCount;
    }
    if (diagnostic.hidReady) diagnostic.hidReadyObserved = true;
    diagnostic.previousHidReady = diagnostic.hidReady;

    if (diagnostic.hidReady) {
        diagnostic.vid = Hid.vendorId();
        diagnostic.pid = Hid.productId();
    } else {
        diagnostic.vid = 0;
        diagnostic.pid = 0;
    }
}

void updateLanRuntimeStatus() {
    if (!lanLinkPollingEnabled() || !diagnostic.w5500InitOk) return;
    deselectExternalSpiDevices();
    diagnostic.linkStatus = Ethernet.linkStatus();
}

void sendDiagnosticPacket(uint32_t now) {
    if (diagnostic.linkStatus != LinkON) {
        ++diagnostic.udpSkippedNoLinkCount;
        return;
    }

    if (!diagnostic.w5500InitOk || !diagnostic.udpSocketReady) {
        ++diagnostic.udpFailedCount;
        return;
    }

    deselectExternalSpiDevices();
    DiagnosticPacket packet = {};
    packet.magic[0] = 'M';
    packet.magic[1] = '5';
    packet.magic[2] = 'D';
    packet.magic[3] = 'S';
    packet.version = 1;
    packet.sequence = diagnostic.nextSequence++;
    packet.uptimeMs = now;
    const bool inputValid = inputIsValid(now);
    packet.inputValid = inputValid ? 1 : 0;
    if (inputValid) {
        packet.buttonBits = controllerButtonBits();
        packet.dpad = padState.dpad;
        packet.leftX = padState.lX;
        packet.leftY = padState.lY;
        packet.rightX = padState.rX;
        packet.rightY = padState.rY;
    } else {
        packet.buttonBits = 0;
        packet.dpad = 8;
        packet.leftX = 0x80;
        packet.leftY = 0x80;
        packet.rightX = 0x80;
        packet.rightY = 0x80;
    }
    diagnostic.lastSequence = packet.sequence;

    const uint32_t totalStartUs = micros();

    const uint32_t beginStartUs = micros();
    const int beginResult = udp.beginPacket(DiagnosticConfig::kDestinationIp,
                                            DiagnosticConfig::kDestinationUdpPort);
    const uint32_t beginElapsedUs = micros() - beginStartUs;

    uint32_t writeElapsedUs = 0;
    uint32_t endElapsedUs = 0;
    bool sent = false;
    if (beginResult == 1) {
        const uint32_t writeStartUs = micros();
        const size_t written = udp.write(reinterpret_cast<const uint8_t*>(&packet),
                                         sizeof(packet));
        writeElapsedUs = micros() - writeStartUs;

        if (written == sizeof(packet)) {
            const uint32_t endStartUs = micros();
            const int endResult = udp.endPacket();
            endElapsedUs = micros() - endStartUs;
            sent = endResult == 1;
        }
    }

    const uint32_t totalElapsedUs = micros() - totalStartUs;
    diagnostic.udpLastBeginUs = beginElapsedUs;
    diagnostic.udpLastWriteUs = writeElapsedUs;
    diagnostic.udpLastEndUs = endElapsedUs;
    diagnostic.udpLastTotalUs = totalElapsedUs;
    diagnostic.udpMaxBeginUs = max(diagnostic.udpMaxBeginUs, beginElapsedUs);
    diagnostic.udpMaxWriteUs = max(diagnostic.udpMaxWriteUs, writeElapsedUs);
    diagnostic.udpMaxEndUs = max(diagnostic.udpMaxEndUs, endElapsedUs);
    diagnostic.udpMaxTotalUs = max(diagnostic.udpMaxTotalUs, totalElapsedUs);

    if (sent) {
        ++diagnostic.udpSentCount;
    } else {
        ++diagnostic.udpFailedCount;
    }
}

void updateLoopRates(uint32_t now) {
    const uint32_t elapsedMs = now - diagnostic.lastLoopRateSampleMs;
    if (elapsedMs < 1000) return;

    const uint32_t loopDelta =
        diagnostic.loopCount - diagnostic.lastLoopCountSnapshot;
    const uint32_t usbTaskDelta =
        diagnostic.usbTaskCallCount - diagnostic.lastUsbTaskCountSnapshot;
    diagnostic.loopsPerSecond = static_cast<uint32_t>(
        static_cast<uint64_t>(loopDelta) * 1000U / elapsedMs);
    diagnostic.usbTasksPerSecond = static_cast<uint32_t>(
        static_cast<uint64_t>(usbTaskDelta) * 1000U / elapsedMs);
    diagnostic.lastLoopCountSnapshot = diagnostic.loopCount;
    diagnostic.lastUsbTaskCountSnapshot = diagnostic.usbTaskCallCount;
    diagnostic.lastLoopRateSampleMs = now;
}

void drawStatus(uint32_t now) {
    deselectExternalSpiDevices();
    M5.Display.startWrite();
    M5.Display.fillScreen(BLACK);
    M5.Display.setCursor(0, 0);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.setTextSize(1);
    M5.Display.println("CoreS3 SE USB+LAN diagnostic");
    M5.Display.printf("Mode:%s\n", diagnosticModeText());
    M5.Display.printf("Order:%s Reset:%s\n", initializationOrderText(), resetReasonText(diagnostic.resetReason));
    M5.Display.printf("SPI S%d MO%d MI%d\n", PIN_SPI_SCK, PIN_SPI_MOSI,
                      PIN_SPI_MISO);
    M5.Display.printf("USB:%s CS%d INT%d DS:%s\n",
                      diagnostic.usbInitOk ? "OK" : "FAIL",
                      USB_HOST_SHIELD_SS_GPIO, USB_HOST_SHIELD_INT_GPIO,
                      dualSenseConnected() ? "YES" : "NO");
    M5.Display.printf("PARSER=%s\n",
                      diagnostic.parserAttached ? "OK" : "FAIL");
    M5.Display.printf("TASK:%02X Ready:%u Rev:%02X Drop:%lu\n",
                      diagnostic.usbTaskState, diagnostic.hidReady ? 1 : 0,
                      diagnostic.max3421eRevision,
                      static_cast<unsigned long>(diagnostic.readyToNotReadyCount));
    M5.Display.printf("PIN U-I:%d U-CS:%d L-CS:%d L-R:%d\n",
                      digitalRead(USB_HOST_SHIELD_INT_GPIO),
                      digitalRead(USB_HOST_SHIELD_SS_GPIO),
                      digitalRead(DiagnosticConfig::kLanCsPin),
                      digitalRead(DiagnosticConfig::kLanResetPin));
    M5.Display.printf("VID:%04X PID:%04X HID:%llu\n", diagnostic.vid,
                      diagnostic.pid,
                      static_cast<unsigned long long>(diagnostic.hidReportCount));
    if (diagnostic.hidReportCount == 0) {
        M5.Display.println("Last HID:-");
    } else {
        M5.Display.printf("Last HID:%lu ms (%lums ago)\n",
                          static_cast<unsigned long>(diagnostic.lastHidReportMs),
                          static_cast<unsigned long>(now - diagnostic.lastHidReportMs));
    }
    M5.Display.printf("W5500:%s Link:%s\n", w5500StatusText(),
                      diagnosticLinkStatusText());
    M5.Display.printf("LAN CS%d INT%d RST%d\n", DiagnosticConfig::kLanCsPin,
                      DiagnosticConfig::kLanIntPin,
                      DiagnosticConfig::kLanResetPin);
    M5.Display.printf("IP cfg:%s\n", diagnostic.configuredIpText.c_str());
    M5.Display.printf("IP act:%s\n", diagnostic.actualIpText.c_str());
    M5.Display.printf("UDP socket:%s\n", udpSocketStatusText());
    M5.Display.printf("UDP OK:%lu FAIL:%lu\n",
                      static_cast<unsigned long>(diagnostic.udpSentCount),
                      static_cast<unsigned long>(diagnostic.udpFailedCount));
    M5.Display.printf("UDP SKIP:%lu\n",
                      static_cast<unsigned long>(diagnostic.udpSkippedNoLinkCount));
    M5.Display.printf("UDP US:%lu/%lu\n",
                      static_cast<unsigned long>(diagnostic.udpLastTotalUs),
                      static_cast<unsigned long>(diagnostic.udpMaxTotalUs));
    M5.Display.printf("LOOP/s:%lu\n",
                      static_cast<unsigned long>(diagnostic.loopsPerSecond));
    M5.Display.printf("USB/s:%lu\n",
                      static_cast<unsigned long>(diagnostic.usbTasksPerSecond));
    M5.Display.printf("SEQ:%lu Valid:%u\n",
                      static_cast<unsigned long>(diagnostic.lastSequence),
                      inputIsValid(now) ? 1 : 0);
    M5.Display.printf("Uptime:%lu ms\n", static_cast<unsigned long>(now));
    M5.Display.endWrite();
}

void logStatus(uint32_t now) {
    Serial.printf(
        "[STATUS] MODE=%s USB_INIT=%s PARSER=%s USB_TASK=0x%02X HID_READY=%u "
        "MAX_REV=0x%02X READY_DROP=%lu USB_INT=%d USB_CS=%d LAN_CS=%d LAN_RST=%d "
        "DS=%s VID=%04X PID=%04X HID_COUNT=%llu LAST_HID_MS=%lu "
        "LAST_HID_AGE_MS=%lu W5500_INIT=%s LINK=%s IP=%s UDP_SOCKET=%s UDP_OK=%lu "
        "UDP_FAIL=%lu UDP_SKIP=%lu SEQ=%lu UPTIME_MS=%lu RESET=%s INPUT_VALID=%u\n",
        diagnosticModeText(), diagnostic.usbInitOk ? "OK" : "FAIL",
        diagnostic.parserAttached ? "OK" : "FAIL",
        diagnostic.usbTaskState, diagnostic.hidReady ? 1 : 0,
        diagnostic.max3421eRevision,
        static_cast<unsigned long>(diagnostic.readyToNotReadyCount),
        digitalRead(USB_HOST_SHIELD_INT_GPIO), digitalRead(USB_HOST_SHIELD_SS_GPIO),
        digitalRead(DiagnosticConfig::kLanCsPin), digitalRead(DiagnosticConfig::kLanResetPin),
        dualSenseConnected() ? "CONNECTED" : "DISCONNECTED", diagnostic.vid,
        diagnostic.pid,
        static_cast<unsigned long long>(diagnostic.hidReportCount),
        static_cast<unsigned long>(diagnostic.lastHidReportMs),
        static_cast<unsigned long>(now - diagnostic.lastHidReportMs),
        w5500StatusText(), diagnosticLinkStatusText(),
        diagnostic.configuredIpText.c_str(),
        diagnostic.actualIpText.c_str(),
        udpSocketStatusText(),
        static_cast<unsigned long>(diagnostic.udpSentCount),
        static_cast<unsigned long>(diagnostic.udpFailedCount),
        static_cast<unsigned long>(diagnostic.udpSkippedNoLinkCount),
        static_cast<unsigned long>(diagnostic.lastSequence),
        static_cast<unsigned long>(now), resetReasonText(diagnostic.resetReason),
        inputIsValid(now) ? 1 : 0);
    Serial.printf(
        "[PERF] UDP_US_BEGIN_LAST=%lu UDP_US_BEGIN_MAX=%lu "
        "UDP_US_WRITE_LAST=%lu UDP_US_WRITE_MAX=%lu "
        "UDP_US_END_LAST=%lu UDP_US_END_MAX=%lu "
        "UDP_US_TOTAL_LAST=%lu UDP_US_TOTAL_MAX=%lu "
        "LOOP_PER_SEC=%lu USB_TASK_PER_SEC=%lu\n",
        static_cast<unsigned long>(diagnostic.udpLastBeginUs),
        static_cast<unsigned long>(diagnostic.udpMaxBeginUs),
        static_cast<unsigned long>(diagnostic.udpLastWriteUs),
        static_cast<unsigned long>(diagnostic.udpMaxWriteUs),
        static_cast<unsigned long>(diagnostic.udpLastEndUs),
        static_cast<unsigned long>(diagnostic.udpMaxEndUs),
        static_cast<unsigned long>(diagnostic.udpLastTotalUs),
        static_cast<unsigned long>(diagnostic.udpMaxTotalUs),
        static_cast<unsigned long>(diagnostic.loopsPerSecond),
        static_cast<unsigned long>(diagnostic.usbTasksPerSecond));
}

void setup() {
    diagnostic.resetReason = esp_reset_reason();
    resetControllerState();
    prepareSharedSpiPins();

    auto cfg = M5.config();
    // GPIO0 and GPIO13 are reused as LAN RESET/CS in this diagnostic.
    cfg.internal_spk = false;
    cfg.internal_mic = false;
    M5.begin(cfg);
    prepareSharedSpiPins();

    Serial.begin(115200);
    delay(100);

    Serial.println("\n=== CoreS3 SE DualSense + LAN stack diagnostic ===");
    Serial.printf("Mode=%s Order=%s Reset=%s\n", diagnosticModeText(),
                  initializationOrderText(), resetReasonText(diagnostic.resetReason));
    Serial.printf("USB SS=GPIO%d INT=GPIO%d; LAN CS=GPIO%d INT=GPIO%d RST=GPIO%d\n",
                  USB_HOST_SHIELD_SS_GPIO, USB_HOST_SHIELD_INT_GPIO,
                  DiagnosticConfig::kLanCsPin, DiagnosticConfig::kLanIntPin,
                  DiagnosticConfig::kLanResetPin);

    if (DiagnosticConfig::kInitializationOrder == InitializationOrder::UsbThenLan) {
        initializeUsbHost();
        initializeLan();
    } else {
        initializeLan();
        initializeUsbHost();
    }

    const uint32_t now = millis();
    lastUdpMs = now;
    lastLinkPollMs = now - DiagnosticConfig::kLinkPollIntervalMs;
    lastDisplayMs = now - DiagnosticConfig::kDisplayIntervalMs;
    lastSerialMs = now - DiagnosticConfig::kSerialIntervalMs;
    diagnostic.lastLoopRateSampleMs = now;
    diagnostic.lastLoopCountSnapshot = diagnostic.loopCount;
    diagnostic.lastUsbTaskCountSnapshot = diagnostic.usbTaskCallCount;
}

void loop() {
    ++diagnostic.loopCount;
    if (diagnostic.usbInitOk) {
        deselectExternalSpiDevices();
        Usb.Task();
        ++diagnostic.usbTaskCallCount;
    }
    M5.update();
    updateUsbIdentity();

    const uint32_t now = millis();
    updateLoopRates(now);

    if (lanLinkPollingEnabled() &&
        now - lastLinkPollMs >= DiagnosticConfig::kLinkPollIntervalMs) {
        lastLinkPollMs = now;
        updateLanRuntimeStatus();
    }

    if (udpEnabled() &&
        now - lastUdpMs >= DiagnosticConfig::kUdpIntervalMs) {
        lastUdpMs = now;
        sendDiagnosticPacket(now);
    }

    if (now - lastDisplayMs >= DiagnosticConfig::kDisplayIntervalMs) {
        lastDisplayMs = now;
        drawStatus(now);
    }

    if (now - lastSerialMs >= DiagnosticConfig::kSerialIntervalMs) {
        lastSerialMs = now;
        logStatus(now);
    }
}
