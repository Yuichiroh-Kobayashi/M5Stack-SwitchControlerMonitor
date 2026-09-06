#include <M5Unified.h>
#include <SPI.h>
#include <M5_Ethernet.h>
#include <EthernetUdp.h>
#include <esp_system.h>
#include "src/core_protocol/CoreProtocol.h"
#include "src/core_runtime/Deadline.h"
#include "src/numeric_ui/NumericDisplay.h"

#if !defined(BUILD_TARGET_CORES3SE)
#error "M5Stack-PS5CoRELANReceiver.ino supports only cores3se."
#endif
#ifndef PIN_SPI_SCK
#define PIN_SPI_SCK 36
#define PIN_SPI_MOSI 37
#define PIN_SPI_MISO 35
#endif
#ifndef SERIAL2_RX_PIN
#define SERIAL2_RX_PIN 18
#define SERIAL2_TX_PIN 17
#endif

namespace Config {
constexpr uint8_t kLanCs=13, kLanInt=10, kLanReset=0;
constexpr uint16_t kPort=50001;
constexpr uint32_t kPeriodMs=core_runtime::kTransportPeriodMs, kStatusPhaseMs=kPeriodMs/2, kTimeoutMs=100;
constexpr uint32_t kLinkPollMs=250, kDrawMs=100, kBatteryMs=1000,
                   kSerialMs=1000;
const IPAddress kLocalIp(192,168,50,20), kPeerIp(192,168,50,10);
const IPAddress kDns(192,168,50,1), kGateway(192,168,50,1),
                kSubnet(255,255,255,0);
uint8_t kMac[6]={0x02,0x4D,0x35,0x52,0x45,0x20};
}

static_assert(Config::kLanCs != Config::kLanReset, "LAN CS/reset conflict");
static_assert(Config::kLanCs != PIN_SPI_SCK && Config::kLanCs != PIN_SPI_MOSI &&
              Config::kLanCs != PIN_SPI_MISO, "LAN CS/SPI conflict");
static_assert(SERIAL2_RX_PIN == 18 && SERIAL2_TX_PIN == 17, "Port C pin mismatch");

using namespace core_protocol;
EthernetUDP udp;
constexpr int16_t UI_TOP_Y=15;

struct ReceivedPadState {
  bool btnA=false, btnB=false, btnX=false, btnY=false;
  bool btnL=false, btnR=false, btnZL=false, btnZR=false;
  bool btnMinus=false, btnPlus=false, btnHome=false, btnCapture=false;
  bool btnLStick=false, btnRStick=false;
  uint8_t dpad=8, lX=128, lY=128, rX=128, rY=128;
  uint8_t lTrigger=0,rTrigger=0;
} rxPadState;

struct State {
  bool selfTestOk=false, w5500=false, lanCfg=false, udpReady=false;
  EthernetLinkStatus link=Unknown;
  IPAddress actualIp;
  bool controlValid=false, controlTimeout=true, haveControl=false;
  uint16_t lastControlSeq=0, statusSeq=0;
  uint32_t lastControlMs=0, controlRx=0, controlCrcFail=0,
           controlInvalid=0, controlSeqGap=0, duplicate=0, stale=0,
           controlRxBacklog=0;
  uint32_t statusTx=0, statusTxFail=0, statusScheduleSkip=0;
  uint32_t uartTx=0, uartRxBytes=0, uartValidFrames=0, uartCrcFail=0;
  uint32_t loopCount=0, loopsPerSec=0, controlRxPerSec=0, statusTxPerSec=0,
           lastLoopSnapshot=0, lastControlRxSnapshot=0, lastStatusTxSnapshot=0;
  uint32_t maxLanOperationUs=0, maxLoopDurationUs=0;
  int battery=-1;
  esp_reset_reason_t resetReason=ESP_RST_UNKNOWN;
} state;

uint32_t lastLinkMs=0, lastDrawMs=0, lastBatteryMs=0, lastSerialMs=0,
         lastRateMs=0;
uint32_t nextStatusMs=Config::kStatusPhaseMs;
uint8_t uartBuffer[kFrameSize];
uint8_t uartLength=0;
uint8_t drawPhase=0;
numeric_ui::NumericDisplay numericDisplay;
uint32_t nextNumericSnapshotMs=0, maxSendLatenessMs=0;

const char* linkText() {
  return state.link==LinkON ? "ON" : state.link==LinkOFF ? "OFF" : "UNKNOWN";
}

const char* resetText() {
  switch (state.resetReason) {
    case ESP_RST_PANIC:return "PANIC";
    case ESP_RST_INT_WDT:case ESP_RST_TASK_WDT:case ESP_RST_WDT:return "WDT";
    case ESP_RST_BROWNOUT:return "BROWNOUT";
    case ESP_RST_SW:return "SOFTWARE";
    case ESP_RST_USB:return "USB";
    case ESP_RST_POWERON:return "POWERON";
    default:return "OTHER";
  }
}

void neutralize() { rxPadState=ReceivedPadState{}; }

void applyControl(const ControlPayload& payload) {
  const uint16_t buttons=payload.buttons;
  rxPadState.btnA=buttons&0x0001; rxPadState.btnB=buttons&0x0002;
  rxPadState.btnX=buttons&0x0004; rxPadState.btnY=buttons&0x0008;
  rxPadState.btnL=buttons&0x0010; rxPadState.btnR=buttons&0x0020;
  rxPadState.btnZL=buttons&0x0040; rxPadState.btnZR=buttons&0x0080;
  rxPadState.btnMinus=buttons&0x0100; rxPadState.btnPlus=buttons&0x0200;
  rxPadState.btnHome=buttons&0x0400; rxPadState.btnCapture=buttons&0x0800;
  rxPadState.btnLStick=buttons&0x1000; rxPadState.btnRStick=buttons&0x2000;
  rxPadState.dpad=payload.dpad;
  rxPadState.lX=payload.leftX; rxPadState.lY=payload.leftY;
  rxPadState.rX=payload.rightX; rxPadState.rY=payload.rightY;
  rxPadState.lTrigger=payload.leftTrigger; rxPadState.rTrigger=payload.rightTrigger;
}

inline void prepareForLanAccess() { digitalWrite(Config::kLanCs, HIGH); }
inline void releaseExternalSpiDevices() { digitalWrite(Config::kLanCs, HIGH); }

void prepareExternalPins() {
  pinMode(Config::kLanReset, OUTPUT);
  digitalWrite(Config::kLanReset, LOW);
  pinMode(Config::kLanCs, OUTPUT);
  digitalWrite(Config::kLanCs, HIGH);
  pinMode(Config::kLanInt, INPUT_PULLUP);
}

void updateLanOperationDuration(uint32_t startUs) {
  const uint32_t elapsedUs=micros()-startUs;
  if (elapsedUs>state.maxLanOperationUs) state.maxLanOperationUs=elapsedUs;
}

void initializeLan() {
  digitalWrite(Config::kLanReset, LOW); delay(50);
  digitalWrite(Config::kLanReset, HIGH); delay(50);
  SPI.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);
  prepareForLanAccess();
  const uint32_t startUs=micros();
  Ethernet.init(Config::kLanCs);
  Ethernet.begin(Config::kMac,Config::kLocalIp,Config::kDns,
                 Config::kGateway,Config::kSubnet);
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

void countDecodeFailure(DecodeResult result) {
  if (result==DecodeResult::BadCrc) ++state.controlCrcFail;
  else ++state.controlInvalid;
}

void processControlFrame(uint32_t now, int packetSize, int read,
                         const IPAddress& remoteIp, uint16_t remotePort,
                         const uint8_t* frame) {
  if (packetSize!=static_cast<int>(kFrameSize) ||
      read!=static_cast<int>(kFrameSize) || remoteIp!=Config::kPeerIp ||
      remotePort!=Config::kPort) {
    ++state.controlInvalid;
    return;
  }
  FrameHeader header{};
  ControlPayload payload{};
  const DecodeResult result=decodeControl(frame,kFrameSize,header,payload);
  if (result!=DecodeResult::Ok) { countDecodeFailure(result); return; }
  uint16_t missing=0;
  const SequenceRelation relation=classifySequence(
      state.haveControl,state.lastControlSeq,header.sequence,missing);
  if (relation==SequenceRelation::Duplicate) { ++state.duplicate; return; }
  if (relation==SequenceRelation::StaleOrReverse) { ++state.stale; return; }
  if (relation==SequenceRelation::ForwardGap) state.controlSeqGap+=missing;
  state.haveControl=true;
  state.lastControlSeq=header.sequence;
  state.lastControlMs=now;
  ++state.controlRx;
  state.controlValid=(payload.controlFlags&kControlInputValid)!=0;
  state.controlTimeout=false;
  if (state.controlValid) applyControl(payload); else neutralize();
  Serial2.write(frame,kFrameSize);
  ++state.uartTx;
}

void receiveAtMostTwoControlPackets(uint32_t now) {
  for (uint8_t count=0; count<2; ++count) {
    prepareForLanAccess();
    const uint32_t startUs=micros();
    const int packetSize=udp.parsePacket();
    if (packetSize<=0) {
      releaseExternalSpiDevices();
      updateLanOperationDuration(startUs);
      return;
    }
    uint8_t frame[kFrameSize];
    const int read=udp.read(frame,sizeof(frame));
    const IPAddress remoteIp=udp.remoteIP();
    const uint16_t remotePort=udp.remotePort();
    releaseExternalSpiDevices();
    updateLanOperationDuration(startUs);
    if (count>0) ++state.controlRxBacklog;
    processControlFrame(now,packetSize,read,remoteIp,remotePort,frame);
  }
}

void serviceTimeout(uint32_t now) {
  if (!state.haveControl || now-state.lastControlMs>=Config::kTimeoutMs) {
    state.controlValid=false;
    state.controlTimeout=true;
    state.haveControl=false;
    neutralize();
  }
}

void sendStatus(uint32_t now) {
  StatusPayload payload{};
  payload.statusFlags=kStatusReceiverReady|kStatusUartTxEnabled;
  if (state.controlValid) payload.statusFlags|=kStatusControlValid;
  if (state.controlTimeout) payload.statusFlags|=kStatusControlTimeout;
  if (state.link==LinkON) payload.statusFlags|=kStatusLanLinkOn;
  if (state.controlInvalid||state.controlCrcFail) payload.statusFlags|=kStatusProtocolError;
  if (state.controlSeqGap) payload.statusFlags|=kStatusSequenceGap;
  if (state.battery>=0) payload.statusFlags|=kStatusBatteryValid;
  payload.lastControlSequence=state.lastControlSeq;
  payload.controlAgeMs=state.haveControl
      ? static_cast<uint16_t>(min<uint32_t>(now-state.lastControlMs,65535))
      : 65535;
  payload.sequenceGapCount=static_cast<uint16_t>(min<uint32_t>(state.controlSeqGap,65535));
  payload.invalidFrameCount=static_cast<uint16_t>(min<uint32_t>(
      state.controlInvalid+state.controlCrcFail,65535));
  payload.receiverBatteryPercent=state.battery>=0 ? state.battery : 255;
  payload.uartState=1;
  uint8_t frame[kFrameSize];
  encodeStatus(frame,state.statusSeq,now,payload);
  bool sent=false;
  if (state.link==LinkON && state.udpReady) {
    prepareForLanAccess();
    const uint32_t startUs=micros();
    sent=udp.beginPacket(Config::kPeerIp,Config::kPort)==1 &&
         udp.write(frame,sizeof(frame))==sizeof(frame) && udp.endPacket()==1;
    releaseExternalSpiDevices();
    updateLanOperationDuration(startUs);
  }
  if (sent) { ++state.statusTx; ++state.statusSeq; }
  else ++state.statusTxFail;
}

void sendAtMostOneStatusFrame(uint32_t now) {
  const auto due=core_runtime::takeDeadline(now,nextStatusMs,Config::kPeriodMs);
  if (!due.ready) return;
  state.statusScheduleSkip+=due.skipped;
  if(due.lateness>maxSendLatenessMs) maxSendLatenessMs=due.lateness;
  sendStatus(now);
}

void serviceUartParser() {
  while (Serial2.available()) {
    const uint8_t value=Serial2.read();
    ++state.uartRxBytes;
    if (uartLength==0 && value!=kMagic0) continue;
    if (uartLength==1 && value!=kMagic1) {
      uartLength=value==kMagic0 ? 1 : 0;
      continue;
    }
    uartBuffer[uartLength++]=value;
    if (uartLength<kFrameSize) continue;
    FrameHeader header{};
    StatusPayload payload{};
    const DecodeResult result=decodeStatus(uartBuffer,sizeof(uartBuffer),header,payload);
    if (result==DecodeResult::Ok) {
      ++state.uartValidFrames;
      uartLength=0;
    } else {
      if (result==DecodeResult::BadCrc) ++state.uartCrcFail;
      memmove(uartBuffer,uartBuffer+1,kFrameSize-1);
      uartLength=kFrameSize-1;
      while (uartLength && uartBuffer[0]!=kMagic0) {
        memmove(uartBuffer,uartBuffer+1,--uartLength);
      }
    }
  }
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

void updateRates(uint32_t now) {
  if (now-lastRateMs<1000) return;
  const uint32_t elapsed=now-lastRateMs;
  state.loopsPerSec=(state.loopCount-state.lastLoopSnapshot)*1000ULL/elapsed;
  state.controlRxPerSec=(state.controlRx-state.lastControlRxSnapshot)*1000ULL/elapsed;
  state.statusTxPerSec=(state.statusTx-state.lastStatusTxSnapshot)*1000ULL/elapsed;
  state.lastLoopSnapshot=state.loopCount;
  state.lastControlRxSnapshot=state.controlRx;
  state.lastStatusTxSnapshot=state.statusTx;
  lastRateMs=now;
}

const char* controllerStateText() {
  if (state.controlValid) return "OK";
  if (state.controlTimeout) return state.link==LinkON ? "TIMEOUT" : "DISCONNECTED";
  return "NEUTRAL";
}

const char* peerStateText() {
  if (state.link!=LinkON) return "DISCONNECTED";
  return state.haveControl && !state.controlTimeout ? "OK" : "TIMEOUT";
}

void formatBattery(char* text,size_t length) {
  if (state.battery>=0) snprintf(text,length,"BAT:%3d%%",state.battery);
  else snprintf(text,length,"BAT: --%%");
}

template<typename DisplayType>
void drawReceiverInfoTo(DisplayType& target,int16_t yOffset,uint32_t now,
                        uint8_t phase) {
  char batteryText[10];
  formatBattery(batteryText,sizeof(batteryText));
  const char* dpadText="CENTER";
  int dx=0,dy=0;
  switch(rxPadState.dpad) {
    case 0:dpadText="UP";dy=-1;break;case 1:dpadText="UP-R";dx=1;dy=-1;break;
    case 2:dpadText="RIGHT";dx=1;break;case 3:dpadText="DW-R";dx=1;dy=1;break;
    case 4:dpadText="DOWN";dy=1;break;case 5:dpadText="DW-L";dx=-1;dy=1;break;
    case 6:dpadText="LEFT";dx=-1;break;case 7:dpadText="UP-L";dx=-1;dy=-1;break;
  }
  target.setTextSize(1);
  target.setTextColor(WHITE,BLACK);
  if (phase==0) {
    target.setCursor(0,UI_TOP_Y-yOffset);
    target.printf("LAN:%s UDP:%s %s",linkText(),state.udpReady?"OK":"NG",batteryText);
    target.setCursor(0,30-yOffset);
    target.printf("CTRL:%s PEER:%s",controllerStateText(),peerStateText());
    return;
  }
  if (phase==1) {
    target.setCursor(0,50-yOffset);
    target.printf("A:%d B:%d X:%d Y:%d\n",rxPadState.btnA,rxPadState.btnB,
                  rxPadState.btnX,rxPadState.btnY);
    target.printf("L:%d R:%d ZL:%d ZR:%d\n",rxPadState.btnL,rxPadState.btnR,
                  rxPadState.btnZL,rxPadState.btnZR);
    target.printf("-:%d +:%d H:%d C:%d\n",rxPadState.btnMinus,rxPadState.btnPlus,
                  rxPadState.btnHome,rxPadState.btnCapture);
    target.printf("LS:%d RS:%d DP:%s\n",rxPadState.btnLStick,rxPadState.btnRStick,dpadText);
    return;
  }
  target.setCursor(0,100-yOffset);
  target.printf("L Stick: X=%3d Y=%3d\n",rxPadState.lX,rxPadState.lY);
  target.printf("R Stick: X=%3d Y=%3d\n",rxPadState.rX,rxPadState.rY);
  int cx=60,cy=160-yOffset,r=25;
  target.drawRect(cx-r,cy-r,r*2,r*2,DARKGREY);
  target.fillCircle(cx+map(rxPadState.lX,0,255,-r,r),
                    cy+map(rxPadState.lY,0,255,-r,r),4,GREEN);
  target.setCursor(cx-10,cy+r+5);target.print("LS");
  cx=160;
  target.drawRect(cx-r,cy-r,r*2,r*2,DARKGREY);
  target.fillCircle(cx+map(rxPadState.rX,0,255,-r,r),
                    cy+map(rxPadState.rY,0,255,-r,r),4,GREEN);
  target.setCursor(cx-10,cy+r+5);target.print("RS");
  cx=260;
  target.drawRect(cx-r,cy-r,r*2,r*2,DARKGREY);
  target.drawLine(cx-r,cy,cx+r,cy,DARKGREY);
  target.drawLine(cx,cy-r,cx,cy+r,DARKGREY);
  if(rxPadState.dpad!=8)target.fillCircle(cx+dx*15,cy+dy*15,6,YELLOW);
  else target.fillCircle(cx,cy,4,DARKGREY);
  target.setCursor(cx-15,cy+r+5);target.print("DPAD");
  target.setCursor(0,215-yOffset);
  target.setTextColor(CYAN,BLACK);
  if(state.haveControl) {
    target.printf("TX:%lu RX:%lu AGE:%lums",(unsigned long)state.statusTx,
                  (unsigned long)state.controlRx,
                  (unsigned long)(now-state.lastControlMs));
  } else {
    target.printf("TX:%lu RX:%lu AGE:--ms",(unsigned long)state.statusTx,
                  (unsigned long)state.controlRx);
  }
  target.setTextColor(WHITE,BLACK);
}

void drawStatus(uint32_t now) {
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
  drawReceiverInfoTo(M5.Display,0,now,drawPhase);
  drawPhase=(drawPhase+1)%3;
}

void updateNumericUi(uint32_t now) {
  numericDisplay.text(0,state.controlValid ? "OK" : "INVALID");
  numericDisplay.text(1,state.controlTimeout ? "TIMEOUT" : "OK");
  numericDisplay.text(2,linkText());
  if(core_runtime::takeDeadline(now,nextNumericSnapshotMs,core_runtime::kDisplayPeriodMs).ready) {
    numericDisplay.pad(state.controlValid ? rxPadState : ReceivedPadState{});
    numericDisplay.number(11,state.controlRxPerSec);
    numericDisplay.number(12,state.statusTx); numericDisplay.number(13,state.controlRx);
    if(state.haveControl) numericDisplay.number(14,now-state.lastControlMs); else numericDisplay.text(14,"--");
    if(state.battery>=0) numericDisplay.number(15,state.battery); else numericDisplay.text(15,"--");
    numericDisplay.number(16,state.controlCrcFail); numericDisplay.number(17,state.controlSeqGap);
    numericDisplay.number(18,state.statusScheduleSkip); numericDisplay.number(19,maxSendLatenessMs);
    numericDisplay.text(20,"N/A"); numericDisplay.number(21,numericDisplay.maxUnitUs);
    numericDisplay.number(22,numericDisplay.deferred); numericDisplay.number(23,state.controlInvalid);
  }
  releaseExternalSpiDevices();
  numericDisplay.service(nextStatusMs);
}

void logStatus(uint32_t now) {
  Serial.printf("TRANSPORT_PERIOD_MS=%lu MAX_SEND_LATE_MS=%lu NUMERIC_UI=%u LCD_MAX_US=%lu LCD_DEFER=%lu LCD_FIELDS=%lu\n",
    (unsigned long)Config::kPeriodMs,(unsigned long)maxSendLatenessMs,PRODUCT_NUMERIC_UI,
    (unsigned long)numericDisplay.maxUnitUs,(unsigned long)numericDisplay.deferred,
    (unsigned long)numericDisplay.drawn);
  char ipText[16];
  snprintf(ipText,sizeof(ipText),"%u.%u.%u.%u",state.actualIp[0],state.actualIp[1],
           state.actualIp[2],state.actualIp[3]);
  Serial.printf("[RECEIVER] UPTIME=%lu BATTERY=%d W5500_INIT=%s LAN_CFG=%s IP_ACT=%s LINK=%s "
    "CONTROL_RX=%lu CONTROL_HZ=%lu CONTROL_VALID=%u CONTROL_TIMEOUT=%u CONTROL_CRC_FAIL=%lu CONTROL_SEQ_GAP=%lu CONTROL_RX_BACKLOG=%lu "
    "STATUS_TX=%lu STATUS_HZ=%lu STATUS_TX_FAIL=%lu STATUS_SCHEDULE_SKIP=%lu "
    "UART_TX=%lu UART_RX_BYTES=%lu UART_VALID_FRAMES=%lu UART_CRC_FAIL=%lu "
    "LOOP_PER_SEC=%lu MAX_LAN_OP_US=%lu MAX_LOOP_US=%lu RESET=%s\n",
    (unsigned long)now,state.battery,state.w5500?"OK":"FAIL",
    state.lanCfg?"OK":"FAIL",ipText,linkText(),(unsigned long)state.controlRx,
    (unsigned long)state.controlRxPerSec,state.controlValid,state.controlTimeout,
    (unsigned long)state.controlCrcFail,(unsigned long)state.controlSeqGap,
    (unsigned long)state.controlRxBacklog,(unsigned long)state.statusTx,
    (unsigned long)state.statusTxPerSec,(unsigned long)state.statusTxFail,
    (unsigned long)state.statusScheduleSkip,(unsigned long)state.uartTx,
    (unsigned long)state.uartRxBytes,(unsigned long)state.uartValidFrames,
    (unsigned long)state.uartCrcFail,(unsigned long)state.loopsPerSec,
    (unsigned long)state.maxLanOperationUs,(unsigned long)state.maxLoopDurationUs,
    resetText());
  state.maxLanOperationUs=0;
  state.maxLoopDurationUs=0;
}

void setup() {
  auto cfg=M5.config();
  cfg.internal_spk=false;
  cfg.internal_mic=false;
  M5.begin(cfg);
  Serial.begin(115200);
  prepareExternalPins();
  pinMode(SERIAL2_RX_PIN,INPUT_PULLUP);
  Serial2.begin(115200,SERIAL_8N1,SERIAL2_RX_PIN,SERIAL2_TX_PIN);
  state.resetReason=esp_reset_reason();
  neutralize();
  M5.Display.setRotation(1);
  M5.Display.fillScreen(BLACK);
  if (PRODUCT_NUMERIC_UI) Serial.printf("NUMERIC_UI_INIT=%s\n",
    numericDisplay.begin("CoRE numeric / dev") ? "OK" : "FAIL");
  state.selfTestOk=selfTest();
  Serial.printf("PROTOCOL_SELF_TEST=%s\n",state.selfTestOk?"OK":"FAIL");
  if(state.selfTestOk) initializeLan();
  char ipText[16];
  snprintf(ipText,sizeof(ipText),"%u.%u.%u.%u",state.actualIp[0],state.actualIp[1],
           state.actualIp[2],state.actualIp[3]);
  Serial.printf("W5500_INIT=%s LAN_CFG=%s IP_ACT=%s UDP=%s UART=115200,8N1,RX18,TX17\n",
    state.w5500?"OK":"FAIL",state.lanCfg?"OK":"FAIL",ipText,
    state.udpReady?"OK":"SKIP");
  updateBattery();
  const uint32_t now=millis();
  nextStatusMs=now+Config::kStatusPhaseMs;
  lastRateMs=now;
  nextNumericSnapshotMs=now;
  if (!PRODUCT_NUMERIC_UI) drawStatus(now);
}

void loop() {
  const uint32_t loopStartUs=micros();
  ++state.loopCount;
  M5.update();
  uint32_t now=millis();
  if(state.udpReady) receiveAtMostTwoControlPackets(now);
  serviceUartParser();
  serviceTimeout(now);
  if(now-lastLinkMs>=Config::kLinkPollMs) {
    lastLinkMs=now;
    if(state.w5500) pollLink();
  }
  now=millis();
  sendAtMostOneStatusFrame(now);
  if(now-lastBatteryMs>=Config::kBatteryMs) {
    lastBatteryMs=now;
    updateBattery();
  }
  updateRates(now);
  if(PRODUCT_NUMERIC_UI) updateNumericUi(millis());
  else if(now-lastDrawMs>=Config::kDrawMs) { lastDrawMs=now; drawStatus(now); }
  if(now-lastSerialMs>=Config::kSerialMs) { lastSerialMs=now; logStatus(now); }
  const uint32_t elapsedUs=micros()-loopStartUs;
  if(elapsedUs>state.maxLoopDurationUs) state.maxLoopDurationUs=elapsedUs;
}
