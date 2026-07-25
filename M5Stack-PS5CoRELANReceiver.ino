#include <M5Unified.h>
#include <SPI.h>
#include <M5_Ethernet.h>
#include <esp_system.h>

#if !defined(BUILD_TARGET_CORES3SE)
#error "M5Stack-PS5CoRELANReceiver.ino supports only the cores3se build target."
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
#ifndef USB_HOST_SHIELD_SS_GPIO
#define USB_HOST_SHIELD_SS_GPIO 1
#endif

namespace LanReceiverConfig {

constexpr uint8_t kLanCsPin = 13;
constexpr uint8_t kLanIntPin = 10;
constexpr uint8_t kLanResetPin = 0;
constexpr uint32_t kLinkPollIntervalMs = 250;
constexpr uint32_t kConnectRetryIntervalMs = 1000;
constexpr uint16_t kConnectTimeoutMs = 50;
constexpr uint32_t kReceiveTimeoutMs = 100;
constexpr uint32_t kDisplayIntervalMs = 5000;
constexpr uint32_t kSerialIntervalMs = 1000;
constexpr uint16_t kTcpPort = 12345;

// Final product defaults. The temporary single-device test changes these two
// constants to .10/.20 for its build, then restores them before final build.
const IPAddress kLocalIp(192, 168, 50, 20);
const IPAddress kSenderIp(192, 168, 50, 10);
const IPAddress kDns(192, 168, 50, 1);
const IPAddress kGateway(192, 168, 50, 1);
const IPAddress kSubnet(255, 255, 255, 0);
uint8_t kMacAddress[6] = {0x02, 0x4D, 0x35, 0x53, 0x45, 0x21};

}  // namespace LanReceiverConfig

struct ReceiverState {
    bool w5500InitOk = false;
    bool explicitConfigApplied = false;
    bool lanConfigOk = false;
    EthernetLinkStatus linkStatus = Unknown;
    String ipAfterBeginText = "N/A";
    String actualIpText = "N/A";
    String gatewayText = "N/A";
    String subnetText = "N/A";
    bool tcpConnected = false;
    uint32_t connectCount = 0;
    uint32_t connectFailCount = 0;
    uint32_t rxCount = 0;
    uint32_t invalidCount = 0;
    uint32_t overflowCount = 0;
    uint32_t timeoutCount = 0;
    uint32_t droppedSequence = 0;  // N/A for the reused protocol; remains zero.
    uint32_t lastRxMs = 0;
    bool hasValidRecord = false;
    bool inputValid = false;
    bool outputNeutral = true;
    uint32_t connectLastUs = 0;
    uint32_t connectMaxUs = 0;
    esp_reset_reason_t resetReason = ESP_RST_UNKNOWN;
};

ReceiverState receiverState;
EthernetClient tcpClient;
char lineBuffer[64] = {0};
size_t lineLength = 0;
char outputRecord[21] = "00,00,00,80,80,80,80";
uint32_t lastLinkPollMs = 0;
uint32_t lastConnectAttemptMs = 0;
uint32_t lastDisplayMs = 0;
uint32_t lastSerialMs = 0;

static_assert(LanReceiverConfig::kLanCsPin != USB_HOST_SHIELD_SS_GPIO,
              "LAN CS conflicts with USB SS");

inline void deselectExternalSpiDevices() {
    digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
    digitalWrite(LanReceiverConfig::kLanCsPin, HIGH);
}

void prepareLanPins() {
    pinMode(USB_HOST_SHIELD_SS_GPIO, OUTPUT);
    pinMode(LanReceiverConfig::kLanCsPin, OUTPUT);
    deselectExternalSpiDevices();
    pinMode(LanReceiverConfig::kLanResetPin, OUTPUT);
    digitalWrite(LanReceiverConfig::kLanResetPin, LOW);
    pinMode(LanReceiverConfig::kLanIntPin, INPUT_PULLUP);
}

const char* linkText() {
    if (receiverState.linkStatus == LinkON) return "ON";
    if (receiverState.linkStatus == LinkOFF) return "OFF";
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

int hexNibble(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    return -1;
}

bool parseCanonicalRecord(const char* line, uint8_t values[7]) {
    if (strlen(line) != 20) return false;
    for (uint8_t field = 0; field < 7; ++field) {
        const size_t offset = field * 3;
        const int high = hexNibble(line[offset]);
        const int low = hexNibble(line[offset + 1]);
        if (high < 0 || low < 0) return false;
        values[field] = static_cast<uint8_t>((high << 4) | low);
        if (field < 6 && line[offset + 2] != ',') return false;
    }
    // The reused Wireless sender only emits 0 (neutral) or hat+1 (1..8).
    return values[2] <= 8;
}

void writeSerial2Record(const char* record) {
    Serial2.print(record);
    Serial2.print("\r\n");
}

void neutralizeOutput(const char* reason, bool forceWrite = false) {
    receiverState.inputValid = false;
    receiverState.hasValidRecord = false;
    strcpy(outputRecord, "00,00,00,80,80,80,80");
    if (!receiverState.outputNeutral || forceWrite) {
        writeSerial2Record(outputRecord);
        Serial.printf("[SAFE] OUTPUT=NEUTRAL REASON=%s\n", reason);
    }
    receiverState.outputNeutral = true;
}

void acceptRecord(const char* line, uint32_t now) {
    uint8_t values[7];
    if (!parseCanonicalRecord(line, values)) {
        ++receiverState.invalidCount;
        Serial.printf("[RX] INVALID LENGTH=%u DATA=%s\n",
                      static_cast<unsigned>(strlen(line)), line);
        return;
    }
    memcpy(outputRecord, line, 21);
    writeSerial2Record(outputRecord);
    ++receiverState.rxCount;
    receiverState.lastRxMs = now;
    receiverState.hasValidRecord = true;
    receiverState.inputValid = true;
    receiverState.outputNeutral =
        values[0] == 0 && values[1] == 0 && values[2] == 0 &&
        values[3] == 0x80 && values[4] == 0x80 &&
        values[5] == 0x80 && values[6] == 0x80;
}

void processTcpInput(uint32_t now) {
    uint16_t processed = 0;
    while (tcpClient.connected() && tcpClient.available() && processed < 256) {
        ++processed;
        const char value = static_cast<char>(tcpClient.read());
        if (value == '\r') continue;
        if (value == '\n') {
            if (lineLength > 0) {
                lineBuffer[lineLength] = '\0';
                acceptRecord(lineBuffer, now);
            }
            lineLength = 0;
            continue;
        }
        if (lineLength < sizeof(lineBuffer) - 1) {
            lineBuffer[lineLength++] = value;
        } else {
            lineLength = 0;
            ++receiverState.invalidCount;
            ++receiverState.overflowCount;
        }
    }
}

void initializeLan() {
    deselectExternalSpiDevices();
    digitalWrite(LanReceiverConfig::kLanResetPin, LOW);
    delay(50);
    digitalWrite(LanReceiverConfig::kLanResetPin, HIGH);
    delay(50);
    SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);
    Ethernet.init(LanReceiverConfig::kLanCsPin);
    Ethernet.begin(LanReceiverConfig::kMacAddress, LanReceiverConfig::kLocalIp,
                   LanReceiverConfig::kDns, LanReceiverConfig::kGateway,
                   LanReceiverConfig::kSubnet);
    receiverState.w5500InitOk = Ethernet.hardwareStatus() == EthernetW5500;
    if (!receiverState.w5500InitOk) {
        Serial.println("[INIT] W5500=FAIL LAN_CFG=FAIL");
        return;
    }
    receiverState.ipAfterBeginText = Ethernet.localIP().toString();
    Ethernet.setMACAddress(LanReceiverConfig::kMacAddress);
    Ethernet.setLocalIP(LanReceiverConfig::kLocalIp);
    Ethernet.setGatewayIP(LanReceiverConfig::kGateway);
    Ethernet.setSubnetMask(LanReceiverConfig::kSubnet);
    Ethernet.setDnsServerIP(LanReceiverConfig::kDns);
    receiverState.explicitConfigApplied = true;
    const IPAddress actualIp = Ethernet.localIP();
    const IPAddress actualGateway = Ethernet.gatewayIP();
    const IPAddress actualSubnet = Ethernet.subnetMask();
    receiverState.actualIpText = actualIp.toString();
    receiverState.gatewayText = actualGateway.toString();
    receiverState.subnetText = actualSubnet.toString();
    receiverState.lanConfigOk =
        actualIp == LanReceiverConfig::kLocalIp &&
        actualGateway == LanReceiverConfig::kGateway &&
        actualSubnet == LanReceiverConfig::kSubnet;
    Ethernet.setRetransmissionTimeout(20);
    Ethernet.setRetransmissionCount(1);
    Serial.printf(
        "[INIT] W5500=OK IP_AFTER_BEGIN=%s IP_ACT=%s GATEWAY_ACT=%s "
        "SUBNET_ACT=%s EXPLICIT_CFG=%s LAN_CFG=%s SENDER=%s:%u\n",
        receiverState.ipAfterBeginText.c_str(), receiverState.actualIpText.c_str(),
        receiverState.gatewayText.c_str(), receiverState.subnetText.c_str(),
        receiverState.explicitConfigApplied ? "OK" : "SKIP",
        receiverState.lanConfigOk ? "OK" : "FAIL",
        LanReceiverConfig::kSenderIp.toString().c_str(),
        static_cast<unsigned>(LanReceiverConfig::kTcpPort));
}

void disconnectTcp(uint32_t now, const char* reason) {
    if (tcpClient) tcpClient.stop();
    tcpClient = EthernetClient();
    tcpClient.setConnectionTimeout(LanReceiverConfig::kConnectTimeoutMs);
    receiverState.tcpConnected = false;
    lineLength = 0;
    neutralizeOutput(reason);
    lastConnectAttemptMs = now;
}

void connectIfNeeded(uint32_t now) {
    if (!receiverState.lanConfigOk || receiverState.linkStatus != LinkON) {
        if (receiverState.tcpConnected) disconnectTcp(now, "LINK_OFF");
        return;
    }
    if (receiverState.tcpConnected) {
        if (!tcpClient.connected()) disconnectTcp(now, "TCP_DISCONNECT");
        return;
    }
    if (now - lastConnectAttemptMs <
        LanReceiverConfig::kConnectRetryIntervalMs) {
        return;
    }
    lastConnectAttemptMs = now;
    deselectExternalSpiDevices();
    tcpClient.setConnectionTimeout(LanReceiverConfig::kConnectTimeoutMs);
    const uint32_t startUs = micros();
    const int connected =
        tcpClient.connect(LanReceiverConfig::kSenderIp,
                          LanReceiverConfig::kTcpPort);
    const uint32_t elapsedUs = micros() - startUs;
    receiverState.connectLastUs = elapsedUs;
    receiverState.connectMaxUs = max(receiverState.connectMaxUs, elapsedUs);
    if (connected == 1) {
        receiverState.tcpConnected = true;
        ++receiverState.connectCount;
        lineLength = 0;
        Serial.printf("[TCP] CONNECTED=%s:%u\n",
                      LanReceiverConfig::kSenderIp.toString().c_str(),
                      static_cast<unsigned>(LanReceiverConfig::kTcpPort));
    } else {
        tcpClient.stop();
        ++receiverState.connectFailCount;
    }
}

void updateSafety(uint32_t now) {
    if (receiverState.inputValid &&
        now - receiverState.lastRxMs > LanReceiverConfig::kReceiveTimeoutMs) {
        ++receiverState.timeoutCount;
        neutralizeOutput("RX_TIMEOUT");
    }
}

void drawStatus(uint32_t now) {
    deselectExternalSpiDevices();
    M5.Display.fillScreen(BLACK);
    M5.Display.setCursor(0, 0);
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.println("CoreS3 SE PS5 CoRE LAN Receiver");
    M5.Display.printf("LAN:%s Link:%s\n",
                      receiverState.lanConfigOk ? "OK" : "FAIL", linkText());
    M5.Display.printf("Local:%s\n", receiverState.actualIpText.c_str());
    M5.Display.printf("Sender:%s:%u\n",
                      LanReceiverConfig::kSenderIp.toString().c_str(),
                      static_cast<unsigned>(LanReceiverConfig::kTcpPort));
    M5.Display.printf("TCP:%s RX:%lu Invalid:%lu\n",
                      receiverState.tcpConnected ? "ON" : "OFF",
                      static_cast<unsigned long>(receiverState.rxCount),
                      static_cast<unsigned long>(receiverState.invalidCount));
    M5.Display.printf("Dropped sequence:N/A (%lu)\n",
                      static_cast<unsigned long>(receiverState.droppedSequence));
    M5.Display.printf("Last RX age:%lu ms\n",
                      static_cast<unsigned long>(
                          receiverState.hasValidRecord
                              ? now - receiverState.lastRxMs
                              : 0));
    M5.Display.printf("Input valid:%u Output:%s\n",
                      receiverState.inputValid ? 1 : 0,
                      receiverState.inputValid ? "ACTIVE" : "NEUTRAL");
    M5.Display.printf("Data:%s\n", outputRecord);
    M5.Display.printf("Uptime:%lu ms\n", static_cast<unsigned long>(now));
}

void logStatus(uint32_t now) {
    Serial.printf(
        "[STATUS] W5500=%s LAN_CFG=%s LINK=%s LOCAL_IP=%s SENDER_IP=%s "
        "PORT=%u TCP=%s CONNECT=%lu CONNECT_FAIL=%lu CONNECT_US_LAST=%lu "
        "CONNECT_US_MAX=%lu RX=%lu INVALID=%lu OVERFLOW=%lu TIMEOUT=%lu "
        "DROPPED_SEQUENCE=%lu SEQUENCE=N/A LAST_RX_AGE_MS=%lu INPUT_VALID=%u "
        "OUTPUT=%s DATA=%s UPTIME_MS=%lu RESET=%s\n",
        receiverState.w5500InitOk ? "OK" : "FAIL",
        receiverState.lanConfigOk ? "OK" : "FAIL", linkText(),
        receiverState.actualIpText.c_str(),
        LanReceiverConfig::kSenderIp.toString().c_str(),
        static_cast<unsigned>(LanReceiverConfig::kTcpPort),
        receiverState.tcpConnected ? "CONNECTED" : "WAITING",
        static_cast<unsigned long>(receiverState.connectCount),
        static_cast<unsigned long>(receiverState.connectFailCount),
        static_cast<unsigned long>(receiverState.connectLastUs),
        static_cast<unsigned long>(receiverState.connectMaxUs),
        static_cast<unsigned long>(receiverState.rxCount),
        static_cast<unsigned long>(receiverState.invalidCount),
        static_cast<unsigned long>(receiverState.overflowCount),
        static_cast<unsigned long>(receiverState.timeoutCount),
        static_cast<unsigned long>(receiverState.droppedSequence),
        static_cast<unsigned long>(receiverState.hasValidRecord
                                       ? now - receiverState.lastRxMs
                                       : 0),
        receiverState.inputValid ? 1 : 0,
        receiverState.inputValid ? "ACTIVE" : "NEUTRAL", outputRecord,
        static_cast<unsigned long>(now),
        resetReasonText(receiverState.resetReason));
}

void setup() {
    receiverState.resetReason = esp_reset_reason();
    Serial.begin(115200);
    delay(100);
    prepareLanPins();
    auto cfg = M5.config();
    cfg.internal_spk = false;
    cfg.internal_mic = false;
    M5.begin(cfg);
    prepareLanPins();
    Serial2.begin(115200, SERIAL_8N1, SERIAL2_RX_PIN, SERIAL2_TX_PIN);
    tcpClient.setConnectionTimeout(LanReceiverConfig::kConnectTimeoutMs);
    neutralizeOutput("STARTUP", true);
    Serial.println("\n=== CoreS3 SE PS5 CoRE LAN Receiver ===");
    initializeLan();
    const uint32_t now = millis();
    lastLinkPollMs = now - LanReceiverConfig::kLinkPollIntervalMs;
    lastConnectAttemptMs = now - LanReceiverConfig::kConnectRetryIntervalMs;
    lastDisplayMs = now - LanReceiverConfig::kDisplayIntervalMs;
    lastSerialMs = now - LanReceiverConfig::kSerialIntervalMs;
}

void loop() {
    M5.update();
    const uint32_t now = millis();
    if (now - lastLinkPollMs >= LanReceiverConfig::kLinkPollIntervalMs) {
        lastLinkPollMs = now;
        if (receiverState.w5500InitOk) {
    deselectExternalSpiDevices();
            receiverState.linkStatus = Ethernet.linkStatus();
        }
    }
    connectIfNeeded(now);
    if (receiverState.tcpConnected) processTcpInput(now);
    updateSafety(now);
    if (now - lastDisplayMs >= LanReceiverConfig::kDisplayIntervalMs) {
        lastDisplayMs = now;
        drawStatus(now);
    }
    if (now - lastSerialMs >= LanReceiverConfig::kSerialIntervalMs) {
        lastSerialMs = now;
        logStatus(now);
    }
}
