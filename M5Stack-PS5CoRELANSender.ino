#include <M5Unified.h>
#include <SPI.h>
#include <M5_Ethernet.h>
#include <EthernetUdp.h>
#include <esp_system.h>
#include <usbhub.h>
#include <hiduniversal.h>
#include "src/core_protocol/CoreProtocol.h"
#include "src/core_runtime/Deadline.h"
#include "src/numeric_ui/NumericDisplay.h"
#include "src/controller_profile/ControllerProfile.h"

#if !defined(BUILD_TARGET_CORES3SE)
#error "M5Stack-PS5CoRELANSender.ino supports only cores3se."
#endif
#ifndef USB_HOST_SHIELD_SS_GPIO
#define USB_HOST_SHIELD_SS_GPIO 1
#endif
#ifndef USB_HOST_SHIELD_INT_GPIO
#define USB_HOST_SHIELD_INT_GPIO 14
#endif
#ifndef PIN_SPI_SCK
#define PIN_SPI_SCK 36
#define PIN_SPI_MOSI 37
#define PIN_SPI_MISO 35
#endif
#ifndef SENDER_DIAGNOSTIC_MODE
#define SENDER_DIAGNOSTIC_MODE 4
#endif
#ifndef SENDER_USB_ONLY
#define SENDER_USB_ONLY 0
#endif
#ifndef SENDER_USB_INTAKE
#define SENDER_USB_INTAKE 0
#endif
static_assert(SENDER_USB_INTAKE==0 || (SENDER_USB_INTAKE==1 && SENDER_USB_ONLY==1),
              "USB intake is available only in a USB-only diagnostic build");
#if SENDER_USB_INTAKE
#include "src/controller_profile/UsbIntake.h"
controller_profile::UsbIntake usbIntake;
#endif
static_assert(SENDER_USB_ONLY == 0 || SENDER_USB_ONLY == 1, "USB-only must be 0 or 1");
static_assert(SENDER_DIAGNOSTIC_MODE >= 1 && SENDER_DIAGNOSTIC_MODE <= 4,
              "SENDER_DIAGNOSTIC_MODE must be 1 (link), 2 (TX), 3 (RX), or 4 (full duplex)");

namespace Config {
constexpr uint8_t kLanCs = 13, kLanInt = 10, kLanReset = 0;
constexpr uint16_t kPort = 50001;
constexpr uint32_t kPeriodMs = core_runtime::kTransportPeriodMs, kTimeoutMs = 100;
constexpr uint32_t kLinkPollMs = 250, kDrawMs = 100, kBatteryMs = 1000,
                   kSerialMs = 1000;
const IPAddress kLocalIp(192, 168, 50, 10), kPeerIp(192, 168, 50, 20);
const IPAddress kDns(192, 168, 50, 1), kGateway(192, 168, 50, 1),
                kSubnet(255, 255, 255, 0);
uint8_t kMac[6] = {0x02, 0x4D, 0x35, 0x53, 0x45, 0x10};
constexpr bool kUsbOnly=SENDER_USB_ONLY==1;
constexpr bool kControlTxEnabled=!kUsbOnly && (SENDER_DIAGNOSTIC_MODE==2 || SENDER_DIAGNOSTIC_MODE==4);
constexpr bool kStatusRxEnabled=!kUsbOnly && (SENDER_DIAGNOSTIC_MODE==3 || SENDER_DIAGNOSTIC_MODE==4);
}

static_assert(Config::kLanCs != USB_HOST_SHIELD_SS_GPIO, "LAN/USB CS conflict");
static_assert(Config::kLanInt != USB_HOST_SHIELD_INT_GPIO, "LAN/USB INT conflict");
static_assert(Config::kLanReset != USB_HOST_SHIELD_SS_GPIO, "LAN reset/USB CS conflict");
static_assert(Config::kLanCs != PIN_SPI_SCK && Config::kLanCs != PIN_SPI_MOSI &&
              Config::kLanCs != PIN_SPI_MISO, "LAN CS/SPI conflict");

using namespace core_protocol;
USB Usb;
USBHub Hub(&Usb);
class SenderHID : public HIDUniversal {
 public:
  explicit SenderHID(USB* usb) : HIDUniversal(usb) {}
  uint16_t vid() const { return VID; }
  uint16_t pid() const { return PID; }
};
SenderHID Hid(&Usb);
EthernetUDP udp;
constexpr int16_t UI_TOP_Y = 15;

using controller_profile::ControllerState;
controller_profile::Input controllerInput;
const ControllerState& padState=controllerInput.value();

struct State {
  bool selfTestOk=false, usbInit=false, parser=false, hidReady=false;
  bool previousReady=false, hidStalled=false;
  uint16_t vid=0, pid=0;
  uint8_t usbTaskState=0, maxRevision=0;
  uint32_t hidReports=0, hidReportsPerSecond=0,
           hidReportDelta=0, hidAgeMs=0, hidStallCount=0, readyDrop=0;
  bool w5500=false, lanCfg=false, udpReady=false;
  EthernetLinkStatus link=Unknown;
  IPAddress actualIp;
  uint16_t controlSeq=0, lastStatusSeq=0;
  bool haveStatus=false, statusValid=false, statusTimeout=true;
  uint32_t lastStatusMs=0, controlTx=0, controlTxFail=0, statusRx=0,
           statusCrcFail=0, statusInvalid=0, statusSeqGap=0;
  uint32_t loopCount=0, usbTaskCount=0, drawCount=0,
           loopsPerSec=0, usbTasksPerSec=0, lastLoopSnapshot=0,
           lastUsbSnapshot=0, lastHidSnapshot=0;
  uint32_t maxUsbTaskDurationUs=0, maxUsbServiceGapUs=0,
           maxLanOperationUs=0, maxLoopDurationUs=0;
  uint32_t controlScheduleSkip=0, statusRxBacklog=0;
  int battery=-1;
  esp_reset_reason_t resetReason=ESP_RST_UNKNOWN;
} state;

uint32_t nextControlMs=0, lastLinkMs=0, lastDrawMs=0, lastBatteryMs=0,
         lastSerialMs=0, lastRateMs=0, lastUsbServiceUs=0;
uint8_t drawPhase=0;
numeric_ui::NumericDisplay numericDisplay;
uint32_t nextNumericSnapshotMs=0, maxSendLatenessMs=0;

void resetPad() { controllerInput.invalidate(); }

class ControllerParser : public HIDReportParser {
 public:
  void Parse(USBHID*, bool hasReportId, uint8_t len, uint8_t* report) override {
    ++state.hidReports;
    controllerInput.observe(Hid.isReady(), Hid.vid(), Hid.pid());
    const bool accepted=controllerInput.accept(hasReportId, report, len, millis());
    if (!accepted) ++rejectedReports;
#if SENDER_USB_INTAKE
    usbIntake.observe(hasReportId,len,report,accepted,controllerInput.value());
#endif
  }
  uint32_t rejectedReports=0;
} parser;

inline void prepareForUsbAccess() { digitalWrite(Config::kLanCs, HIGH); }
inline void prepareForLanAccess() { digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH); }
inline void releaseExternalSpiDevices() {
  digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
  digitalWrite(Config::kLanCs, HIGH);
}

void prepareExternalPins() {
  pinMode(Config::kLanReset, OUTPUT);
  digitalWrite(Config::kLanReset, LOW);
  pinMode(USB_HOST_SHIELD_SS_GPIO, OUTPUT);
  digitalWrite(USB_HOST_SHIELD_SS_GPIO, HIGH);
  pinMode(Config::kLanCs, OUTPUT);
  digitalWrite(Config::kLanCs, HIGH);
  pinMode(Config::kLanInt, INPUT_PULLUP);
}

void updateUsbTaskDuration(uint32_t elapsedUs) {
  if (elapsedUs > state.maxUsbTaskDurationUs) state.maxUsbTaskDurationUs = elapsedUs;
}

void updateLanOperationDuration(uint32_t startUs) {
  const uint32_t elapsedUs = micros() - startUs;
  if (elapsedUs > state.maxLanOperationUs) state.maxLanOperationUs = elapsedUs;
}

void serviceUsbTask() {
  if (!state.usbInit) return;
  prepareForUsbAccess();
  const uint32_t startUs = micros();
  if (lastUsbServiceUs != 0) {
    const uint32_t gapUs = startUs - lastUsbServiceUs;
    if (gapUs > state.maxUsbServiceGapUs) state.maxUsbServiceGapUs = gapUs;
  }
  lastUsbServiceUs = startUs;
  Usb.Task();
  const uint32_t elapsedUs = micros() - startUs;
  releaseExternalSpiDevices();
  ++state.usbTaskCount;
  updateUsbTaskDuration(elapsedUs);
}

const char* linkText() {
  return state.link==LinkON ? "ON" : state.link==LinkOFF ? "OFF" : "UNKNOWN";
}

const char* resetText() {
  switch (state.resetReason) {
    case ESP_RST_PANIC: return "PANIC";
    case ESP_RST_INT_WDT: case ESP_RST_TASK_WDT: case ESP_RST_WDT: return "WDT";
    case ESP_RST_BROWNOUT: return "BROWNOUT";
    case ESP_RST_SW: return "SOFTWARE";
    case ESP_RST_USB: return "USB";
    case ESP_RST_POWERON: return "POWERON";
    default: return "OTHER";
  }
}

bool supportedController() {
  return state.usbInit && state.parser && state.hidReady &&
         controllerInput.connected();
}

bool inputValid(uint32_t now) {
  return supportedController() && controllerInput.valid(now);
}

void initializeUsb() {
  releaseExternalSpiDevices();
  prepareForUsbAccess();
  const int result=Usb.Init();
  state.usbInit=result!=-1;
  if (state.usbInit) {
    state.parser=Hid.SetReportParser(0, &parser);
    state.maxRevision=Usb.regRd(rREVISION);
  }
  releaseExternalSpiDevices();
  Serial.printf("USB_INIT=%s PARSER=%s MAX_REV=%02X\n",
                state.usbInit?"OK":"FAIL", state.parser?"OK":"FAIL",
                state.maxRevision);
}

void updateUsbIdentity() {
  state.usbTaskState=state.usbInit ? Usb.getUsbTaskState() : 0;
  state.hidReady=state.usbInit && Hid.isReady();
  if (state.hidReady != state.previousReady) {
    if (state.previousReady && !state.hidReady) ++state.readyDrop;
    resetPad();
  }
  state.previousReady=state.hidReady;
  if (state.hidReady) {
    state.vid=Hid.vid(); state.pid=Hid.pid();
  } else {
    state.vid=state.pid=0;
  }
  controllerInput.observe(state.hidReady, state.vid, state.pid);
}

void initializeLan() {
  digitalWrite(Config::kLanReset, LOW); delay(50);
  digitalWrite(Config::kLanReset, HIGH); delay(50);
  SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);
  prepareForLanAccess();
  const uint32_t startUs=micros();
  Ethernet.init(Config::kLanCs);
  Ethernet.begin(Config::kMac, Config::kLocalIp, Config::kDns,
                 Config::kGateway, Config::kSubnet);
  state.w5500=Ethernet.hardwareStatus()==EthernetW5500;
  if (state.w5500) {
    Ethernet.setMACAddress(Config::kMac);
    Ethernet.setLocalIP(Config::kLocalIp);
    Ethernet.setGatewayIP(Config::kGateway);
    Ethernet.setSubnetMask(Config::kSubnet);
    Ethernet.setDnsServerIP(Config::kDns);
    state.actualIp=Ethernet.localIP();
    state.lanCfg=state.actualIp==Config::kLocalIp &&
                 Ethernet.gatewayIP()==Config::kGateway &&
                 Ethernet.subnetMask()==Config::kSubnet;
    if (state.lanCfg) state.udpReady=udp.begin(Config::kPort)==1;
  }
  releaseExternalSpiDevices();
  updateLanOperationDuration(startUs);
}

void sendControl(uint32_t now) {
  const bool valid=inputValid(now);
  const ControllerState effectiveState=valid ? padState : ControllerState{};
  ControlPayload payload=neutralControl();
  payload.controlFlags=0;
  if (supportedController()) payload.controlFlags|=kControlControllerConnected;
  if (state.link==LinkON) payload.controlFlags|=kControlLanLinkOn;
  if (state.battery>=0) {
    payload.controlFlags|=kControlBatteryValid;
    payload.senderBatteryPercent=state.battery;
  }
  if (valid) {
    payload.controlFlags|=kControlInputValid;
    payload.buttons=controller_profile::buttons(effectiveState); payload.dpad=effectiveState.dpad;
    payload.leftX=effectiveState.lX; payload.leftY=effectiveState.lY;
    payload.rightX=effectiveState.rX; payload.rightY=effectiveState.rY;
    payload.leftTrigger=effectiveState.lTrigger;
    payload.rightTrigger=effectiveState.rTrigger;
  }
  uint8_t frame[kFrameSize];
  encodeControl(frame, state.controlSeq, now, payload);
  bool sent=false;
  if (state.link==LinkON && state.udpReady) {
    prepareForLanAccess();
    const uint32_t startUs=micros();
    sent=udp.beginPacket(Config::kPeerIp, Config::kPort)==1 &&
         udp.write(frame, sizeof(frame))==sizeof(frame) &&
         udp.endPacket()==1;
    releaseExternalSpiDevices();
    updateLanOperationDuration(startUs);
  }
  if (sent) { ++state.controlTx; ++state.controlSeq; }
  else ++state.controlTxFail;
}

void receiveOneStatusPacket(uint32_t now) {
  prepareForLanAccess();
  const uint32_t startUs=micros();
  const int packetSize=udp.parsePacket();
  if (packetSize<=0) {
    releaseExternalSpiDevices();
    updateLanOperationDuration(startUs);
    return;
  }
  uint8_t frame[kFrameSize];
  const int read=udp.read(frame, sizeof(frame));
  const IPAddress remoteIp=udp.remoteIP();
  const uint16_t remotePort=udp.remotePort();
  releaseExternalSpiDevices();
  updateLanOperationDuration(startUs);

  if (state.haveStatus && now==state.lastStatusMs) {
    ++state.statusRxBacklog;
  }
  if (packetSize!=static_cast<int>(kFrameSize) ||
      read!=static_cast<int>(kFrameSize) || remoteIp!=Config::kPeerIp ||
      remotePort!=Config::kPort) {
    ++state.statusInvalid;
    return;
  }
  FrameHeader header{};
  StatusPayload payload{};
  const DecodeResult result=decodeStatus(frame, sizeof(frame), header, payload);
  if (result!=DecodeResult::Ok) {
    if (result==DecodeResult::BadCrc) ++state.statusCrcFail;
    else ++state.statusInvalid;
    return;
  }
  uint16_t missing=0;
  const SequenceRelation relation=classifySequence(
      state.haveStatus, state.lastStatusSeq, header.sequence, missing);
  if (relation==SequenceRelation::Duplicate ||
      relation==SequenceRelation::StaleOrReverse) return;
  if (relation==SequenceRelation::ForwardGap) state.statusSeqGap+=missing;
  state.haveStatus=true;
  state.lastStatusSeq=header.sequence;
  state.lastStatusMs=now;
  ++state.statusRx;
  state.statusValid=(payload.statusFlags&kStatusReceiverReady)!=0;
  state.statusTimeout=false;
}

void updateStatusTimeout(uint32_t now) {
  if (!state.haveStatus || now-state.lastStatusMs>=Config::kTimeoutMs) {
    state.statusTimeout=true;
    state.statusValid=false;
    state.haveStatus=false;
  }
}

void updateHidStall(uint32_t now) {
  state.hidAgeMs=(state.hidReady && controllerInput.haveReport()) ? now-controllerInput.lastReportMs() : 0;
  const bool stalled=state.hidReady && controllerInput.haveReport() &&
                     now-controllerInput.lastReportMs()>=250;
  if (stalled != state.hidStalled) {
    Serial.printf("HID_STALL=%s\n", stalled ? "ENTER" : "EXIT");
    if (stalled) ++state.hidStallCount;
    state.hidStalled=stalled;
  }
}

void updateRates(uint32_t now) {
  if (now-lastRateMs<1000) return;
  const uint32_t elapsed=now-lastRateMs;
  state.hidReportDelta=state.hidReports-state.lastHidSnapshot;
  state.hidReportsPerSecond=state.hidReportDelta*1000ULL/elapsed;
  state.loopsPerSec=(state.loopCount-state.lastLoopSnapshot)*1000ULL/elapsed;
  state.usbTasksPerSec=(state.usbTaskCount-state.lastUsbSnapshot)*1000ULL/elapsed;
  state.lastHidSnapshot=state.hidReports;
  state.lastLoopSnapshot=state.loopCount;
  state.lastUsbSnapshot=state.usbTaskCount;
  lastRateMs=now;
}

void updateBattery() {
  const int value=M5.Power.getBatteryLevel();
  state.battery=value>=0 && value<=100 ? value : -1;
}

void pollLink() {
  prepareForLanAccess();
  const uint32_t startUs=micros();
  state.link=Ethernet.linkStatus();
  releaseExternalSpiDevices();
  updateLanOperationDuration(startUs);
}

const char* controllerStateText(uint32_t now) {
  if (!state.hidReady) return "DISCONNECTED";
  if (!supportedController()) return "UNSUPPORTED";
  if (inputValid(now)) return "OK";
  return controllerInput.haveReport() ? "TIMEOUT" : "NEUTRAL";
}

const char* peerStateText() {
  if (state.link!=LinkON) return "DISCONNECTED";
  if (!state.haveStatus || state.statusTimeout) return "TIMEOUT";
  return state.statusValid ? "OK" : "NEUTRAL";
}

void formatBattery(char* text, size_t length) {
  if (state.battery>=0) snprintf(text, length, "BAT:%3d%%", state.battery);
  else snprintf(text, length, "BAT: --%%");
}

template<typename DisplayType>
void drawControllerInfoTo(DisplayType& target, int16_t yOffset, uint32_t now,
                          uint8_t phase) {
  const ControllerState displayState=inputValid(now) ? padState : ControllerState{};
  char batteryText[10];
  formatBattery(batteryText, sizeof(batteryText));
  const char* dpadText="CENTER";
  int dx=0, dy=0;
  switch(displayState.dpad) {
    case 0:dpadText="UP";dy=-1;break; case 1:dpadText="UP-R";dx=1;dy=-1;break;
    case 2:dpadText="RIGHT";dx=1;break; case 3:dpadText="DW-R";dx=1;dy=1;break;
    case 4:dpadText="DOWN";dy=1;break; case 5:dpadText="DW-L";dx=-1;dy=1;break;
    case 6:dpadText="LEFT";dx=-1;break; case 7:dpadText="UP-L";dx=-1;dy=-1;break;
  }
  target.setTextSize(1);
  target.setTextColor(WHITE, BLACK);
  if (phase==0) {
    target.setCursor(0, UI_TOP_Y-yOffset);
    target.printf("LAN:%s UDP:%s %s", linkText(), state.udpReady?"OK":"NG", batteryText);
    target.setCursor(0, 30-yOffset);
    target.printf("CTRL:%s PEER:%s", controllerStateText(now), peerStateText());
    return;
  }
  if (phase==1) {
    target.setCursor(0, 50-yOffset);
    target.printf("SQ:%d CR:%d CI:%d TR:%d\n", displayState.btnX, displayState.btnA,
                  displayState.btnB, displayState.btnY);
    target.printf("L1:%d R1:%d L2:%d R2:%d\n", displayState.btnL, displayState.btnR,
                  displayState.btnZL, displayState.btnZR);
    target.printf("SH:%d OP:%d PS:%d TP:%d\n", displayState.btnMinus,
                  displayState.btnPlus, displayState.btnHome, displayState.btnCapture);
    target.printf("LS:%d RS:%d DP:%s\n", displayState.btnLStick,
                  displayState.btnRStick, dpadText);
    return;
  }
  target.setCursor(0, 100-yOffset);
  target.printf("L Stick: X=%3d Y=%3d\n", displayState.lX, displayState.lY);
  target.printf("R Stick: X=%3d Y=%3d\n", displayState.rX, displayState.rY);
  int cx=60, cy=160-yOffset, r=25;
  target.drawRect(cx-r, cy-r, r*2, r*2, DARKGREY);
  target.fillCircle(cx+map(displayState.lX,0,255,-r,r),
                    cy+map(displayState.lY,0,255,-r,r),4,GREEN);
  target.setCursor(cx-10,cy+r+5); target.print("LS");
  cx=160;
  target.drawRect(cx-r,cy-r,r*2,r*2,DARKGREY);
  target.fillCircle(cx+map(displayState.rX,0,255,-r,r),
                    cy+map(displayState.rY,0,255,-r,r),4,GREEN);
  target.setCursor(cx-10,cy+r+5); target.print("RS");
  cx=260;
  target.drawRect(cx-r,cy-r,r*2,r*2,DARKGREY);
  target.drawLine(cx-r,cy,cx+r,cy,DARKGREY);
  target.drawLine(cx,cy-r,cx,cy+r,DARKGREY);
  if(displayState.dpad!=8) target.fillCircle(cx+dx*15,cy+dy*15,6,YELLOW);
  else target.fillCircle(cx,cy,4,DARKGREY);
  target.setCursor(cx-15,cy+r+5); target.print("DPAD");
  target.setCursor(0,215-yOffset);
  target.setTextColor(CYAN,BLACK);
  if (state.haveStatus) {
    target.printf("TX:%lu RX:%lu AGE:%lums", (unsigned long)state.controlTx,
                  (unsigned long)state.statusRx,
                  (unsigned long)(now-state.lastStatusMs));
  } else {
    target.printf("TX:%lu RX:%lu AGE:--ms", (unsigned long)state.controlTx,
                  (unsigned long)state.statusRx);
  }
  target.setTextColor(WHITE,BLACK);
}

void drawControllerInfo(uint32_t now) {
  serviceUsbTask();
  if (drawPhase==0) {
    M5.Display.fillRect(0,15,320,27,BLACK);
  } else if (drawPhase==1) {
    M5.Display.fillRect(0,50,230,64,BLACK);
  } else {
    M5.Display.fillRect(0,100,230,22,BLACK);
    M5.Display.fillRect(34,134,53,63,BLACK);
    M5.Display.fillRect(134,134,53,63,BLACK);
    M5.Display.fillRect(234,134,53,63,BLACK);
    M5.Display.fillRect(0,212,320,16,BLACK);
  }
  drawControllerInfoTo(M5.Display,0,now,drawPhase);
  drawPhase=(drawPhase+1)%3;
  ++state.drawCount;
}

void logStatus(uint32_t now) {
#if SENDER_USB_INTAKE
  usbIntake.log(now,controllerInput.effective(now),inputValid(now));
#endif
  Serial.printf("TRANSPORT_PERIOD_MS=%lu MAX_SEND_LATE_MS=%lu NUMERIC_UI=%u LCD_MAX_US=%lu LCD_DEFER=%lu LCD_FIELDS=%lu\n",
    (unsigned long)Config::kPeriodMs,(unsigned long)maxSendLatenessMs,PRODUCT_NUMERIC_UI,
    (unsigned long)numericDisplay.maxUnitUs,(unsigned long)numericDisplay.deferred,
    (unsigned long)numericDisplay.drawn);
  Serial.printf("CONTROLLER_PROFILE=%s HID_REJECTED=%lu USB_ONLY=%u\n",
    controller_profile::name(controllerInput.profile()),
    (unsigned long)parser.rejectedReports, Config::kUsbOnly);
  char ipText[16];
  snprintf(ipText,sizeof(ipText),"%u.%u.%u.%u",state.actualIp[0],state.actualIp[1],
           state.actualIp[2],state.actualIp[3]);
  Serial.printf("[SENDER] MODE=%c UPTIME=%lu USB_INIT=%s PARSER=%s HID_READY=%u VID=%04X PID=%04X "
    "USB_STATE=%02X USB_INT=%d MAX_REV=%02X HID_READY_DROP=%lu INPUT_VALID=%u BATTERY=%d W5500_INIT=%s LAN_CFG=%s IP_ACT=%s LINK=%s "
    "HID_REPORTS=%lu HID_REPORT_DELTA=%lu HID_REPORT_TOTAL=%lu HID_AGE_MS=%lu HID_STALL=%lu DRAW_COUNT=%lu "
    "CONTROL_TX=%lu CONTROL_TX_FAIL=%lu STATUS_RX=%lu STATUS_VALID=%u STATUS_TIMEOUT=%u STATUS_CRC_FAIL=%lu STATUS_SEQ_GAP=%lu "
    "USB_TASK_PER_SEC=%lu LOOP_PER_SEC=%lu MAX_USB_TASK_US=%lu MAX_USB_GAP_US=%lu MAX_LAN_OP_US=%lu MAX_LOOP_US=%lu "
    "CONTROL_SCHEDULE_SKIP=%lu STATUS_RX_BACKLOG=%lu RESET=%s\n",
    'A'+SENDER_DIAGNOSTIC_MODE-1,(unsigned long)now,state.usbInit?"OK":"FAIL",state.parser?"OK":"FAIL",
    state.hidReady,state.vid,state.pid,state.usbTaskState,
    digitalRead(USB_HOST_SHIELD_INT_GPIO),state.maxRevision,
    (unsigned long)state.readyDrop,inputValid(now),
    state.battery,state.w5500?"OK":"FAIL",state.lanCfg?"OK":"FAIL",ipText,linkText(),
    (unsigned long)state.hidReportsPerSecond,(unsigned long)state.hidReportDelta,
    (unsigned long)state.hidReports,(unsigned long)state.hidAgeMs,
    (unsigned long)state.hidStallCount,(unsigned long)state.drawCount,
    (unsigned long)state.controlTx,(unsigned long)state.controlTxFail,
    (unsigned long)state.statusRx,state.statusValid,state.statusTimeout,
    (unsigned long)state.statusCrcFail,(unsigned long)state.statusSeqGap,
    (unsigned long)state.usbTasksPerSec,(unsigned long)state.loopsPerSec,
    (unsigned long)state.maxUsbTaskDurationUs,(unsigned long)state.maxUsbServiceGapUs,
    (unsigned long)state.maxLanOperationUs,(unsigned long)state.maxLoopDurationUs,
    (unsigned long)state.controlScheduleSkip,(unsigned long)state.statusRxBacklog,
    resetText());
  state.maxUsbTaskDurationUs=0;
  state.maxUsbServiceGapUs=0;
  state.maxLanOperationUs=0;
  state.maxLoopDurationUs=0;
}

void sendAtMostOneControlFrame(uint32_t now) {
  const auto due=core_runtime::takeDeadline(now,nextControlMs,Config::kPeriodMs);
  if (!due.ready) return;
  if (Config::kControlTxEnabled) {
    state.controlScheduleSkip+=due.skipped;
    if(due.lateness>maxSendLatenessMs) maxSendLatenessMs=due.lateness;
    sendControl(now);
  }
}

void updateNumericUi(uint32_t now) {
  numericDisplay.text(0,!state.hidReady ? "OFF" : !supportedController() ? "UNSUP" : inputValid(now) ? "OK" : "INVALID");
  numericDisplay.text(1,state.statusTimeout ? "TIMEOUT" : state.statusValid ? "OK" : "INVALID");
  numericDisplay.text(2,linkText());
  if(core_runtime::takeDeadline(now,nextNumericSnapshotMs,core_runtime::kDisplayPeriodMs).ready) {
    numericDisplay.pad(controllerInput.effective(now));
    numericDisplay.number(11,state.hidReportsPerSecond);
    numericDisplay.number(12,state.controlTx); numericDisplay.number(13,state.statusRx);
    if(state.haveStatus) numericDisplay.number(14,now-state.lastStatusMs); else numericDisplay.text(14,"--");
    if(state.battery>=0) numericDisplay.number(15,state.battery); else numericDisplay.text(15,"--");
    numericDisplay.number(16,state.statusCrcFail); numericDisplay.number(17,state.statusSeqGap);
    numericDisplay.number(18,state.controlScheduleSkip); numericDisplay.number(19,maxSendLatenessMs);
    numericDisplay.number(20,state.maxUsbServiceGapUs); numericDisplay.number(21,numericDisplay.maxUnitUs);
    numericDisplay.number(22,numericDisplay.deferred); numericDisplay.number(23,parser.rejectedReports);
  }
  releaseExternalSpiDevices();
  if(numericDisplay.service(nextControlMs)) ++state.drawCount;
}

void updateDisplayAndDiagnostics(uint32_t now) {
  updateStatusTimeout(now);
  updateHidStall(now);
  if (now-lastLinkMs>=Config::kLinkPollMs) {
    lastLinkMs=now;
    if (state.w5500) pollLink();
  }
  if (now-lastBatteryMs>=Config::kBatteryMs) {
    lastBatteryMs=now;
    updateBattery();
  }
  updateRates(now);
  const bool drawDue=now-lastDrawMs>=Config::kDrawMs;
  if (PRODUCT_NUMERIC_UI) {
    serviceUsbTask();
    updateUsbIdentity();
    updateNumericUi(millis());
  } else if (drawDue) {
    lastDrawMs=now;
    drawControllerInfo(now);
  } else {
    serviceUsbTask();
  }
  if (now-lastSerialMs>=Config::kSerialMs) {
    lastSerialMs=now;
    logStatus(now);
  }
}

void setup() {
  auto cfg=M5.config();
  cfg.internal_spk=false;
  cfg.internal_mic=false;
  M5.begin(cfg);
  Serial.begin(115200);
  prepareExternalPins();
  state.resetReason=esp_reset_reason();
  resetPad();
  M5.Display.setRotation(1);
  M5.Display.fillScreen(BLACK);
  if (PRODUCT_NUMERIC_UI) Serial.printf("NUMERIC_UI_INIT=%s\n",
    numericDisplay.begin("CoRE numeric / dev") ? "OK" : "FAIL");
  state.selfTestOk=selfTest();
  Serial.printf("PROTOCOL_SELF_TEST=%s\n",state.selfTestOk?"OK":"FAIL");
  if (state.selfTestOk) {
    if (!Config::kUsbOnly) initializeLan();
    else SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);
    initializeUsb();
  }
  char ipText[16];
  snprintf(ipText,sizeof(ipText),"%u.%u.%u.%u",state.actualIp[0],state.actualIp[1],
           state.actualIp[2],state.actualIp[3]);
  Serial.printf("W5500_INIT=%s LAN_CFG=%s IP_ACT=%s UDP=%s\n",
                state.w5500?"OK":"FAIL",state.lanCfg?"OK":"FAIL",ipText,
                state.udpReady?"OK":"SKIP");
  updateBattery();
  const uint32_t now=millis();
  nextControlMs=now;
  lastRateMs=now;
  nextNumericSnapshotMs=now;
  if (!PRODUCT_NUMERIC_UI) drawControllerInfo(now);
}

void loop() {
  const uint32_t loopStartUs=micros();
  ++state.loopCount;
  serviceUsbTask();
  M5.update();
  uint32_t now=millis();
  updateUsbIdentity();
  if (state.udpReady && Config::kStatusRxEnabled) receiveOneStatusPacket(now);
#if SENDER_USB_INTAKE
  if(now>=5000 && inputValid(now)) {
    prepareForUsbAccess();
    usbIntake.readDescriptorsOnce(Usb,Hid.GetAddress());
    releaseExternalSpiDevices();
  }
#endif
  serviceUsbTask();
  now=millis();
  updateUsbIdentity();
  sendAtMostOneControlFrame(now);
  now=millis();
  updateDisplayAndDiagnostics(now);
  const uint32_t elapsedUs=micros()-loopStartUs;
  if (elapsedUs>state.maxLoopDurationUs) state.maxLoopDurationUs=elapsedUs;
}
