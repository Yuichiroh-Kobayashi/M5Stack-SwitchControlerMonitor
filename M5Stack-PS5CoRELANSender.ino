#include <M5Unified.h>
#include <SPI.h>
#include <M5_Ethernet.h>
#include <esp_system.h>

// usbhub.h includes USB Host Shield's local "Usb.h" and avoids the
// case-insensitive collision with ESP32 core's USB.h on Windows.
#include <usbhub.h>
#include <hiduniversal.h>

#if !defined(BUILD_TARGET_CORES3SE)
#error "M5Stack-PS5CoRELANSender.ino supports only the cores3se build target."
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

namespace LanSenderConfig {

constexpr uint8_t kLanCsPin = 13;
constexpr uint8_t kLanIntPin = 10;
constexpr uint8_t kLanResetPin = 0;
constexpr uint32_t kSendIntervalMs = 20;
constexpr uint32_t kInputValidWindowMs = 500;
constexpr uint32_t kLinkPollIntervalMs = 250;
constexpr uint32_t kAcceptPollIntervalMs = 20;
constexpr uint32_t kFailureBackoffMs = 250;
constexpr uint32_t kDisplayIntervalMs = 5000;
constexpr uint32_t kSerialIntervalMs = 1000;
constexpr uint16_t kTcpPort = 12345;

const IPAddress kLocalIp(192, 168, 50, 10);
const IPAddress kDns(192, 168, 50, 1);
const IPAddress kGateway(192, 168, 50, 1);
const IPAddress kSubnet(255, 255, 255, 0);
const IPAddress kExpectedReceiverIp(192, 168, 50, 20);
uint8_t kMacAddress[6] = {0x02, 0x4D, 0x35, 0x53, 0x45, 0x11};

}  // namespace LanSenderConfig

static_assert(LanSenderConfig::kLanCsPin != USB_HOST_SHIELD_SS_GPIO,
              "LAN CS conflicts with USB SS");
static_assert(LanSenderConfig::kLanIntPin != USB_HOST_SHIELD_INT_GPIO,
              "LAN INT conflicts with USB INT");
static_assert(LanSenderConfig::kLanResetPin != USB_HOST_SHIELD_SS_GPIO,
              "LAN RESET conflicts with USB SS");

struct ControllerState {
    bool btnA, btnB, btnX, btnY;
    bool btnL, btnR, btnZL, btnZR;
    bool btnMinus, btnPlus, btnHome, btnCapture;
    bool btnLStick, btnRStick;
    bool isPs5;
    uint8_t dpad;
    uint8_t lX, lY, rX, rY;
    uint8_t raw[64];
    uint8_t rawLen;
};

ControllerState padState;

struct SenderState {
    bool usbInitOk = false;
    bool parserAttached = false;
    bool hidReady = false;
    bool previousHidReady = false;
    bool hidReadyObserved = false;
    bool validInputThisSession = false;
    uint8_t usbTaskState = 0;
    uint8_t max3421eRevision = 0;
    uint16_t vid = 0;
    uint16_t pid = 0;
    uint64_t hidReportCount = 0;
    uint64_t validHidReportCount = 0;
    uint32_t lastValidHidReportMs = 0;
    uint32_t readyDropCount = 0;

    bool w5500InitOk = false;
    bool explicitConfigApplied = false;
    bool lanConfigOk = false;
    bool serverReady = false;
    EthernetLinkStatus linkStatus = Unknown;
    String ipAfterBeginText = "N/A";
    String actualIpText = "N/A";
    String gatewayText = "N/A";
    String subnetText = "N/A";

    bool clientConnected = false;
    String clientIpText = "N/A";
    uint32_t txCount = 0;
    uint32_t txFailCount = 0;
    uint32_t txSkipNoLinkCount = 0;
    uint32_t txSkipNoClientCount = 0;
    uint32_t rejectedClientCount = 0;
    uint32_t txLastUs = 0;
    uint32_t txMaxUs = 0;
    uint32_t loopCount = 0;
    uint32_t usbTaskCount = 0;
    uint32_t loopsPerSecond = 0;
    uint32_t usbTasksPerSecond = 0;
    uint32_t lastLoopSnapshot = 0;
    uint32_t lastUsbTaskSnapshot = 0;
    uint32_t lastRateMs = 0;
    esp_reset_reason_t resetReason = ESP_RST_UNKNOWN;
};

SenderState senderState;

void resetControllerState() {
    memset(&padState, 0, sizeof(padState));
    padState.dpad = 8;
    padState.lX = padState.lY = padState.rX = padState.rY = 0x80;
}

bool isPs5ControllerReport(const uint8_t* buf, uint8_t len) {
    return len >= 10 && (buf[0] == 0x01 || buf[0] == 0x11);
}

bool parsePs5ControllerReport(const uint8_t* buf) {
    if (padState.rawLen < 10) return false;
    padState.isPs5 = true;
    padState.lX = buf[1];
    padState.lY = buf[2];
    padState.rX = buf[3];
    padState.rY = buf[4];
    padState.btnZL = buf[5] != 0;
    padState.btnZR = buf[6] != 0;
    const uint8_t buttons0 = buf[8];
    const uint8_t buttons1 = buf[9];
    const uint8_t buttons2 = padState.rawLen > 10 ? buf[10] : 0;
    padState.dpad = buttons0 & 0x0F;
    padState.btnX = buttons0 & 0x10;
    padState.btnA = buttons0 & 0x20;
    padState.btnB = buttons0 & 0x40;
    padState.btnY = buttons0 & 0x80;
    padState.btnL = buttons1 & 0x01;
    padState.btnR = buttons1 & 0x02;
    padState.btnMinus = buttons1 & 0x10;
    padState.btnPlus = buttons1 & 0x20;
    padState.btnLStick = buttons1 & 0x40;
    padState.btnRStick = buttons1 & 0x80;
    padState.btnHome = buttons2 & 0x01;
    padState.btnCapture = buttons2 & 0x02;
    return true;
}

class ControllerParser : public HIDReportParser {
public:
    void Parse(USBHID* hid, bool isRptId, uint8_t len, uint8_t* buf) override {
        (void)hid;
        (void)isRptId;
        if (len > sizeof(padState.raw)) len = sizeof(padState.raw);
        memcpy(padState.raw, buf, len);
        padState.rawLen = len;
        ++senderState.hidReportCount;
        if (isPs5ControllerReport(buf, len) && parsePs5ControllerReport(buf)) {
            ++senderState.validHidReportCount;
            senderState.lastValidHidReportMs = millis();
            senderState.validInputThisSession = true;
        }
    }
};

class SenderHIDUniversal : public HIDUniversal {
public:
    explicit SenderHIDUniversal(USB* usb) : HIDUniversal(usb) {}
    uint16_t vendorId() const { return VID; }
    uint16_t productId() const { return PID; }
};

USB Usb;
USBHub Hub(&Usb);
SenderHIDUniversal Hid(&Usb);
ControllerParser parser;

// ESP32 core 3.3.7 Server requires begin(), while M5-Ethernet 4.0.0 only
// provides begin(uint16_t). Bridge that API mismatch without editing the
// installed library.
class CoreCompatibleEthernetServer : public EthernetServer {
public:
    explicit CoreCompatibleEthernetServer(uint16_t port)
        : EthernetServer(port), port_(port) {}
    void begin() override { EthernetServer::begin(port_); }

private:
    uint16_t port_;
};

CoreCompatibleEthernetServer tcpServer(LanSenderConfig::kTcpPort);
EthernetClient tcpClient;

uint32_t lastSendMs = 0;
uint32_t lastLinkPollMs = 0;
uint32_t lastAcceptPollMs = 0;
uint32_t lastDisplayMs = 0;
uint32_t lastSerialMs = 0;
uint32_t txBackoffUntilMs = 0;
char lastTxData[21] = "00,00,00,80,80,80,80";

inline void deselectExternalSpiDevices() {
    digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
    digitalWrite(LanSenderConfig::kLanCsPin, HIGH);
}

void prepareSharedSpiPins() {
    pinMode(USB_HOST_SHIELD_SS_GPIO, OUTPUT);
    pinMode(LanSenderConfig::kLanCsPin, OUTPUT);
    deselectExternalSpiDevices();
    pinMode(LanSenderConfig::kLanResetPin, OUTPUT);
    digitalWrite(LanSenderConfig::kLanResetPin, LOW);
    pinMode(LanSenderConfig::kLanIntPin, INPUT_PULLUP);
}

const char* linkText() {
    if (senderState.linkStatus == LinkON) return "ON";
    if (senderState.linkStatus == LinkOFF) return "OFF";
    return "UNKNOWN";
}

const char* resetReasonText(esp_reset_reason_t reason) {
    switch (reason) {
        case ESP_RST_POWERON: return "POWERON";
        case ESP_RST_SW: return "SOFTWARE";
        case ESP_RST_PANIC: return "PANIC";
        case ESP_RST_INT_WDT: return "INT_WDT";
        case ESP_RST_TASK_WDT: return "TASK_WDT";
        case ESP_RST_WDT: return "OTHER_WDT";
        case ESP_RST_BROWNOUT: return "BROWNOUT";
        case ESP_RST_USB: return "USB";
        default: return "OTHER";
    }
}

bool isDualSenseIdentity(uint16_t vid, uint16_t pid) {
    return vid == 0x054C && pid == 0x0CE6;
}

bool dualSenseConnected() {
    return senderState.usbInitOk && senderState.parserAttached &&
           senderState.hidReady &&
           isDualSenseIdentity(senderState.vid, senderState.pid);
}

bool inputIsValid(uint32_t now) {
    return dualSenseConnected() && senderState.validInputThisSession &&
           senderState.validHidReportCount > 0 &&
           now - senderState.lastValidHidReportMs <=
               LanSenderConfig::kInputValidWindowMs;
}

void initializeUsbHost() {
    deselectExternalSpiDevices();
    const int result = Usb.Init();
    senderState.usbInitOk = result != -1;
    if (senderState.usbInitOk) {
        senderState.parserAttached = Hid.SetReportParser(0, &parser);
        senderState.max3421eRevision = Usb.regRd(rREVISION);
    }
    Serial.printf("[INIT] USB=%s PARSER=%s RESULT=%d MAX_REV=0x%02X\n",
                  senderState.usbInitOk ? "OK" : "FAIL",
                  senderState.parserAttached ? "OK" : "FAIL", result,
                  senderState.max3421eRevision);
}

void initializeLan() {
    deselectExternalSpiDevices();
    digitalWrite(LanSenderConfig::kLanResetPin, LOW);
    delay(50);
    digitalWrite(LanSenderConfig::kLanResetPin, HIGH);
    delay(50);
    SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);
    Ethernet.init(LanSenderConfig::kLanCsPin);
    Ethernet.begin(LanSenderConfig::kMacAddress, LanSenderConfig::kLocalIp,
                   LanSenderConfig::kDns, LanSenderConfig::kGateway,
                   LanSenderConfig::kSubnet);
    senderState.w5500InitOk = Ethernet.hardwareStatus() == EthernetW5500;
    if (!senderState.w5500InitOk) {
        Serial.println("[INIT] W5500=FAIL LAN_CFG=FAIL TCP_SERVER=SKIP");
        return;
    }

    senderState.ipAfterBeginText = Ethernet.localIP().toString();
    Ethernet.setMACAddress(LanSenderConfig::kMacAddress);
    Ethernet.setLocalIP(LanSenderConfig::kLocalIp);
    Ethernet.setGatewayIP(LanSenderConfig::kGateway);
    Ethernet.setSubnetMask(LanSenderConfig::kSubnet);
    Ethernet.setDnsServerIP(LanSenderConfig::kDns);
    senderState.explicitConfigApplied = true;
    const IPAddress actualIp = Ethernet.localIP();
    const IPAddress actualGateway = Ethernet.gatewayIP();
    const IPAddress actualSubnet = Ethernet.subnetMask();
    senderState.actualIpText = actualIp.toString();
    senderState.gatewayText = actualGateway.toString();
    senderState.subnetText = actualSubnet.toString();
    senderState.lanConfigOk =
        actualIp == LanSenderConfig::kLocalIp &&
        actualGateway == LanSenderConfig::kGateway &&
        actualSubnet == LanSenderConfig::kSubnet;
    Ethernet.setRetransmissionTimeout(20);
    Ethernet.setRetransmissionCount(1);
    if (senderState.lanConfigOk) {
        tcpServer.begin();
        senderState.serverReady = static_cast<bool>(tcpServer);
    }
    Serial.printf(
        "[INIT] W5500=OK IP_AFTER_BEGIN=%s IP_ACT=%s GATEWAY_ACT=%s "
        "SUBNET_ACT=%s EXPLICIT_CFG=%s LAN_CFG=%s TCP_SERVER=%s PORT=%u\n",
        senderState.ipAfterBeginText.c_str(), senderState.actualIpText.c_str(),
        senderState.gatewayText.c_str(), senderState.subnetText.c_str(),
        senderState.explicitConfigApplied ? "OK" : "SKIP",
        senderState.lanConfigOk ? "OK" : "FAIL",
        senderState.serverReady ? "OK" : "FAIL",
        static_cast<unsigned>(LanSenderConfig::kTcpPort));
}

void updateUsbIdentity() {
    senderState.usbTaskState =
        senderState.usbInitOk ? Usb.getUsbTaskState() : 0;
    senderState.hidReady = senderState.usbInitOk && Hid.isReady();
    if (senderState.hidReady != senderState.previousHidReady) {
        resetControllerState();
        senderState.validInputThisSession = false;
        senderState.lastValidHidReportMs = 0;
    }
    if (senderState.hidReadyObserved && senderState.previousHidReady &&
        !senderState.hidReady) {
        ++senderState.readyDropCount;
    }
    if (senderState.hidReady) senderState.hidReadyObserved = true;
    senderState.previousHidReady = senderState.hidReady;
    if (senderState.hidReady) {
        senderState.vid = Hid.vendorId();
        senderState.pid = Hid.productId();
    } else {
        senderState.vid = 0;
        senderState.pid = 0;
    }
}

void disconnectClient(uint32_t now) {
    if (tcpClient) tcpClient.stop();
    tcpClient = EthernetClient();
    senderState.clientConnected = false;
    senderState.clientIpText = "N/A";
    txBackoffUntilMs = now + LanSenderConfig::kFailureBackoffMs;
}

void serviceTcpClient(uint32_t now) {
    if (!senderState.serverReady || senderState.linkStatus != LinkON) {
        if (senderState.clientConnected) disconnectClient(now);
        return;
    }
    if (senderState.clientConnected) {
        if (!tcpClient.connected()) {
            disconnectClient(now);
            return;
        }
        for (uint8_t i = 0; i < 16 && tcpClient.available(); ++i) {
            tcpClient.read();
        }
        return;
    }
    if (static_cast<int32_t>(now - txBackoffUntilMs) < 0 ||
        now - lastAcceptPollMs < LanSenderConfig::kAcceptPollIntervalMs) {
        return;
    }
    lastAcceptPollMs = now;
    deselectExternalSpiDevices();
    EthernetClient candidate = tcpServer.accept();
    if (!candidate) return;
    const IPAddress remoteIp = candidate.remoteIP();
    if (remoteIp != LanSenderConfig::kExpectedReceiverIp) {
        candidate.stop();
        ++senderState.rejectedClientCount;
        txBackoffUntilMs = now + LanSenderConfig::kFailureBackoffMs;
        return;
    }
    tcpClient = candidate;
    senderState.clientConnected = true;
    senderState.clientIpText = remoteIp.toString();
    Serial.printf("[TCP] CLIENT=CONNECTED IP=%s\n",
                  senderState.clientIpText.c_str());
}

void encodeControllerRecord(uint32_t now, char* output, size_t outputSize) {
    uint8_t byte0 = 0;
    uint8_t byte1 = 0;
    uint8_t byte2 = 0;
    uint8_t lX = 0x80, lY = 0x80, rX = 0x80, rY = 0x80;
    if (inputIsValid(now)) {
        if (padState.btnA) byte0 |= 0x01;
        if (padState.btnB) byte0 |= 0x02;
        if (padState.btnX) byte0 |= 0x04;
        if (padState.btnY) byte0 |= 0x08;
        if (padState.btnL) byte0 |= 0x10;
        if (padState.btnR) byte0 |= 0x20;
        if (padState.btnZL) byte0 |= 0x40;
        if (padState.btnZR) byte0 |= 0x80;
        if (padState.btnMinus) byte1 |= 0x01;
        if (padState.btnPlus) byte1 |= 0x02;
        if (padState.btnHome) byte1 |= 0x04;
        if (padState.btnCapture) byte1 |= 0x08;
        if (padState.btnLStick) byte1 |= 0x10;
        if (padState.btnRStick) byte1 |= 0x20;
        if (padState.dpad != 0x0F && padState.dpad != 8) {
            byte2 = (padState.dpad & 0x0F) + 1;
        }
        lX = padState.lX;
        lY = padState.lY;
        rX = padState.rX;
        rY = padState.rY;
    }
    snprintf(output, outputSize, "%02X,%02X,%02X,%02X,%02X,%02X,%02X",
             byte0, byte1, byte2, lX, lY, rX, rY);
}

void sendControllerState(uint32_t now) {
    encodeControllerRecord(now, lastTxData, sizeof(lastTxData));
    Serial2.print(lastTxData);
    Serial2.print("\r\n");
    if (senderState.linkStatus != LinkON) {
        ++senderState.txSkipNoLinkCount;
        return;
    }
    if (!senderState.clientConnected || !tcpClient.connected()) {
        ++senderState.txSkipNoClientCount;
        return;
    }
    if (static_cast<int32_t>(now - txBackoffUntilMs) < 0) return;

    char tcpRecord[22];
    memcpy(tcpRecord, lastTxData, 20);
    tcpRecord[20] = '\n';
    tcpRecord[21] = '\0';
    deselectExternalSpiDevices();
    if (tcpClient.availableForWrite() < 21) {
        ++senderState.txFailCount;
        txBackoffUntilMs = now + LanSenderConfig::kFailureBackoffMs;
        return;
    }
    const uint32_t startUs = micros();
    const size_t written =
        tcpClient.write(reinterpret_cast<const uint8_t*>(tcpRecord), 21);
    const uint32_t elapsedUs = micros() - startUs;
    senderState.txLastUs = elapsedUs;
    senderState.txMaxUs = max(senderState.txMaxUs, elapsedUs);
    if (written == 21) {
        ++senderState.txCount;
    } else {
        ++senderState.txFailCount;
        disconnectClient(now);
    }
}

void updateRates(uint32_t now) {
    const uint32_t elapsed = now - senderState.lastRateMs;
    if (elapsed < 1000) return;
    senderState.loopsPerSecond = static_cast<uint32_t>(
        static_cast<uint64_t>(senderState.loopCount - senderState.lastLoopSnapshot) *
        1000U / elapsed);
    senderState.usbTasksPerSecond = static_cast<uint32_t>(
        static_cast<uint64_t>(senderState.usbTaskCount - senderState.lastUsbTaskSnapshot) *
        1000U / elapsed);
    senderState.lastLoopSnapshot = senderState.loopCount;
    senderState.lastUsbTaskSnapshot = senderState.usbTaskCount;
    senderState.lastRateMs = now;
}

void drawStatus(uint32_t now) {
    deselectExternalSpiDevices();
    M5.Display.fillScreen(BLACK);
    M5.Display.setCursor(0, 0);
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.println("CoreS3 SE PS5 CoRE LAN Sender");
    M5.Display.printf("USB:%s Parser:%s\n",
                      senderState.usbInitOk ? "OK" : "FAIL",
                      senderState.parserAttached ? "OK" : "FAIL");
    M5.Display.printf("DualSense:%s VID:%04X PID:%04X\n",
                      dualSenseConnected() ? "CONNECTED" : "DISCONNECTED",
                      senderState.vid, senderState.pid);
    M5.Display.printf("LAN:%s Link:%s Server:%s\n",
                      senderState.lanConfigOk ? "OK" : "FAIL", linkText(),
                      senderState.serverReady ? "OK" : "FAIL");
    M5.Display.printf("Local:%s\n", senderState.actualIpText.c_str());
    M5.Display.printf("Destination:%s:%u\n",
                      LanSenderConfig::kExpectedReceiverIp.toString().c_str(),
                      static_cast<unsigned>(LanSenderConfig::kTcpPort));
    M5.Display.printf("Client:%s %s\n",
                      senderState.clientConnected ? "ON" : "OFF",
                      senderState.clientIpText.c_str());
    M5.Display.printf("TX:%lu Fail:%lu\n",
                      static_cast<unsigned long>(senderState.txCount),
                      static_cast<unsigned long>(senderState.txFailCount));
    M5.Display.printf("Input valid:%u Last HID age:%lu\n",
                      inputIsValid(now) ? 1 : 0,
                      static_cast<unsigned long>(
                          senderState.validHidReportCount == 0
                              ? 0
                              : now - senderState.lastValidHidReportMs));
    M5.Display.printf("Data:%s\n", lastTxData);
    M5.Display.printf("Uptime:%lu ms\n", static_cast<unsigned long>(now));
}

void logStatus(uint32_t now) {
    const uint32_t lastHidAge =
        senderState.validHidReportCount == 0
            ? 0
            : now - senderState.lastValidHidReportMs;
    Serial.printf(
        "[STATUS] USB=%s PARSER=%s USB_TASK=0x%02X MAX_REV=0x%02X "
        "DUALSENSE=%s VID=%04X PID=%04X HID_COUNT=%llu VALID_HID_COUNT=%llu "
        "READY_DROP=%lu INPUT_VALID=%u LAST_HID_AGE_MS=%lu W5500=%s "
        "LAN_CFG=%s LINK=%s LOCAL_IP=%s DEST=%s:%u TCP_SERVER=%s CLIENT=%s "
        "CLIENT_IP=%s TX=%lu TX_FAIL=%lu TX_SKIP_LINK=%lu TX_SKIP_CLIENT=%lu "
        "TX_US_LAST=%lu TX_US_MAX=%lu LOOP_PER_SEC=%lu USB_TASK_PER_SEC=%lu "
        "UPTIME_MS=%lu RESET=%s DATA=%s\n",
        senderState.usbInitOk ? "OK" : "FAIL",
        senderState.parserAttached ? "OK" : "FAIL",
        senderState.usbTaskState, senderState.max3421eRevision,
        dualSenseConnected() ? "CONNECTED" : "DISCONNECTED", senderState.vid,
        senderState.pid,
        static_cast<unsigned long long>(senderState.hidReportCount),
        static_cast<unsigned long long>(senderState.validHidReportCount),
        static_cast<unsigned long>(senderState.readyDropCount),
        inputIsValid(now) ? 1 : 0, static_cast<unsigned long>(lastHidAge),
        senderState.w5500InitOk ? "OK" : "FAIL",
        senderState.lanConfigOk ? "OK" : "FAIL", linkText(),
        senderState.actualIpText.c_str(),
        LanSenderConfig::kExpectedReceiverIp.toString().c_str(),
        static_cast<unsigned>(LanSenderConfig::kTcpPort),
        senderState.serverReady ? "OK" : "FAIL",
        senderState.clientConnected ? "CONNECTED" : "WAITING",
        senderState.clientIpText.c_str(),
        static_cast<unsigned long>(senderState.txCount),
        static_cast<unsigned long>(senderState.txFailCount),
        static_cast<unsigned long>(senderState.txSkipNoLinkCount),
        static_cast<unsigned long>(senderState.txSkipNoClientCount),
        static_cast<unsigned long>(senderState.txLastUs),
        static_cast<unsigned long>(senderState.txMaxUs),
        static_cast<unsigned long>(senderState.loopsPerSecond),
        static_cast<unsigned long>(senderState.usbTasksPerSecond),
        static_cast<unsigned long>(now), resetReasonText(senderState.resetReason),
        lastTxData);
}

void setup() {
    senderState.resetReason = esp_reset_reason();
    resetControllerState();
    Serial.begin(115200);
    delay(100);
    prepareSharedSpiPins();
    auto cfg = M5.config();
    cfg.internal_spk = false;
    cfg.internal_mic = false;
    M5.begin(cfg);
    prepareSharedSpiPins();
    Serial2.begin(115200, SERIAL_8N1, SERIAL2_RX_PIN, SERIAL2_TX_PIN);
    Serial.println("\n=== CoreS3 SE PS5 CoRE LAN Sender ===");
    initializeUsbHost();
    initializeLan();
    const uint32_t now = millis();
    lastSendMs = now;
    lastLinkPollMs = now - LanSenderConfig::kLinkPollIntervalMs;
    lastAcceptPollMs = now;
    lastDisplayMs = now - LanSenderConfig::kDisplayIntervalMs;
    lastSerialMs = now - LanSenderConfig::kSerialIntervalMs;
    senderState.lastRateMs = now;
}

void loop() {
    ++senderState.loopCount;
    if (senderState.usbInitOk) {
        deselectExternalSpiDevices();
        Usb.Task();
        ++senderState.usbTaskCount;
    }
    M5.update();
    updateUsbIdentity();
    const uint32_t now = millis();
    updateRates(now);
    if (now - lastLinkPollMs >= LanSenderConfig::kLinkPollIntervalMs) {
        lastLinkPollMs = now;
        if (senderState.w5500InitOk) {
            deselectExternalSpiDevices();
            senderState.linkStatus = Ethernet.linkStatus();
        }
    }
    serviceTcpClient(now);
    if (now - lastSendMs >= LanSenderConfig::kSendIntervalMs) {
        lastSendMs = now;
        sendControllerState(now);
    }
    if (now - lastDisplayMs >= LanSenderConfig::kDisplayIntervalMs) {
        lastDisplayMs = now;
        drawStatus(now);
    }
    if (now - lastSerialMs >= LanSenderConfig::kSerialIntervalMs) {
        lastSerialMs = now;
        logStatus(now);
    }
}
