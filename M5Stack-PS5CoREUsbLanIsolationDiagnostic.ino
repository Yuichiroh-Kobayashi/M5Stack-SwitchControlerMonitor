#include <M5Unified.h>
#include <SPI.h>
#include <M5_Ethernet.h>
#include <EthernetUdp.h>
#include <esp_system.h>
#include <usbhub.h>
#include <hiduniversal.h>
#include "src/core_protocol/CoreProtocol.h"

#if !defined(BUILD_TARGET_CORES3SE)
#error "This diagnostic supports only CoreS3 SE."
#endif
#ifndef USB_LAN_TEST_MODE
#define USB_LAN_TEST_MODE 0
#endif
#ifndef USB_LAN_INIT_ORDER
#define USB_LAN_INIT_ORDER 0
#endif
#ifndef USB_LAN_TEST_DURATION_MS
#define USB_LAN_TEST_DURATION_MS 600000UL
#endif
#ifndef USB_TARGET_READY_TIMEOUT_MS
#define USB_TARGET_READY_TIMEOUT_MS 0UL
#endif
#ifndef USB_POWERED_HUB_TEST
#define USB_POWERED_HUB_TEST 0
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

static_assert(USB_LAN_TEST_MODE >= 0 && USB_LAN_TEST_MODE <= 7,
              "USB_LAN_TEST_MODE must be 0..7");
static_assert(USB_LAN_INIT_ORDER >= 0 && USB_LAN_INIT_ORDER <= 2,
              "USB_LAN_INIT_ORDER must be 0..2");

namespace Config {
constexpr uint8_t kLanCs=13, kLanInt=10, kLanReset=0;
constexpr uint16_t kPort=50001;
constexpr uint32_t kPeriodMs=20, kLinkPollMs=250, kDisplayMs=100,
                   kSerialMs=1000, kPostDropMs=30000;
const IPAddress kLocalIp(192,168,50,10), kPeerIp(192,168,50,20);
const IPAddress kDns(192,168,50,1), kGateway(192,168,50,1),
                kSubnet(255,255,255,0);
uint8_t kMac[6]={0x02,0x4D,0x35,0x55,0x53,0x42};
constexpr bool kDisplayEnabled=USB_LAN_TEST_MODE==1 || USB_LAN_TEST_MODE==2 ||
                               USB_LAN_TEST_MODE==5 || USB_LAN_TEST_MODE==7;
constexpr bool kLanInitEnabled=USB_LAN_TEST_MODE>=3;
constexpr bool kLinkPollEnabled=USB_LAN_TEST_MODE>=4;
constexpr bool kFullDuplexEnabled=USB_LAN_TEST_MODE>=6;
}

using namespace core_protocol;
USB Usb;
USBHub Hub(&Usb);
class DiagnosticHID : public HIDUniversal {
 public:
  explicit DiagnosticHID(USB* usb):HIDUniversal(usb){}
  uint16_t vid() const { return VID; }
  uint16_t pid() const { return PID; }
  uint8_t address() const { return bAddress; }
};
DiagnosticHID Hid(&Usb);
EthernetUDP udp;

struct State {
  bool usbInit=false, parser=false, hidReady=false, previousHidReady=false;
  bool w5500Init=false, lanConfig=false, udpReady=false;
  bool dropDetected=false, stopped=false, spiCorruptionSuspected=false;
  bool everRunning=false, everHidReady=false;
  bool poweredHubTargetReady=false, everPoweredHubTargetReady=false;
  bool targetTimeoutReported=false;
  uint8_t usbTaskState=0, previousUsbTaskState=0, maxRevision=0;
  uint16_t vid=0, pid=0, controlSequence=0;
  EthernetLinkStatus link=Unknown;
  IPAddress actualIp;
  uint32_t startMs=0, dropMs=0, stopMs=0, lastSerialMs=0,
           lastLinkMs=0, lastDisplayMs=0, nextControlMs=0;
  uint32_t hidReportTotal=0, hidReportDelta=0, lastHidSnapshot=0,
           hidReadyDrop=0, usbTaskCount=0, lastUsbTaskSnapshot=0,
           usbTaskPerSec=0, lastRateMs=0, lastUsbServiceUs=0,
           maxUsbGapUs=0, maxUsbTaskUs=0;
  uint32_t maxRevMismatch=0, maxHrslMismatch=0,
           maxSpiReadMismatch=0, linkPollCount=0,
           displayUpdateCount=0, controlTx=0, statusRx=0;
  uint8_t lastRevBefore=0, lastRevAfter=0,
          lastHrslBefore=0, lastHrslAfter=0;
  esp_reset_reason_t resetReason=ESP_RST_UNKNOWN;
} state;

class DiagnosticParser : public HIDReportParser {
 public:
  void Parse(USBHID*,bool,uint8_t,uint8_t*) override {
    ++state.hidReportTotal;
  }
} parser;

struct InventoryEntry {
  uint8_t address=0, parent=0, port=0;
  bool hub=false;
};
InventoryEntry inventory[USB_NUMDEVICES];
uint8_t inventoryCount=0;

void collectInventoryDevice(UsbDevice* device){
  if(!device || inventoryCount>=USB_NUMDEVICES)return;
  InventoryEntry& entry=inventory[inventoryCount++];
  entry.address=device->address.devAddress;
  entry.parent=device->address.bmParent;
  entry.port=device->address.bmAddress;
  entry.hub=device->address.bmHub;
}

struct TripleRead {
  uint8_t a=0, b=0, c=0;
  bool mismatch=false;
};

struct MaxSnapshot {
  TripleRead revision;
  TripleRead hrsl;
  uint8_t mode=0, hctl=0, hirq=0, usbirq=0, pinctl=0;
  int intGpio=0;
  uint8_t usbTaskState=0;
  bool hidReady=false;
  uint16_t vid=0, pid=0;
  uint32_t millisValue=0, microsValue=0;
};

// Keep Arduino's generated function prototypes from referring to TripleRead
// before the sketch-local type is declared.
TripleRead readTriple(uint8_t reg,bool revision);
MaxSnapshot captureMaxSnapshot();
void printSnapshot(const char* reason,const MaxSnapshot& value);

inline void prepareForUsbAccess(){digitalWrite(Config::kLanCs,HIGH);}
inline void prepareForLanAccess(){digitalWrite(USB_HOST_SHIELD_SS_GPIO,HIGH);}
inline void releaseExternalSpiDevices(){
  digitalWrite(USB_HOST_SHIELD_SS_GPIO,HIGH);
  digitalWrite(Config::kLanCs,HIGH);
}

void prepareExternalPins(){
  pinMode(Config::kLanReset,OUTPUT);
  digitalWrite(Config::kLanReset,LOW);
  pinMode(USB_HOST_SHIELD_SS_GPIO,OUTPUT);
  digitalWrite(USB_HOST_SHIELD_SS_GPIO,HIGH);
  pinMode(Config::kLanCs,OUTPUT);
  digitalWrite(Config::kLanCs,HIGH);
  pinMode(Config::kLanInt,INPUT_PULLUP);
}

const char* resetText(){
  switch(state.resetReason){
    case ESP_RST_POWERON:return "POWERON";
    case ESP_RST_SW:return "SOFTWARE";
    case ESP_RST_PANIC:return "PANIC";
    case ESP_RST_INT_WDT:case ESP_RST_TASK_WDT:case ESP_RST_WDT:return "WDT";
    case ESP_RST_BROWNOUT:return "BROWNOUT";
    case ESP_RST_USB:return "USB";
    default:return "OTHER";
  }
}

TripleRead readTriple(uint8_t reg,bool revision){
  TripleRead value{};
  prepareForUsbAccess();
  value.a=Usb.regRd(reg);
  value.b=Usb.regRd(reg);
  value.c=Usb.regRd(reg);
  releaseExternalSpiDevices();
  value.mismatch=value.a!=value.b || value.a!=value.c;
  if(value.mismatch){
    ++state.maxSpiReadMismatch;
    if(revision)++state.maxRevMismatch;else ++state.maxHrslMismatch;
  }
  return value;
}

uint8_t readMaxRegister(uint8_t reg){
  prepareForUsbAccess();
  const uint8_t value=Usb.regRd(reg);
  releaseExternalSpiDevices();
  return value;
}

MaxSnapshot captureMaxSnapshot(){
  MaxSnapshot value{};
  value.revision=readTriple(rREVISION,true);
  value.hrsl=readTriple(rHRSL,false);
  value.mode=readMaxRegister(rMODE);
  value.hctl=readMaxRegister(rHCTL);
  value.hirq=readMaxRegister(rHIRQ);
  value.usbirq=readMaxRegister(rUSBIRQ);
  value.pinctl=readMaxRegister(rPINCTL);
  value.intGpio=digitalRead(USB_HOST_SHIELD_INT_GPIO);
  value.usbTaskState=state.usbTaskState;
  value.hidReady=state.hidReady;
  value.vid=state.vid;
  value.pid=state.pid;
  value.millisValue=millis();
  value.microsValue=micros();
  return value;
}

void printSnapshot(const char* reason,const MaxSnapshot& value){
  Serial.printf("MAX_SNAPSHOT REASON=%s REV_A=%02X REV_B=%02X REV_C=%02X "
    "HRSL_A=%02X HRSL_B=%02X HRSL_C=%02X MODE=%02X HCTL=%02X HIRQ=%02X "
    "USBIRQ=%02X PINCTL=%02X INT_GPIO=%d USB_TASK_STATE=%02X HID_READY=%u "
    "VID=%04X PID=%04X MILLIS=%lu MICROS=%lu\n",
    reason,value.revision.a,value.revision.b,value.revision.c,
    value.hrsl.a,value.hrsl.b,value.hrsl.c,value.mode,value.hctl,value.hirq,
    value.usbirq,value.pinctl,value.intGpio,value.usbTaskState,value.hidReady,
    value.vid,value.pid,(unsigned long)value.millisValue,
    (unsigned long)value.microsValue);
}

void initializeUsb(){
  Serial.println("SPI_INIT_OWNER=USB_LIBRARY COUNT=1 CALL_PATH=Usb.Init->MAX3421e::Init->spi::init->USB_SPI.begin");
  Serial.println("USB_INIT_BEGIN");
  releaseExternalSpiDevices();
  prepareForUsbAccess();
  const int result=Usb.Init();
  state.usbInit=result!=-1;
  if(state.usbInit){
    state.parser=Hid.SetReportParser(0,&parser);
    state.maxRevision=Usb.regRd(rREVISION);
  }
  releaseExternalSpiDevices();
  Serial.printf("USB_INIT_END RESULT=%s PARSER=%s MAX_REV=%02X\n",
                state.usbInit?"OK":"FAIL",state.parser?"OK":"FAIL",
                state.maxRevision);
}

void initializeLan(){
  Serial.println("LAN_INIT_BEGIN");
  digitalWrite(Config::kLanReset,LOW);delay(50);
  digitalWrite(Config::kLanReset,HIGH);delay(50);
  Serial.printf("SPI_INIT_OWNER=LAN COUNT=1 CALL=SPI.begin(%u,%u,%u,-1)\n",
                PIN_SPI_SCK,PIN_SPI_MISO,PIN_SPI_MOSI);
  SPI.begin(PIN_SPI_SCK,PIN_SPI_MISO,PIN_SPI_MOSI,-1);
  prepareForLanAccess();
  Ethernet.init(Config::kLanCs);
  Ethernet.begin(Config::kMac,Config::kLocalIp,Config::kDns,
                 Config::kGateway,Config::kSubnet);
  state.w5500Init=Ethernet.hardwareStatus()==EthernetW5500;
  if(state.w5500Init){
    Ethernet.setMACAddress(Config::kMac);
    Ethernet.setLocalIP(Config::kLocalIp);
    Ethernet.setGatewayIP(Config::kGateway);
    Ethernet.setSubnetMask(Config::kSubnet);
    Ethernet.setDnsServerIP(Config::kDns);
    state.actualIp=Ethernet.localIP();
    state.lanConfig=state.actualIp==Config::kLocalIp &&
                    Ethernet.gatewayIP()==Config::kGateway &&
                    Ethernet.subnetMask()==Config::kSubnet;
    if(Config::kFullDuplexEnabled && state.lanConfig){
      state.udpReady=udp.begin(Config::kPort)==1;
    }
  }
  releaseExternalSpiDevices();
  Serial.printf("LAN_INIT_END W5500_STATUS=%s IP=%u.%u.%u.%u LAN_CONFIG=%s UDP=%s\n",
    state.w5500Init?"W5500":"FAIL",state.actualIp[0],state.actualIp[1],
    state.actualIp[2],state.actualIp[3],state.lanConfig?"OK":"FAIL",
    state.udpReady?"OK":"OFF");
}

void serviceUsbTask(){
  if(!state.usbInit)return;
  const uint8_t stateBefore=Usb.getUsbTaskState();
  const bool hidBefore=Hid.isReady();
  const uint16_t vidBefore=hidBefore?Hid.vid():0;
  const uint16_t pidBefore=hidBefore?Hid.pid():0;
  prepareForUsbAccess();
  const uint32_t startUs=micros();
  if(state.lastUsbServiceUs){
    const uint32_t gap=startUs-state.lastUsbServiceUs;
    if(gap>state.maxUsbGapUs)state.maxUsbGapUs=gap;
  }
  state.lastUsbServiceUs=startUs;
  Usb.Task();
  const uint32_t elapsed=micros()-startUs;
  releaseExternalSpiDevices();
  if(elapsed>state.maxUsbTaskUs)state.maxUsbTaskUs=elapsed;
  ++state.usbTaskCount;
  if(elapsed>20000){
    const uint8_t stateAfter=Usb.getUsbTaskState();
    const bool hidAfter=Hid.isReady();
    Serial.printf("USB_TASK_SLOW DURATION_US=%lu STATE_BEFORE=%02X STATE_AFTER=%02X "
      "HID_BEFORE=%u HID_AFTER=%u VID_BEFORE=%04X PID_BEFORE=%04X "
      "VID_AFTER=%04X PID_AFTER=%04X\n",(unsigned long)elapsed,stateBefore,
      stateAfter,hidBefore,hidAfter,vidBefore,pidBefore,
      hidAfter?Hid.vid():0,hidAfter?Hid.pid():0);
    if(elapsed>100000){
      state.usbTaskState=stateAfter;
      state.hidReady=hidAfter;
      state.vid=hidAfter?Hid.vid():0;
      state.pid=hidAfter?Hid.pid():0;
      printSnapshot("USB_TASK_SLOW",captureMaxSnapshot());
    }
  }
}

void logUsbInventory(){
  inventoryCount=0;
  Usb.ForEachUsbDevice(collectInventoryDevice);
  const bool hubReady=Hub.GetAddress()!=0;
  const bool targetReady=Hid.isReady();
  UsbDeviceAddress hidAddress{};
  hidAddress.devAddress=targetReady?Hid.address():0;
  const bool downstreamHidReady=targetReady && hidAddress.bmParent!=0;
  const uint8_t hubAddress=Hub.GetAddress();
  const uint8_t targetAddress=targetReady?Hid.address():0;
  uint8_t targetParent=0;
  uint8_t targetPort=0;
  for(uint8_t index=0;index<inventoryCount;++index){
    if(inventory[index].address==targetAddress){
      targetParent=inventory[index].parent;
      targetPort=inventory[index].port;
      break;
    }
  }
  USB_DEVICE_DESCRIPTOR hubDescriptor{};
  USB_DEVICE_DESCRIPTOR targetDescriptor{};
  uint8_t hubDescriptorResult=0xFF;
  uint8_t targetDescriptorResult=0xFF;
  if(hubAddress!=0){
    prepareForUsbAccess();
    hubDescriptorResult=Usb.getDevDescr(hubAddress,0,sizeof(hubDescriptor),
      reinterpret_cast<uint8_t*>(&hubDescriptor));
    releaseExternalSpiDevices();
  }
  if(targetAddress!=0){
    prepareForUsbAccess();
    targetDescriptorResult=Usb.getDevDescr(targetAddress,0,
      sizeof(targetDescriptor),reinterpret_cast<uint8_t*>(&targetDescriptor));
    releaseExternalSpiDevices();
  }
  Serial.printf("USB_DEVICE_COUNT=%u HUB_READY=%u DOWNSTREAM_HID_READY=%u "
    "TARGET_CONTROLLER_READY=%u\n",inventoryCount,hubReady,
    downstreamHidReady,targetReady);
  Serial.printf("HUB_ADDRESS=%02X HUB_VID=%04X HUB_PID=%04X "
    "TARGET_ADDRESS=%02X TARGET_PARENT=%u TARGET_PORT=%u TARGET_CLASS=%02X "
    "TARGET_VID=%04X TARGET_PID=%04X TARGET_DEVICE_PRESENT=%u\n",
    hubAddress,hubDescriptorResult==0?hubDescriptor.idVendor:0,
    hubDescriptorResult==0?hubDescriptor.idProduct:0,targetAddress,
    targetParent,targetPort,targetDescriptorResult==0?
      targetDescriptor.bDeviceClass:0xFF,
    targetDescriptorResult==0?targetDescriptor.idVendor:0,
    targetDescriptorResult==0?targetDescriptor.idProduct:0,targetReady);
  for(uint8_t index=0;index<inventoryCount;++index){
    USB_DEVICE_DESCRIPTOR descriptor{};
    prepareForUsbAccess();
    const uint8_t result=Usb.getDevDescr(inventory[index].address,0,
      sizeof(descriptor),reinterpret_cast<uint8_t*>(&descriptor));
    releaseExternalSpiDevices();
    Serial.printf("USB_DEVICE_ADDR[%u]=%02X USB_DEVICE_PARENT[%u]=%u "
      "USB_DEVICE_PORT[%u]=%u USB_DEVICE_CLASS[%u]=%02X "
      "USB_DEVICE_VID[%u]=%04X USB_DEVICE_PID[%u]=%04X DESCR_RESULT=%02X\n",
      index,inventory[index].address,index,inventory[index].parent,index,
      inventory[index].port,index,result==0?descriptor.bDeviceClass:0xFF,
      index,result==0?descriptor.idVendor:0,index,
      result==0?descriptor.idProduct:0,result);
  }
}

void updateUsbIdentity(){
  state.usbTaskState=state.usbInit?Usb.getUsbTaskState():0;
  state.hidReady=state.usbInit&&Hid.isReady();
  if(state.usbTaskState==0x90)state.everRunning=true;
  if(state.hidReady)state.everHidReady=true;
  UsbDeviceAddress hidAddress{};
  hidAddress.devAddress=state.hidReady?Hid.address():0;
  state.poweredHubTargetReady=state.hidReady && Hub.GetAddress()!=0 &&
                              hidAddress.bmParent!=0;
  if(state.poweredHubTargetReady)state.everPoweredHubTargetReady=true;
  if(state.previousHidReady&&!state.hidReady)++state.hidReadyDrop;
  state.previousHidReady=state.hidReady;
  if(state.hidReady){state.vid=Hid.vid();state.pid=Hid.pid();}
  else{state.vid=0;state.pid=0;}
}

void checkUsbTransition(uint32_t now){
  if(state.usbTaskState==state.previousUsbTaskState)return;
  Serial.printf("USB_STATE_TRANSITION=%02X->%02X MILLIS=%lu MICROS=%lu\n",
    state.previousUsbTaskState,state.usbTaskState,(unsigned long)now,
    (unsigned long)micros());
  const MaxSnapshot snapshot=captureMaxSnapshot();
  printSnapshot("USB_STATE_TRANSITION",snapshot);
  if(state.previousUsbTaskState==0x90 && state.usbTaskState==0x12 &&
     !state.dropDetected){
    state.dropDetected=true;
    state.dropMs=now;
    state.stopMs=now+Config::kPostDropMs;
  }
  state.previousUsbTaskState=state.usbTaskState;
}

void pollLinkWithSnapshots(){
  const TripleRead revBefore=readTriple(rREVISION,true);
  const TripleRead hrslBefore=readTriple(rHRSL,false);
  releaseExternalSpiDevices();
  prepareForLanAccess();
  state.link=Ethernet.linkStatus();
  releaseExternalSpiDevices();
  const TripleRead revAfter=readTriple(rREVISION,true);
  const TripleRead hrslAfter=readTriple(rHRSL,false);
  state.lastRevBefore=revBefore.a;state.lastRevAfter=revAfter.a;
  state.lastHrslBefore=hrslBefore.a;state.lastHrslAfter=hrslAfter.a;
  if(revBefore.mismatch||revAfter.mismatch||hrslBefore.mismatch||
     hrslAfter.mismatch||revBefore.a!=revAfter.a){
    state.spiCorruptionSuspected=true;
  }
  ++state.linkPollCount;
}

void serviceFullDuplex(uint32_t now){
  if(!state.udpReady)return;
  prepareForLanAccess();
  const int packetSize=udp.parsePacket();
  if(packetSize>0){
    uint8_t incoming[kFrameSize];
    udp.read(incoming,sizeof(incoming));
    ++state.statusRx;
  }
  releaseExternalSpiDevices();
  if(static_cast<int32_t>(now-state.nextControlMs)<0)return;
  ControlPayload payload=neutralControl();
  uint8_t frame[kFrameSize];
  encodeControl(frame,state.controlSequence,now,payload);
  bool sent=false;
  prepareForLanAccess();
  sent=udp.beginPacket(Config::kPeerIp,Config::kPort)==1&&
       udp.write(frame,sizeof(frame))==sizeof(frame)&&udp.endPacket()==1;
  releaseExternalSpiDevices();
  if(sent){++state.controlTx;++state.controlSequence;}
  do{state.nextControlMs+=Config::kPeriodMs;}
  while(static_cast<int32_t>(now-state.nextControlMs)>=0);
}

void updateMinimalDisplay(uint32_t now){
  if(!Config::kDisplayEnabled)return;
  M5.Display.fillRect(0,0,320,48,BLACK);
  M5.Display.setTextColor(WHITE,BLACK);
  M5.Display.setTextSize(1);
  M5.Display.setCursor(0,0);
  M5.Display.printf("MODE:%d ORDER:%d USB:%02X HID:%u\n",
                    USB_LAN_TEST_MODE,USB_LAN_INIT_ORDER,
                    state.usbTaskState,state.hidReady);
  M5.Display.printf("REPORT:%lu LINK:%d DROP:%lu\n",
                    (unsigned long)state.hidReportTotal,state.link,
                    (unsigned long)state.hidReadyDrop);
  ++state.displayUpdateCount;
}

void updateRates(uint32_t now){
  if(now-state.lastRateMs<Config::kSerialMs)return;
  const uint32_t elapsed=now-state.lastRateMs;
  state.hidReportDelta=state.hidReportTotal-state.lastHidSnapshot;
  state.usbTaskPerSec=(state.usbTaskCount-state.lastUsbTaskSnapshot)*1000ULL/elapsed;
  state.lastHidSnapshot=state.hidReportTotal;
  state.lastUsbTaskSnapshot=state.usbTaskCount;
  state.lastRateMs=now;
}

void logOneSecond(uint32_t now){
  const TripleRead revision=readTriple(rREVISION,true);
  const TripleRead hrsl=readTriple(rHRSL,false);
  state.maxRevision=revision.a;
  Serial.printf("DIAG UPTIME=%lu TEST_MODE=%d INIT_ORDER=%d USB_TASK_STATE=%02X "
    "HID_READY=%u VID=%04X PID=%04X HID_REPORT_TOTAL=%lu HID_REPORT_DELTA=%lu "
    "HID_READY_DROP=%lu USB_TASK_PER_SEC=%lu MAX_USB_GAP_US=%lu MAX_USB_TASK_US=%lu "
    "MAX_REV=%02X REV_A=%02X REV_B=%02X REV_C=%02X HRSL_A=%02X HRSL_B=%02X HRSL_C=%02X "
    "MAX_REV_MISMATCH=%lu MAX_HRSL_MISMATCH=%lu MAX_SPI_READ_MISMATCH=%lu "
    "W5500_INIT=%u LINK_POLL_COUNT=%lu DISPLAY_UPDATE_COUNT=%lu "
    "MAX_REV_BEFORE=%02X MAX_REV_AFTER=%02X MAX_HRSL_BEFORE=%02X MAX_HRSL_AFTER=%02X "
    "SPI_CORRUPTION_SUSPECTED=%u CONTROL_TX=%lu STATUS_RX=%lu RESET_REASON=%s\n",
    (unsigned long)(now-state.startMs),USB_LAN_TEST_MODE,USB_LAN_INIT_ORDER,
    state.usbTaskState,state.hidReady,state.vid,state.pid,
    (unsigned long)state.hidReportTotal,(unsigned long)state.hidReportDelta,
    (unsigned long)state.hidReadyDrop,(unsigned long)state.usbTaskPerSec,
    (unsigned long)state.maxUsbGapUs,(unsigned long)state.maxUsbTaskUs,
    state.maxRevision,revision.a,revision.b,revision.c,hrsl.a,hrsl.b,hrsl.c,
    (unsigned long)state.maxRevMismatch,(unsigned long)state.maxHrslMismatch,
    (unsigned long)state.maxSpiReadMismatch,state.w5500Init,
    (unsigned long)state.linkPollCount,(unsigned long)state.displayUpdateCount,
    state.lastRevBefore,state.lastRevAfter,state.lastHrslBefore,state.lastHrslAfter,
    state.spiCorruptionSuspected,(unsigned long)state.controlTx,
    (unsigned long)state.statusRx,resetText());
  if(USB_TARGET_READY_TIMEOUT_MS>0)logUsbInventory();
  state.maxUsbGapUs=0;
  state.maxUsbTaskUs=0;
}

void stopTest(bool passed,uint32_t now){
  if(state.stopped)return;
  state.stopped=true;
  const bool criteriaPassed=passed && state.everRunning && state.everHidReady &&
    state.usbTaskState==0x90 && state.hidReady && state.hidReportTotal>0 &&
    state.hidReadyDrop==0 && state.maxSpiReadMismatch==0 &&
    (!USB_POWERED_HUB_TEST ||
      (state.everPoweredHubTargetReady && state.poweredHubTargetReady));
  Serial.printf("TEST_COMPLETE=%s TEST_MODE=%d INIT_ORDER=%d DURATION_MS=%lu "
    "DROP_TIME_MS=%lu HID_READY_DROP=%lu MAX_SPI_READ_MISMATCH=%lu "
    "SPI_CORRUPTION_SUSPECTED=%u EVER_RUNNING=%u EVER_HID_READY=%u "
    "FINAL_USB_STATE=%02X FINAL_HID_READY=%u HID_REPORT_TOTAL=%lu\n",
    criteriaPassed?"PASS":"FAIL",USB_LAN_TEST_MODE,
    USB_LAN_INIT_ORDER,(unsigned long)(now-state.startMs),
    state.dropDetected?(unsigned long)(state.dropMs-state.startMs):0UL,
    (unsigned long)state.hidReadyDrop,(unsigned long)state.maxSpiReadMismatch,
    state.spiCorruptionSuspected,state.everRunning,state.everHidReady,
    state.usbTaskState,state.hidReady,(unsigned long)state.hidReportTotal);
}

void setup(){
  auto cfg=M5.config();
  cfg.internal_spk=false;
  cfg.internal_mic=false;
  M5.begin(cfg);
  Serial.begin(115200);
  prepareExternalPins();
  delay(1500);
  state.resetReason=esp_reset_reason();
  Serial.printf("DIAGNOSTIC_BOOT TEST_MODE=%d INIT_ORDER=%d DISPLAY=%u LAN_INIT=%u "
    "LINK_POLL=%u FULL_DUPLEX=%u RESET_REASON=%s\n",USB_LAN_TEST_MODE,
    USB_LAN_INIT_ORDER,Config::kDisplayEnabled,Config::kLanInitEnabled,
    Config::kLinkPollEnabled,Config::kFullDuplexEnabled,resetText());
  if(!Config::kLanInitEnabled && USB_LAN_INIT_ORDER!=0){
    Serial.println("CONFIG_ERROR=USB_ONLY_MODE_REQUIRES_INIT_ORDER_0");
    while(true)delay(1000);
  }
  if(Config::kLanInitEnabled && USB_LAN_INIT_ORDER==0){
    Serial.println("CONFIG_ERROR=LAN_MODE_REQUIRES_INIT_ORDER_1_OR_2");
    while(true)delay(1000);
  }
  if(USB_LAN_INIT_ORDER==1){initializeUsb();initializeLan();}
  else if(USB_LAN_INIT_ORDER==2){initializeLan();initializeUsb();}
  else initializeUsb();
  state.startMs=millis();
  state.lastRateMs=state.startMs;
  state.nextControlMs=state.startMs;
  updateUsbIdentity();
  state.previousUsbTaskState=state.usbTaskState;
  const MaxSnapshot initial=captureMaxSnapshot();
  printSnapshot("INITIAL",initial);
  Serial.println("DIAGNOSTIC_START");
}

void loop(){
  if(state.stopped){delay(10);return;}
  serviceUsbTask();
  M5.update();
  uint32_t now=millis();
  updateUsbIdentity();
  checkUsbTransition(now);
  if(Config::kLinkPollEnabled && now-state.lastLinkMs>=Config::kLinkPollMs){
    state.lastLinkMs=now;
    pollLinkWithSnapshots();
  }
  if(Config::kFullDuplexEnabled)serviceFullDuplex(now);
  if(Config::kDisplayEnabled && now-state.lastDisplayMs>=Config::kDisplayMs){
    state.lastDisplayMs=now;
    updateMinimalDisplay(now);
  }
  updateRates(now);
  if(now-state.lastSerialMs>=Config::kSerialMs){
    state.lastSerialMs=now;
    logOneSecond(now);
  }
  const bool targetGateReady=USB_POWERED_HUB_TEST?
    state.everPoweredHubTargetReady:state.everHidReady;
  if(USB_TARGET_READY_TIMEOUT_MS>0 && !targetGateReady &&
     !state.targetTimeoutReported &&
     now-state.startMs>=USB_TARGET_READY_TIMEOUT_MS){
    state.targetTimeoutReported=true;
    Serial.printf("TEST_RESULT=NO_TARGET_HID HUB_READY=%u USB_STATE=%02X "
      "HID_READY=%u VID=%04X PID=%04X HID_REPORT_TOTAL=%lu "
      "TARGET_CONTROLLER_READY=%u\n",
      Hub.GetAddress()!=0,state.usbTaskState,state.hidReady,state.vid,state.pid,
      (unsigned long)state.hidReportTotal,state.poweredHubTargetReady);
    state.stopped=true;
  }
  if(state.dropDetected && static_cast<int32_t>(now-state.stopMs)>=0){
    stopTest(false,now);
  }else if(!state.dropDetected && now-state.startMs>=USB_LAN_TEST_DURATION_MS){
    stopTest(true,now);
  }
}
