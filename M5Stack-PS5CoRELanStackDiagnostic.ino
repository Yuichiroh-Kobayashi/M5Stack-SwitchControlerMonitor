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

// Change only this value to exercise the opposite initialization order.
constexpr InitializationOrder kInitializationOrder = InitializationOrder::UsbThenLan;

constexpr uint8_t kLanCsPin = 13;     // M5-Bus pin 23 (CSN alternate)
constexpr uint8_t kLanIntPin = 10;    // M5-Bus pin 2
constexpr uint8_t kLanResetPin = 0;   // M5-Bus pin 24

constexpr uint32_t kUdpIntervalMs = 20;
constexpr uint32_t kInputValidWindowMs = 500;
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
    bool w5500InitOk = false;
    bool udpSocketReady = false;
    uint64_t hidReportCount = 0;
    uint32_t lastHidReportMs = 0;
    uint32_t udpSentCount = 0;
    uint32_t udpFailedCount = 0;
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

const char* linkStatusText(EthernetLinkStatus status) {
    switch (status) {
        case LinkON: return "ON";
        case LinkOFF: return "OFF";
        default: return "UNKNOWN";
    }
}

bool isDualSenseIdentity(uint16_t vid, uint16_t pid) {
    // Original DualSense USB identity. Unknown revisions are still shown by VID/PID,
    // but are not labelled connected until deliberately added here.
    return vid == 0x054C && pid == 0x0CE6;
}

bool dualSenseConnected() {
    return diagnostic.usbInitOk && diagnostic.parserAttached && Hid.isReady() &&
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

void prepareSharedSpiPins() {
    // Set both external devices inactive before either SPI stack is initialized.
    digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
    pinMode(USB_HOST_SHIELD_SS_GPIO, OUTPUT);
    digitalWrite(DiagnosticConfig::kLanCsPin, HIGH);
    pinMode(DiagnosticConfig::kLanCsPin, OUTPUT);
    digitalWrite(DiagnosticConfig::kLanResetPin, HIGH);
    pinMode(DiagnosticConfig::kLanResetPin, OUTPUT);
    pinMode(DiagnosticConfig::kLanIntPin, INPUT_PULLUP);
}

void initializeUsbHost() {
    Serial.println("[INIT] USB Host start");
    digitalWrite(DiagnosticConfig::kLanCsPin, HIGH);
    const int result = Usb.Init();
    diagnostic.usbInitOk = result != -1;
    if (diagnostic.usbInitOk) {
        diagnostic.parserAttached = Hid.SetReportParser(0, &parser);
    }
    Serial.printf("[INIT] USB Host=%s parser=%s result=%d\n",
                  diagnostic.usbInitOk ? "OK" : "FAIL",
                  diagnostic.parserAttached ? "OK" : "FAIL", result);
}

void initializeLan() {
    Serial.println("[INIT] W5500 start");
    digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);

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
    diagnostic.udpSocketReady =
        diagnostic.w5500InitOk && udp.begin(DiagnosticConfig::kLocalUdpPort) == 1;

    const String ipText = diagnostic.w5500InitOk
                              ? Ethernet.localIP().toString()
                              : String("0.0.0.0");
    Serial.printf("[INIT] W5500=%s UDP socket=%s IP=%s\n",
                  diagnostic.w5500InitOk ? "OK" : "FAIL",
                  diagnostic.udpSocketReady ? "OK" : "FAIL",
                  ipText.c_str());
}

void updateUsbIdentity() {
    if (diagnostic.usbInitOk && Hid.isReady()) {
        diagnostic.vid = Hid.vendorId();
        diagnostic.pid = Hid.productId();
    } else {
        diagnostic.vid = 0;
        diagnostic.pid = 0;
    }
}

void sendDiagnosticPacket(uint32_t now) {
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

    bool sent = false;
    digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
    if (diagnostic.w5500InitOk && diagnostic.udpSocketReady &&
        udp.beginPacket(DiagnosticConfig::kDestinationIp,
                        DiagnosticConfig::kDestinationUdpPort) == 1) {
        const size_t written = udp.write(reinterpret_cast<const uint8_t*>(&packet),
                                         sizeof(packet));
        const int endResult = udp.endPacket();
        sent = written == sizeof(packet) && endResult == 1;
    }

    if (sent) {
        ++diagnostic.udpSentCount;
    } else {
        ++diagnostic.udpFailedCount;
    }
}

void drawStatus(uint32_t now) {
    digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
    const EthernetLinkStatus link = diagnostic.w5500InitOk
                                        ? Ethernet.linkStatus()
                                        : Unknown;
    // Finish W5500 reads before M5GFX owns the same physical SPI bus.
    const String ipText = diagnostic.w5500InitOk
                              ? Ethernet.localIP().toString()
                              : String("0.0.0.0");
    digitalWrite(DiagnosticConfig::kLanCsPin, HIGH);
    M5.Display.startWrite();
    M5.Display.fillScreen(BLACK);
    M5.Display.setCursor(0, 0);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.setTextSize(1);
    M5.Display.println("CoreS3 SE USB+LAN diagnostic");
    M5.Display.printf("Order:%s Reset:%s\n", initializationOrderText(),
                      resetReasonText(diagnostic.resetReason));
    M5.Display.printf("SPI S%d MO%d MI%d\n", PIN_SPI_SCK, PIN_SPI_MOSI,
                      PIN_SPI_MISO);
    M5.Display.printf("USB:%s CS%d INT%d DS:%s\n",
                      diagnostic.usbInitOk ? "OK" : "FAIL",
                      USB_HOST_SHIELD_SS_GPIO, USB_HOST_SHIELD_INT_GPIO,
                      dualSenseConnected() ? "YES" : "NO");
    M5.Display.printf("PARSER=%s\n",
                      diagnostic.parserAttached ? "OK" : "FAIL");
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
    M5.Display.printf("W5500:%s Link:%s\n",
                      diagnostic.w5500InitOk ? "OK" : "FAIL",
                      linkStatusText(link));
    M5.Display.printf("LAN CS%d INT%d RST%d\n", DiagnosticConfig::kLanCsPin,
                      DiagnosticConfig::kLanIntPin,
                      DiagnosticConfig::kLanResetPin);
    M5.Display.printf("IP:%s\n", ipText.c_str());
    M5.Display.printf("UDP OK:%lu FAIL:%lu\n",
                      static_cast<unsigned long>(diagnostic.udpSentCount),
                      static_cast<unsigned long>(diagnostic.udpFailedCount));
    M5.Display.printf("SEQ:%lu Valid:%u\n",
                      static_cast<unsigned long>(diagnostic.lastSequence),
                      inputIsValid(now) ? 1 : 0);
    M5.Display.printf("Uptime:%lu ms\n", static_cast<unsigned long>(now));
    M5.Display.endWrite();
}

void logStatus(uint32_t now) {
    digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
    const EthernetLinkStatus link = diagnostic.w5500InitOk
                                        ? Ethernet.linkStatus()
                                        : Unknown;
    const String ipText = diagnostic.w5500InitOk
                              ? Ethernet.localIP().toString()
                              : String("0.0.0.0");
    Serial.printf(
        "[STATUS] USB_INIT=%s PARSER=%s DS=%s VID=%04X PID=%04X HID_COUNT=%llu "
        "LAST_HID_MS=%lu W5500_INIT=%s LINK=%s IP=%s UDP_OK=%lu "
        "UDP_FAIL=%lu SEQ=%lu UPTIME_MS=%lu RESET=%s INPUT_VALID=%u\n",
        diagnostic.usbInitOk ? "OK" : "FAIL",
        diagnostic.parserAttached ? "OK" : "FAIL",
        dualSenseConnected() ? "CONNECTED" : "DISCONNECTED", diagnostic.vid,
        diagnostic.pid,
        static_cast<unsigned long long>(diagnostic.hidReportCount),
        static_cast<unsigned long>(diagnostic.lastHidReportMs),
        diagnostic.w5500InitOk ? "OK" : "FAIL", linkStatusText(link),
        ipText.c_str(),
        static_cast<unsigned long>(diagnostic.udpSentCount),
        static_cast<unsigned long>(diagnostic.udpFailedCount),
        static_cast<unsigned long>(diagnostic.lastSequence),
        static_cast<unsigned long>(now), resetReasonText(diagnostic.resetReason),
        inputIsValid(now) ? 1 : 0);
}

void setup() {
    diagnostic.resetReason = esp_reset_reason();
    resetControllerState();

    auto cfg = M5.config();
    // GPIO0 and GPIO13 are reused as LAN RESET/CS in this diagnostic.
    cfg.internal_spk = false;
    cfg.internal_mic = false;
    M5.begin(cfg);

    Serial.begin(115200);
    delay(100);
    prepareSharedSpiPins();

    Serial.println("\n=== CoreS3 SE DualSense + LAN stack diagnostic ===");
    Serial.printf("Order=%s Reset=%s\n", initializationOrderText(),
                  resetReasonText(diagnostic.resetReason));
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
    lastDisplayMs = now - DiagnosticConfig::kDisplayIntervalMs;
    lastSerialMs = now - DiagnosticConfig::kSerialIntervalMs;
}

void loop() {
    if (diagnostic.usbInitOk) {
        digitalWrite(DiagnosticConfig::kLanCsPin, HIGH);
        Usb.Task();
    }
    M5.update();
    updateUsbIdentity();

    const uint32_t now = millis();
    if (now - lastUdpMs >= DiagnosticConfig::kUdpIntervalMs) {
        lastUdpMs += DiagnosticConfig::kUdpIntervalMs;
        if (now - lastUdpMs >= DiagnosticConfig::kUdpIntervalMs) {
            // Avoid a burst after a long blocking operation.
            lastUdpMs = now;
        }
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
