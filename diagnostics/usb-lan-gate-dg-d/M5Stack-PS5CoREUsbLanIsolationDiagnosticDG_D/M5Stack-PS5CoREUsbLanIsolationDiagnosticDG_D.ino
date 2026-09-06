#include <M5Unified.h>
#include <SPI.h>
#include <M5_Ethernet.h>
#include <utility/w5100.h>
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
#ifndef USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS
#define USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS 1000UL
#endif
#ifndef USB_LAN_PHY_PROFILE
#define USB_LAN_PHY_PROFILE 0
#endif
#ifndef USB_HOST_SHIELD_SS_GPIO
#define USB_HOST_SHIELD_SS_GPIO 1
#endif
#ifndef USB_HOST_SHIELD_INT_GPIO
#define USB_HOST_SHIELD_INT_GPIO 14
#endif
#ifndef USB_LAN_C1_PEER_IP_A
#define USB_LAN_C1_PEER_IP_A 192
#define USB_LAN_C1_PEER_IP_B 168
#define USB_LAN_C1_PEER_IP_C 50
#define USB_LAN_C1_PEER_IP_D 254
#endif
#ifndef PIN_SPI_SCK
#define PIN_SPI_SCK 36
#define PIN_SPI_MOSI 37
#define PIN_SPI_MISO 35
#endif

static_assert(USB_LAN_TEST_MODE >= 0 &&
              (USB_LAN_TEST_MODE <= 15 || USB_LAN_TEST_MODE == 18),
              "USB_LAN_TEST_MODE must be 0..15 or 18");
static_assert(USB_LAN_INIT_ORDER >= 0 && USB_LAN_INIT_ORDER <= 2,
              "USB_LAN_INIT_ORDER must be 0..2");
static_assert(USB_LAN_TEST_MODE > 2 || USB_LAN_INIT_ORDER == 0,
              "Modes 0..2 require InitOrder 0");
static_assert(USB_LAN_TEST_MODE < 3 || USB_LAN_TEST_MODE > 7 ||
              USB_LAN_INIT_ORDER == 1 || USB_LAN_INIT_ORDER == 2,
              "Modes 3..7 require InitOrder 1 or 2");
static_assert(USB_LAN_TEST_MODE != 8 || USB_LAN_INIT_ORDER == 0,
              "Mode 8 RESET_RELEASE_ONLY requires InitOrder 0");
static_assert((USB_LAN_TEST_MODE != 9 && USB_LAN_TEST_MODE != 10) ||
              USB_LAN_INIT_ORDER == 2,
              "Modes 9 and 10 require LAN_FIRST InitOrder 2");
static_assert((USB_LAN_TEST_MODE != 11 && USB_LAN_TEST_MODE != 12) ||
              USB_LAN_INIT_ORDER == 0,
              "Modes 11 and 12 require InitOrder 0");
static_assert((USB_LAN_TEST_MODE != 13 && USB_LAN_TEST_MODE != 14) ||
              USB_LAN_INIT_ORDER == 0,
              "Modes 13 and 14 require InitOrder 0");
static_assert(USB_LAN_TEST_MODE != 15 || USB_LAN_INIT_ORDER == 0,
              "Mode 15 requires InitOrder 0");
static_assert(USB_LAN_TEST_MODE != 18 || USB_LAN_INIT_ORDER == 0,
              "Mode 18 requires InitOrder 0");
#if USB_LAN_TEST_MODE == 18
static_assert(
    USB_LAN_C1_PEER_IP_A == 192 &&
    USB_LAN_C1_PEER_IP_B == 168 &&
    USB_LAN_C1_PEER_IP_C == 50 &&
    USB_LAN_C1_PEER_IP_D == 30,
    "Mode 18 requires DG-D peer 192.168.50.30");
#endif
static_assert(USB_LAN_PHY_PROFILE >= 0 && USB_LAN_PHY_PROFILE <= 5,
              "USB_LAN_PHY_PROFILE must be 0..5");
static_assert(USB_LAN_TEST_MODE != 15 || USB_LAN_PHY_PROFILE == 2,
              "Mode 15 requires the Fixed10Half PHY profile");
static_assert(USB_LAN_TEST_MODE != 18 || USB_LAN_PHY_PROFILE == 2,
              "Mode 18 requires the Fixed10Half PHY profile");
static_assert(USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS > 0,
              "USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS must be positive");

#if USB_LAN_TEST_MODE == 15 || USB_LAN_TEST_MODE == 18
#ifndef ETHERNET_LARGE_BUFFERS
#error "Modes 15 and 18 require ETHERNET_LARGE_BUFFERS"
#endif
static_assert(MAX_SOCK_NUM == 2);
#endif

enum class SetupPlan : uint8_t {
  kOrderControlled,
  kResetReleaseOnly,
  kInitThenResetHeld,
  kPhyPowerDown,
  kUsbRunningResetHeld,
  kUsbRunningThenResetRelease,
  kLanOnlyPhyLinkTiming,
  kUsbRunningThenPhyProfile,
  kUsbFixed10UdpTxOnly,
  kUsbFixed10UdpPositiveParseImmediateNullDiscard,
};

struct ModePlan {
  const char* name;
  bool display;
  bool lanInit;
  bool linkPoll;
  bool fullDuplex;
  bool failFast;
  SetupPlan setup;
};

constexpr ModePlan kModePlans[] = {
  {"LEGACY_MODE_0",false,false,false,false,false,SetupPlan::kOrderControlled},
  {"LEGACY_MODE_1",true, false,false,false,false,SetupPlan::kOrderControlled},
  {"LEGACY_MODE_2",true, false,false,false,false,SetupPlan::kOrderControlled},
  {"LEGACY_MODE_3",false,true, false,false,false,SetupPlan::kOrderControlled},
  {"LEGACY_MODE_4",false,true, true, false,false,SetupPlan::kOrderControlled},
  {"LEGACY_MODE_5",true, true, true, false,false,SetupPlan::kOrderControlled},
  {"LEGACY_MODE_6",false,true, true, true, false,SetupPlan::kOrderControlled},
  {"LEGACY_MODE_7",true, true, true, true, false,SetupPlan::kOrderControlled},
  {"RESET_RELEASE_ONLY",false,false,false,false,true,SetupPlan::kResetReleaseOnly},
  {"INIT_THEN_RESET_HELD",false,true,false,false,true,SetupPlan::kInitThenResetHeld},
  {"PHY_POWER_DOWN",false,true,false,false,true,SetupPlan::kPhyPowerDown},
  {"USB_RUNNING_RESET_HELD_CONTROL",false,false,false,false,true,
   SetupPlan::kUsbRunningResetHeld},
  {"USB_RUNNING_THEN_RESET_RELEASE",false,false,false,false,true,
   SetupPlan::kUsbRunningThenResetRelease},
  {"LAN_ONLY_PHY_LINK_TIMING",false,false,false,false,false,
   SetupPlan::kLanOnlyPhyLinkTiming},
  {"USB_RUNNING_THEN_PHY_PROFILE",false,false,false,false,true,
   SetupPlan::kUsbRunningThenPhyProfile},
  {"USB_FIXED10_UDP_TX_ONLY",false,false,false,false,true,
   SetupPlan::kUsbFixed10UdpTxOnly},
};
static_assert(sizeof(kModePlans)/sizeof(kModePlans[0]) == 16,
              "ModePlan table must cover modes 0..15");
#if USB_LAN_TEST_MODE == 18
constexpr ModePlan kModePlan={
  "USB_FIXED10_UDP_POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD",
  false,false,false,false,true,
  SetupPlan::kUsbFixed10UdpPositiveParseImmediateNullDiscard,
};
#else
constexpr ModePlan kModePlan=kModePlans[USB_LAN_TEST_MODE];
#endif

enum class PhyProfileId : uint8_t {
  kHardwareStrap=0,
  kPowerDown=1,
  kFixed10Half=2,
  kFixed100Half=3,
  kAuto100Half=4,
  kAutoAll=5,
};

struct PhyProfilePlan {
  const char* name;
  bool registerControlled;
  uint8_t opmdc;
};

constexpr PhyProfilePlan kPhyProfiles[] = {
  {"HardwareStrap",false,0b000},
  {"PowerDown",true,0b110},
  {"Fixed10Half",true,0b000},
  {"Fixed100Half",true,0b010},
  {"Auto100Half",true,0b100},
  {"AutoAll",true,0b111},
};
static_assert(sizeof(kPhyProfiles)/sizeof(kPhyProfiles[0]) == 6,
              "PHY profile table must cover profile ids 0..5");
constexpr PhyProfilePlan kPhyProfile=kPhyProfiles[USB_LAN_PHY_PROFILE];

namespace Config {
constexpr uint8_t kLanCs=13, kLanInt=10, kLanReset=0;
constexpr uint16_t kPort=50001;
constexpr uint32_t kPeriodMs=20, kLinkPollMs=250, kDisplayMs=100,
                   kSerialMs=1000, kPostDropMs=30000,
                    kLanResetAssertMs=50, kLanResetReleaseMs=50,
                    kLanOnlyPhyPollMs=5, kUsbPhyPollMs=10;
const IPAddress kLocalIp(192,168,50,10), kPeerIp(192,168,50,20);
const IPAddress kC1PeerIp(USB_LAN_C1_PEER_IP_A,USB_LAN_C1_PEER_IP_B,
                          USB_LAN_C1_PEER_IP_C,USB_LAN_C1_PEER_IP_D);
const IPAddress kDns(192,168,50,1), kGateway(192,168,50,1),
                kSubnet(255,255,255,0);
uint8_t kMac[6]={0x02,0x4D,0x35,0x55,0x53,0x42};
constexpr bool kDisplayEnabled=kModePlan.display;
constexpr bool kLanInitEnabled=kModePlan.lanInit;
constexpr bool kLinkPollEnabled=kModePlan.linkPoll;
constexpr bool kFullDuplexEnabled=kModePlan.fullDuplex;
constexpr bool kFailFastOnDetach=kModePlan.failFast;
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
  bool lanAccessAllowed=false, failFastPending=false, failFastHandled=false;
  bool w5500ResetReleased=false, w5500ResetHeldDuringUsb=false;
  bool phyPowerDownVerified=false;
  bool usbStableWindowActive=false, usbStableWindowComplete=false;
  bool resetReleasedAfterUsbRunning=false;
  bool phyProfileApplied=false, phyProfileReadbackOk=false;
  bool phyLinkObserved=false, phyReadError=false, phyApplyPending=false;
  bool poweredHubTargetReady=false, everPoweredHubTargetReady=false;
  bool targetTimeoutReported=false;
  uint8_t usbTaskState=0, previousUsbTaskState=0, maxRevision=0;
  uint8_t phyCfgrBefore=0, phyCfgrAfter=0, detachUsbStateBefore=0;
  uint8_t phyCfgrLast=0, phyCfgrAssertReset=0;
  uint16_t vid=0, pid=0, controlSequence=0;
  uint16_t lastReadyVid=0, lastReadyPid=0;
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
  uint32_t detachHidReportTotal=0;
  uint32_t usbStableWindowStartMs=0, firstValidRunningMs=0;
  uint32_t resetReleaseMs=0, resetReleaseUs=0, detachMs=0, detachUs=0;
  uint32_t lanResetLowUs=0, phyProfileAppliedUs=0, phyLinkUpUs=0,
           lastPhyPollMs=0, phyPollCount=0, phyPollMaxUs=0,
           firstPhyReadUs=0;
  uint8_t lastRevBefore=0, lastRevAfter=0,
          lastHrslBefore=0, lastHrslAfter=0;
  esp_reset_reason_t resetReason=ESP_RST_UNKNOWN;
} state;

#if USB_LAN_TEST_MODE == 15 || USB_LAN_TEST_MODE == 18
enum class DgDPhase : uint8_t {
  kActive,
  kDrain,
  kComplete,
  kBlocked,
};

struct C1State {
  bool w5100Init=false, networkConfig=false, linkStable=false;
  bool udpReady=false, usbStable=false, detachMarkerPrinted=false;
  bool finalPhyOk=false, finalVersionOk=false, finalBufferMapOk=false;
  uint8_t version=0;
  uint32_t trialStartMs=0, nextDeadlineUs=0, lastTxUs=0;
  uint32_t lastHidReportMs=0, lastHidReportTotal=0;
  uint32_t udpTxTotal=0, udpTxFail=0, udpBeginCount=0, udpBeginFail=0;
  uint32_t udpBeginMaxUs=0, udpBeginPacketMaxUs=0, udpWriteMaxUs=0;
  uint32_t udpEndPacketMaxUs=0, udpMaxGapUs=0;
  uint32_t schedulerMissedDeadline=0, schedulerMaxLatenessUs=0;
  uint32_t loopMaxUs=0, sequence=0, lastRuntimeCheckMs=0;
  uint32_t hidStallCount=0, hidMaxNoReportMs=0;
#if USB_LAN_TEST_MODE == 18
  DgDPhase dgDPhase=DgDPhase::kActive;
  const char* dgDBlockReason="NONE";
  int32_t rxPositiveOtherSizeFirst=0, rxPositiveOtherSizeLast=0;
  int32_t rxNullDiscardLastReturn=0, rxLastParseResult=0;
  uint32_t rxParseCallStartedTotal=0, rxParseCallCompletedTotal=0;
  uint32_t rxParseZeroTotal=0, rxParsePositiveTotal=0;
  uint32_t rxParseNegativeTotal=0, rxPositiveSize32Total=0;
  uint32_t rxPositiveOtherSizeTotal=0;
  uint32_t rxPreParseRemainingNonzero=0;
  uint32_t rxNullDiscardCallTotal=0, rxNullDiscardReturnTotal=0;
  uint32_t rxNullDiscardRequestBytesTotal=0;
  uint32_t rxNullDiscardBytesTotal=0, rxNullDiscardFailTotal=0;
  uint32_t rxPostDiscardRemainingNonzero=0;
  uint32_t rxParseMaxUs=0, rxNullDiscardMaxUs=0, rxTreatmentMaxUs=0;
  uint32_t drainTargetTxTotal=0, drainEnterMs=0, drainCompleteMs=0;
  uint32_t drainQuietStartMs=0, drainQuietObservedMs=0;
  uint32_t drainParsePositiveStartTotal=0;
  uint32_t drainParsePositiveEndTotal=0, drainZeroConfirmationTotal=0;
#endif
} c1;

struct C1BufferMap {
  uint8_t rxKb[8]{};
  uint8_t txKb[8]{};
};
#endif

class DiagnosticParser : public HIDReportParser {
 public:
  void Parse(USBHID*,bool,uint8_t,uint8_t*) override {
    ++state.hidReportTotal;
  }
};
#if USB_LAN_TEST_MODE != 13
DiagnosticParser parser;
#endif

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
#if USB_LAN_TEST_MODE == 15 || USB_LAN_TEST_MODE == 18
  pinMode(USB_HOST_SHIELD_SS_GPIO,OUTPUT);
  digitalWrite(USB_HOST_SHIELD_SS_GPIO,HIGH);
  pinMode(Config::kLanCs,OUTPUT);
  digitalWrite(Config::kLanCs,HIGH);
  pinMode(Config::kLanReset,OUTPUT);
  digitalWrite(Config::kLanReset,LOW);
  state.lanResetLowUs=micros();
#else
  pinMode(Config::kLanReset,OUTPUT);
  digitalWrite(Config::kLanReset,LOW);
  state.lanResetLowUs=micros();
  pinMode(USB_HOST_SHIELD_SS_GPIO,OUTPUT);
  digitalWrite(USB_HOST_SHIELD_SS_GPIO,HIGH);
  pinMode(Config::kLanCs,OUTPUT);
  digitalWrite(Config::kLanCs,HIGH);
#endif
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
#if USB_LAN_TEST_MODE != 13
    state.parser=Hid.SetReportParser(0,&parser);
#endif
    state.maxRevision=Usb.regRd(rREVISION);
  }
  releaseExternalSpiDevices();
  Serial.printf("USB_INIT_END RESULT=%s PARSER=%s MAX_REV=%02X\n",
                state.usbInit?"OK":"FAIL",state.parser?"OK":"FAIL",
                state.maxRevision);
}

void releaseW5500ResetOnly(){
  releaseExternalSpiDevices();
  digitalWrite(Config::kLanReset,LOW);
  delay(Config::kLanResetAssertMs);
  digitalWrite(Config::kLanReset,HIGH);
  delay(Config::kLanResetReleaseMs);
  state.w5500ResetReleased=true;
  state.lanAccessAllowed=false;
  Serial.println("W5500_RESET_RELEASED=1 W5500_SPI_ACCESS=0 W5500_INIT=0 "
                 "PHY_STATE=ACTIVE_BY_STRAP_UNVERIFIED");
}

void initializeUsbRunningResetPlan(){
  releaseExternalSpiDevices();
  digitalWrite(Config::kLanReset,LOW);
  delay(Config::kLanResetAssertMs);
  state.w5500ResetReleased=false;
  state.w5500ResetHeldDuringUsb=true;
  state.lanAccessAllowed=false;
  if(kModePlan.setup==SetupPlan::kUsbRunningThenPhyProfile){
    W5100.setSS(Config::kLanCs);
  }
  if(kModePlan.setup==SetupPlan::kUsbRunningResetHeld){
    Serial.println("W5500_RESET_HELD=1 W5500_SPI_ACCESS=0 "
                   "USB_RUNNING_BEFORE_RESET_ACTION=1 RESET_ACTION=NONE");
  }else if(kModePlan.setup==SetupPlan::kUsbRunningThenResetRelease){
    Serial.printf("W5500_RESET_HELD=1 W5500_SPI_ACCESS=0 W5500_INIT=0 "
                  "RESET_ACTION=RELEASE_AFTER_RUNNING "
                  "USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS=%lu\n",
                   (unsigned long)USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS);
  }else{
    Serial.printf("W5500_RESET_HELD=1 W5500_INIT=0 "
                  "RESET_ACTION=RELEASE_THEN_PHY_PROFILE "
                  "PHY_PROFILE=%s USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS=%lu\n",
                  kPhyProfile.name,
                  (unsigned long)USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS);
  }
  initializeUsb();
}

void initializeLan(){
  Serial.println("LAN_INIT_BEGIN");
  digitalWrite(Config::kLanReset,LOW);delay(Config::kLanResetAssertMs);
  digitalWrite(Config::kLanReset,HIGH);delay(Config::kLanResetReleaseMs);
  state.w5500ResetReleased=true;
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
  state.lanAccessAllowed=state.w5500Init&&state.lanConfig;
  Serial.printf("LAN_INIT_END W5500_STATUS=%s IP=%u.%u.%u.%u LAN_CONFIG=%s UDP=%s\n",
    state.w5500Init?"W5500":"FAIL",state.actualIp[0],state.actualIp[1],
    state.actualIp[2],state.actualIp[3],state.lanConfig?"OK":"FAIL",
    state.udpReady?"OK":"OFF");
}

void holdW5500ResetAfterInit(){
  releaseExternalSpiDevices();
  digitalWrite(Config::kLanReset,LOW);
  delay(Config::kLanResetAssertMs);
  state.w5500ResetReleased=false;
  state.w5500ResetHeldDuringUsb=true;
  state.lanAccessAllowed=false;
  Serial.printf("W5500_INIT_BEFORE_RESET=%u LAN_CONFIG_BEFORE_RESET=%s "
                "W5500_RESET_HELD_DURING_USB=1 "
                "W5500_SPI_ACCESS_AFTER_RESET=0\n",
                state.w5500Init,state.lanConfig?"OK":"FAIL");
}

uint8_t readW5500PhyCfgr(){
  prepareForLanAccess();
  SPI.beginTransaction(SPI_ETHERNET_SETTINGS);
  const uint8_t value=W5100.readPHYCFGR_W5500();
  SPI.endTransaction();
  releaseExternalSpiDevices();
  return value;
}

void writeW5500PhyCfgr(uint8_t value){
  prepareForLanAccess();
  SPI.beginTransaction(SPI_ETHERNET_SETTINGS);
  W5100.writePHYCFGR_W5500(value);
  SPI.endTransaction();
  releaseExternalSpiDevices();
}

bool applyW5500PhyProfile(const PhyProfilePlan& profile){
  constexpr uint8_t kPhyReset=0x80;
  constexpr uint8_t kOperationModeFromRegister=0x40;
  constexpr uint8_t kOperationModeMask=0x38;
  if(!profile.registerControlled){
    state.phyCfgrBefore=readW5500PhyCfgr();
    state.phyCfgrAfter=state.phyCfgrBefore;
    state.phyProfileReadbackOk=(state.phyCfgrAfter&kPhyReset)!=0;
    state.phyProfileApplied=state.phyProfileReadbackOk;
    state.phyProfileAppliedUs=micros();
    Serial.printf("PHYCFGR_BEFORE=%02X PHYCFGR_ASSERT_RESET=NA "
                  "PHYCFGR_AFTER=%02X PHY_PROFILE_APPLIED=%u "
                  "PHY_PROFILE_APPLIED_MICROS=%lu "
                  "PHY_PROFILE_READBACK_OK=%u\n",state.phyCfgrBefore,
                  state.phyCfgrAfter,state.phyProfileApplied,
                  (unsigned long)state.phyProfileAppliedUs,
                  state.phyProfileReadbackOk);
    return state.phyProfileReadbackOk;
  }
  state.phyCfgrBefore=readW5500PhyCfgr();
  uint8_t configured=state.phyCfgrBefore|kOperationModeFromRegister;
  configured=(configured&static_cast<uint8_t>(~kOperationModeMask))|
             static_cast<uint8_t>(profile.opmdc<<3);
  state.phyCfgrAssertReset=configured&static_cast<uint8_t>(~kPhyReset);
  writeW5500PhyCfgr(state.phyCfgrAssertReset);
  delay(1);
  writeW5500PhyCfgr(configured|kPhyReset);
  state.phyCfgrAfter=readW5500PhyCfgr();
  const uint8_t expected=kPhyReset|kOperationModeFromRegister|
                         static_cast<uint8_t>(profile.opmdc<<3);
  state.phyProfileReadbackOk=
    (state.phyCfgrAfter&static_cast<uint8_t>(kPhyReset|
      kOperationModeFromRegister|kOperationModeMask))==expected;
  state.phyProfileApplied=state.phyProfileReadbackOk;
  state.phyProfileAppliedUs=micros();
  Serial.printf("PHYCFGR_BEFORE=%02X PHYCFGR_ASSERT_RESET=%02X "
                "PHYCFGR_AFTER=%02X PHY_PROFILE_APPLIED=%u "
                "PHY_PROFILE_APPLIED_MICROS=%lu "
                "PHY_PROFILE_READBACK_OK=%u\n",state.phyCfgrBefore,
                state.phyCfgrAssertReset,state.phyCfgrAfter,
                state.phyProfileApplied,(unsigned long)state.phyProfileAppliedUs,
                state.phyProfileReadbackOk);
  return state.phyProfileReadbackOk;
}

bool configureW5500PhyPowerDown(){
  if(!state.w5500Init||!state.lanConfig){
    Serial.println("PHY_POWER_DOWN_VERIFIED=0 REASON=LAN_INIT_FAILED");
    state.lanAccessAllowed=false;
    return false;
  }
  state.phyPowerDownVerified=applyW5500PhyProfile(
    kPhyProfiles[static_cast<uint8_t>(PhyProfileId::kPowerDown)]);
  state.lanAccessAllowed=false;
  Serial.printf("PHYCFGR_BEFORE=%02X PHYCFGR_AFTER=%02X "
                "PHY_POWER_DOWN_VERIFIED=%u\n",state.phyCfgrBefore,
                state.phyCfgrAfter,state.phyPowerDownVerified);
  return state.phyPowerDownVerified;
}

void initializeW5500RegisterAccessWhileResetHeld(){
  releaseExternalSpiDevices();
  digitalWrite(Config::kLanReset,LOW);
  Serial.printf("SPI_INIT_OWNER=LAN COUNT=1 CALL=SPI.begin(%u,%u,%u,-1) "
                "W5500_RESET=LOW\n",PIN_SPI_SCK,PIN_SPI_MISO,PIN_SPI_MOSI);
  SPI.begin(PIN_SPI_SCK,PIN_SPI_MISO,PIN_SPI_MOSI,-1);
  W5100.setSS(Config::kLanCs);
  releaseExternalSpiDevices();
}

void releaseW5500ForPhyMeasurement(){
  const uint32_t lowHeldUs=micros()-state.lanResetLowUs;
  releaseExternalSpiDevices();
  Serial.printf("RESET_RELEASE_BEFORE RESET_LOW_HELD_US=%lu\n",
                (unsigned long)lowHeldUs);
  state.resetReleaseMs=millis();
  state.resetReleaseUs=micros();
  digitalWrite(Config::kLanReset,HIGH);
  state.w5500ResetReleased=true;
  Serial.printf("W5500_EXTERNAL_RESET_RELEASED=1 RESET_RELEASE_MILLIS=%lu "
                "RESET_RELEASE_MICROS=%lu\n",
                (unsigned long)state.resetReleaseMs,
                (unsigned long)state.resetReleaseUs);
}

void printPhyCfgrChange(uint8_t value,uint32_t observedUs){
  const uint8_t opmdc=(value>>3)&0x07;
  Serial.printf("PHYCFGR_CHANGE RAW=%02X RST=%u OPMD=%u OPMDC=%u%u%u DPX=%u "
                "SPD=%u LNK=%u MILLIS=%lu MICROS=%lu SINCE_RESET_US=%lu\n",
                value,(value>>7)&1,(value>>6)&1,(opmdc>>2)&1,
                (opmdc>>1)&1,opmdc&1,(value>>2)&1,
                (value>>1)&1,value&1,(unsigned long)millis(),
                (unsigned long)observedUs,
                (unsigned long)(observedUs-state.resetReleaseUs));
}

void pollPhyProfile(uint32_t now,uint32_t intervalMs){
  if(!state.w5500ResetReleased||!state.phyProfileApplied||
     state.stopped||state.failFastHandled||now-state.lastPhyPollMs<intervalMs)return;
  state.lastPhyPollMs=now;
  const uint32_t pollStartUs=micros();
  const uint8_t value=readW5500PhyCfgr();
  const uint32_t observedUs=micros();
  const uint32_t elapsedUs=observedUs-pollStartUs;
  if(elapsedUs>state.phyPollMaxUs)state.phyPollMaxUs=elapsedUs;
  ++state.phyPollCount;
  if(state.firstPhyReadUs==0){
    state.firstPhyReadUs=observedUs;
    Serial.printf("PHY_FIRST_READ_MICROS=%lu RESET_RELEASE_TO_FIRST_READ_US=%lu\n",
                  (unsigned long)observedUs,
                  (unsigned long)(observedUs-state.resetReleaseUs));
  }
  if((value&0x80)==0)state.phyReadError=true;
  if(state.phyPollCount==1||value!=state.phyCfgrLast){
    state.phyCfgrLast=value;
    printPhyCfgrChange(value,observedUs);
  }
  if(!state.phyLinkObserved&&(value&0x01)!=0){
    state.phyLinkObserved=true;
    state.phyLinkUpUs=observedUs;
    const uint32_t fromProfileUs=state.phyProfileAppliedUs?
      observedUs-state.phyProfileAppliedUs:0;
    Serial.printf("PHY_LINK_UP=1 RESET_RELEASE_TO_LINK_UP_US=%lu "
                  "PROFILE_APPLIED_TO_LINK_UP_US=%lu PHY_SPEED_MBPS=%u "
                  "PHY_DUPLEX=%s PHY_PROFILE_READBACK=%02X\n",
                  (unsigned long)(observedUs-state.resetReleaseUs),
                  (unsigned long)fromProfileUs,(value&0x02)?100:10,
                  (value&0x04)?"FULL":"HALF",value);
  }
}

bool initializeLanOnlyPhyTiming(){
  initializeW5500RegisterAccessWhileResetHeld();
  delay(Config::kLanResetAssertMs);
  releaseW5500ForPhyMeasurement();
  delay(Config::kLanResetReleaseMs);
  state.phyApplyPending=false;
  return applyW5500PhyProfile(kPhyProfile);
}

void serviceUsbTask(){
  if(!state.usbInit||state.stopped||state.failFastHandled)return;
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
  const uint8_t usbStateBefore=state.usbTaskState;
  const bool hidReadyBefore=state.hidReady;
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
  if(Config::kFailFastOnDetach&&!state.failFastHandled&&
     ((state.everRunning&&usbStateBefore==0x90&&state.usbTaskState!=0x90)||
      (state.everHidReady&&hidReadyBefore&&!state.hidReady))){
    state.failFastPending=true;
    state.detachUsbStateBefore=usbStateBefore;
    state.detachHidReportTotal=state.hidReportTotal;
    state.detachMs=millis();
    state.detachUs=micros();
  }
  state.previousHidReady=state.hidReady;
  if(state.hidReady){
    state.vid=Hid.vid();state.pid=Hid.pid();
    state.lastReadyVid=state.vid;state.lastReadyPid=state.pid;
  }
  else{state.vid=0;state.pid=0;}
}

bool targetHoriRunning(){
  return state.usbTaskState==0x90 && state.hidReady &&
         state.vid==0x0F0D && state.pid==0x0202;
}

void handleUsbRunningResetPlan(uint32_t now){
  const bool specialPlan=
    kModePlan.setup==SetupPlan::kUsbRunningResetHeld ||
    kModePlan.setup==SetupPlan::kUsbRunningThenResetRelease ||
    kModePlan.setup==SetupPlan::kUsbRunningThenPhyProfile;
  if(!specialPlan)return;
  if(state.usbStableWindowComplete){
    if(kModePlan.setup==SetupPlan::kUsbRunningThenPhyProfile &&
       state.phyApplyPending &&
       micros()-state.resetReleaseUs>=Config::kLanResetReleaseMs*1000UL){
      state.phyApplyPending=false;
      state.phyProfileApplied=applyW5500PhyProfile(kPhyProfile);
      if(!state.phyProfileApplied){
        state.phyReadError=true;
        Serial.println("TEST_RESULT=PHY_PROFILE_CONFIG_FAILED");
        stopTest(false,now);
      }
    }
    return;
  }
  if(!targetHoriRunning()){
    state.usbStableWindowActive=false;
    state.usbStableWindowStartMs=0;
    return;
  }
  if(!state.usbStableWindowActive){
    state.usbStableWindowActive=true;
    state.usbStableWindowStartMs=now;
    if(state.firstValidRunningMs==0)state.firstValidRunningMs=now;
    return;
  }
  if(now-state.usbStableWindowStartMs<
     USB_LAN_W5500_RELEASE_AFTER_RUNNING_MS)return;
  state.usbStableWindowComplete=true;
  Serial.printf("USB_STABLE_WINDOW_COMPLETE=1 WINDOW_MS=%lu "
                "USB_STATE=%02X HID_READY=%u VID=%04X PID=%04X\n",
                (unsigned long)(now-state.usbStableWindowStartMs),
                state.usbTaskState,state.hidReady,state.vid,state.pid);
  if(kModePlan.setup==SetupPlan::kUsbRunningResetHeld)return;
  const MaxSnapshot beforeRelease=captureMaxSnapshot();
  printSnapshot("W5500_RESET_RELEASE_BEFORE",beforeRelease);
  releaseExternalSpiDevices();
  state.resetReleaseMs=millis();
  state.resetReleaseUs=micros();
  digitalWrite(Config::kLanReset,HIGH);
  state.w5500ResetReleased=true;
  state.resetReleasedAfterUsbRunning=true;
  state.lanAccessAllowed=false;
  if(kModePlan.setup==SetupPlan::kUsbRunningThenPhyProfile){
    state.phyApplyPending=true;
    Serial.printf("USB_STABLE_BEFORE_PHY_PROFILE=1 "
                  "W5500_EXTERNAL_RESET_RELEASED=1 "
                  "RESET_RELEASE_MILLIS=%lu RESET_RELEASE_MICROS=%lu "
                  "RUNNING_TO_RESET_RELEASE_MS=%lu PHY_PROFILE=%s\n",
                  (unsigned long)state.resetReleaseMs,
                  (unsigned long)state.resetReleaseUs,
                  (unsigned long)(state.resetReleaseMs-
                                  state.firstValidRunningMs),kPhyProfile.name);
  }else{
    Serial.printf("USB_STABLE_BEFORE_RESET_RELEASE=1 "
                  "W5500_RESET_RELEASED_AFTER_USB_RUNNING=1 "
                  "W5500_SPI_ACCESS=0 W5500_INIT=0 "
                  "RESET_RELEASE_MILLIS=%lu RESET_RELEASE_MICROS=%lu "
                  "RUNNING_TO_RESET_RELEASE_MS=%lu\n",
                  (unsigned long)state.resetReleaseMs,
                  (unsigned long)state.resetReleaseUs,
                  (unsigned long)(state.resetReleaseMs-
                                  state.firstValidRunningMs));
  }
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

void handleFailFastDetach(uint32_t now){
  if(!Config::kFailFastOnDetach||!state.failFastPending||
     state.failFastHandled)return;
  state.failFastHandled=true;
  state.dropDetected=true;
  state.dropMs=now;
  state.stopMs=now;
  Serial.printf("FAIL_FAST_DETACH=1 DETACH_USB_STATE_BEFORE=%02X "
                "DETACH_USB_STATE_AFTER=%02X DETACH_HID_REPORT_TOTAL=%lu "
                "DETACH_VID=%04X DETACH_PID=%04X\n",
                state.detachUsbStateBefore,state.usbTaskState,
                (unsigned long)state.detachHidReportTotal,
                state.lastReadyVid,state.lastReadyPid);
  if(state.resetReleasedAfterUsbRunning){
    Serial.printf("RESET_RELEASE_TO_DETACH_US=%lu "
                  "RESET_RELEASE_TO_HID_DROP_US=%lu "
                  "RUNNING_TO_RESET_RELEASE_MS=%lu\n",
                  (unsigned long)(state.detachUs-state.resetReleaseUs),
                  (unsigned long)(state.detachUs-state.resetReleaseUs),
                  (unsigned long)(state.resetReleaseMs-
                                   state.firstValidRunningMs));
  }
  if(kModePlan.setup==SetupPlan::kUsbRunningThenPhyProfile){
    const uint32_t fromProfile=state.phyProfileAppliedUs?
      state.detachUs-state.phyProfileAppliedUs:0;
    const int32_t fromLink=state.phyLinkObserved?
      static_cast<int32_t>(state.detachUs-state.phyLinkUpUs):-1;
    Serial.printf("PROFILE_APPLIED_TO_DETACH_US=%lu "
                  "RESET_RELEASE_TO_DETACH_US=%lu "
                  "LINK_UP_TO_DETACH_US=%ld LINK_WAS_UP_BEFORE_DETACH=%u "
                  "PHY_PROFILE=%s\n",(unsigned long)fromProfile,
                  (unsigned long)(state.detachUs-state.resetReleaseUs),
                  (long)fromLink,state.phyLinkObserved,kPhyProfile.name);
  }
  const MaxSnapshot detached=captureMaxSnapshot();
  printSnapshot("FAIL_FAST_DETACH",detached);
  releaseExternalSpiDevices();
  state.lanAccessAllowed=false;
  Serial.printf("FAIL_FAST_FINAL_SUMMARY USB_STATE=%02X HID_READY=%u "
                "VID=%04X PID=%04X HID_REPORT_TOTAL=%lu "
                "DETACH_MILLIS=%lu DETACH_MICROS=%lu\n",
                state.usbTaskState,state.hidReady,state.lastReadyVid,
                state.lastReadyPid,(unsigned long)state.detachHidReportTotal,
                (unsigned long)state.detachMs,(unsigned long)state.detachUs);
  stopTest(false,now);
}

void pollLinkWithSnapshots(){
  if(!state.lanAccessAllowed)return;
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
  if(revBefore.mismatch||revAfter.mismatch||revBefore.a!=revAfter.a){
    state.spiCorruptionSuspected=true;
  }
  ++state.linkPollCount;
}

void serviceFullDuplex(uint32_t now){
  if(!state.udpReady||!state.lanAccessAllowed)return;
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
    "MAX_REGISTER_TRIPLE_READ_MISMATCH=%lu "
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
    (unsigned long)state.maxSpiReadMismatch,
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
  if(kModePlan.setup==SetupPlan::kLanOnlyPhyLinkTiming){
    const bool measurementOk=passed&&state.phyProfileReadbackOk&&
                             !state.phyReadError;
    Serial.printf("TEST_COMPLETE=%s TEST_MODE=13 PHY_PROFILE=%s "
                  "LINK_OBSERVED=%u RESET_RELEASE_TO_LINK_UP_US=%lu "
                  "PHYCFGR_READ_COUNT=%lu PHYCFGR_READ_ERROR=%u "
                  "PHY_POLL_MAX_US=%lu RESULT_CLASS=%s\n",
                  measurementOk?"PASS":"FAIL",kPhyProfile.name,
                  state.phyLinkObserved,
                  state.phyLinkObserved?
                    (unsigned long)(state.phyLinkUpUs-state.resetReleaseUs):0UL,
                  (unsigned long)state.phyPollCount,state.phyReadError,
                  (unsigned long)state.phyPollMaxUs,
                  measurementOk?(state.phyLinkObserved?
                    "MEASUREMENT_COMPLETE":"NO_LINK_OBSERVED"):"FAIL");
    return;
  }
  const bool specialPlanReady=
    (kModePlan.setup!=SetupPlan::kUsbRunningResetHeld &&
     kModePlan.setup!=SetupPlan::kUsbRunningThenResetRelease &&
     kModePlan.setup!=SetupPlan::kUsbRunningThenPhyProfile) ||
    (state.usbStableWindowComplete &&
     (kModePlan.setup!=SetupPlan::kUsbRunningThenResetRelease ||
       state.resetReleasedAfterUsbRunning) &&
      (kModePlan.setup!=SetupPlan::kUsbRunningThenPhyProfile ||
       (state.phyProfileApplied&&state.phyProfileReadbackOk)));
  const bool criteriaPassed=passed && specialPlanReady &&
    state.everRunning && state.everHidReady &&
    state.usbTaskState==0x90 && state.hidReady && state.hidReportTotal>0 &&
    state.hidReadyDrop==0 && state.maxSpiReadMismatch==0 &&
    (!USB_POWERED_HUB_TEST ||
      (state.everPoweredHubTargetReady && state.poweredHubTargetReady));
  Serial.printf("TEST_COMPLETE=%s TEST_MODE=%d INIT_ORDER=%d DURATION_MS=%lu "
    "DROP_TIME_MS=%lu HID_READY_DROP=%lu MAX_SPI_READ_MISMATCH=%lu "
    "MAX_REGISTER_TRIPLE_READ_MISMATCH=%lu "
    "SPI_CORRUPTION_SUSPECTED=%u EVER_RUNNING=%u EVER_HID_READY=%u "
    "FINAL_USB_STATE=%02X FINAL_HID_READY=%u HID_REPORT_TOTAL=%lu "
    "DETACH_VID=%04X DETACH_PID=%04X DETACH_HID_REPORT_TOTAL=%lu "
    "USB_STABLE_WINDOW_COMPLETE=%u RESET_RELEASED_AFTER_USB_RUNNING=%u "
    "RESET_RELEASE_MILLIS=%lu RESET_RELEASE_MICROS=%lu "
    "PHY_PROFILE=%s PHY_PROFILE_APPLIED=%u PHY_PROFILE_READBACK_OK=%u "
    "PHY_LINK_OBSERVED=%u PHY_POLL_COUNT=%lu PHY_POLL_MAX_US=%lu\n",
    criteriaPassed?"PASS":"FAIL",USB_LAN_TEST_MODE,
    USB_LAN_INIT_ORDER,(unsigned long)(now-state.startMs),
    state.dropDetected?(unsigned long)(state.dropMs-state.startMs):0UL,
    (unsigned long)state.hidReadyDrop,(unsigned long)state.maxSpiReadMismatch,
    (unsigned long)state.maxSpiReadMismatch,
    state.spiCorruptionSuspected,state.everRunning,state.everHidReady,
    state.usbTaskState,state.hidReady,(unsigned long)state.hidReportTotal,
    state.lastReadyVid,state.lastReadyPid,
    (unsigned long)state.detachHidReportTotal,
    state.usbStableWindowComplete,state.resetReleasedAfterUsbRunning,
    (unsigned long)state.resetReleaseMs,(unsigned long)state.resetReleaseUs,
    kPhyProfile.name,state.phyProfileApplied,state.phyProfileReadbackOk,
    state.phyLinkObserved,(unsigned long)state.phyPollCount,
    (unsigned long)state.phyPollMaxUs);
}

#if USB_LAN_TEST_MODE == 15 || USB_LAN_TEST_MODE == 18
void c1ScopeMarker(const char* event,const char* result=nullptr){
#if USB_LAN_TEST_MODE == 18
  constexpr const char* kTrialName="DG-D";
#else
  constexpr const char* kTrialName="C1";
#endif
  if(result){
    Serial.printf("SCOPE_MARKER trial=%s event=%s result=%s\n",
                  kTrialName,event,result);
  }else{
    Serial.printf("SCOPE_MARKER trial=%s event=%s\n",kTrialName,event);
  }
}

uint8_t c1ReadVersion(){
  prepareForLanAccess();
  SPI.beginTransaction(SPI_ETHERNET_SETTINGS);
  const uint8_t value=W5100.readVERSIONR_W5500();
  SPI.endTransaction();
  releaseExternalSpiDevices();
  return value;
}

bool c1CheckBufferMap(const char* reason){
  C1BufferMap map{};
  prepareForLanAccess();
  SPI.beginTransaction(SPI_ETHERNET_SETTINGS);
  for(uint8_t socket=0;socket<8;++socket){
    map.rxKb[socket]=W5100.readSnRX_SIZE(socket);
    map.txKb[socket]=W5100.readSnTX_SIZE(socket);
  }
  SPI.endTransaction();
  releaseExternalSpiDevices();
  bool ok=W5100.SSIZE==8192 && W5100.SMASK==8191;
  Serial.printf("BUFFER_MAP_CHECK reason=%s\n",reason);
  for(uint8_t socket=0;socket<8;++socket){
    Serial.printf("S%u_RX=%u S%u_TX=%u\n",socket,map.rxKb[socket],
                  socket,map.txKb[socket]);
    const uint8_t expected=socket<2?8:0;
    if(map.rxKb[socket]!=expected||map.txKb[socket]!=expected)ok=false;
  }
  Serial.printf("SSIZE=%u\nSMASK=%u\nCH_BASE_MSB_INDIRECT_OK=%u\n"
                "BUFFER_MAP_OK=%u\n",W5100.SSIZE,W5100.SMASK,ok,ok);
  return ok;
}

bool c1CheckFixed10Half(bool requireLink,uint8_t* valueOut=nullptr){
  constexpr uint8_t kPhyReset=0x80;
  constexpr uint8_t kOperationModeFromRegister=0x40;
  constexpr uint8_t kOperationModeMask=0x38;
  constexpr uint8_t kDuplex=0x04;
  constexpr uint8_t kSpeed=0x02;
  constexpr uint8_t kLink=0x01;
  const uint8_t value=readW5500PhyCfgr();
  if(valueOut)*valueOut=value;
  const bool profileOk=(value&static_cast<uint8_t>(kPhyReset|
      kOperationModeFromRegister|kOperationModeMask))==
      static_cast<uint8_t>(kPhyReset|kOperationModeFromRegister);
  const bool speedOk=(value&kSpeed)==0;
  const bool duplexOk=(value&kDuplex)==0;
  const bool linkOk=(value&kLink)!=0;
  const bool ok=profileOk&&speedOk&&duplexOk&&(!requireLink||linkOk);
  Serial.printf("C1_PHY_CHECK RAW=%02X RST=%u OPMD=%u OPMDC=%u "
                "SPEED_MBPS=%u DUPLEX=%s LINK=%u REQUIRE_LINK=%u OK=%u\n",
                value,(value>>7)&1,(value>>6)&1,(value>>3)&7,
                speedOk?10:100,duplexOk?"HALF":"FULL",linkOk,
                requireLink,ok);
  return ok;
}

bool c1ConfigureNetwork(){
  prepareForLanAccess();
  Ethernet.setMACAddress(Config::kMac);
  releaseExternalSpiDevices();
  prepareForLanAccess();
  Ethernet.setLocalIP(Config::kLocalIp);
  releaseExternalSpiDevices();
  prepareForLanAccess();
  Ethernet.setGatewayIP(Config::kGateway);
  releaseExternalSpiDevices();
  prepareForLanAccess();
  Ethernet.setSubnetMask(Config::kSubnet);
  releaseExternalSpiDevices();
  prepareForLanAccess();
  Ethernet.setDnsServerIP(Config::kDns);
  releaseExternalSpiDevices();

  uint8_t actualMac[6]{};
  prepareForLanAccess();
  Ethernet.MACAddress(actualMac);
  releaseExternalSpiDevices();
  prepareForLanAccess();
  const IPAddress actualIp=Ethernet.localIP();
  releaseExternalSpiDevices();
  prepareForLanAccess();
  const IPAddress actualGateway=Ethernet.gatewayIP();
  releaseExternalSpiDevices();
  prepareForLanAccess();
  const IPAddress actualSubnet=Ethernet.subnetMask();
  releaseExternalSpiDevices();
  prepareForLanAccess();
  const IPAddress actualDns=Ethernet.dnsServerIP();
  releaseExternalSpiDevices();
  bool macOk=true;
  for(uint8_t index=0;index<6;++index){
    if(actualMac[index]!=Config::kMac[index])macOk=false;
  }
  const bool ok=macOk&&actualIp==Config::kLocalIp&&
                actualGateway==Config::kGateway&&
                actualSubnet==Config::kSubnet&&actualDns==Config::kDns;
  state.actualIp=actualIp;
  Serial.printf("C1_NETWORK_READBACK MAC=%02X:%02X:%02X:%02X:%02X:%02X "
                "LOCAL_IP=%u.%u.%u.%u GATEWAY=%u.%u.%u.%u "
                "SUBNET=%u.%u.%u.%u DNS=%u.%u.%u.%u OK=%u\n",
                actualMac[0],actualMac[1],actualMac[2],actualMac[3],
                actualMac[4],actualMac[5],actualIp[0],actualIp[1],
                actualIp[2],actualIp[3],actualGateway[0],actualGateway[1],
                actualGateway[2],actualGateway[3],actualSubnet[0],
                actualSubnet[1],actualSubnet[2],actualSubnet[3],actualDns[0],
                actualDns[1],actualDns[2],actualDns[3],ok);
  return ok;
}

bool c1AuditUdpSocket(){
  uint8_t udpCount=0;
  prepareForLanAccess();
  SPI.beginTransaction(SPI_ETHERNET_SETTINGS);
  for(uint8_t socket=0;socket<8;++socket){
    const uint8_t status=W5100.readSnSR(socket);
    Serial.printf("C1_SOCKET_STATUS S%u=%02X\n",socket,status);
    if(status==SnSR::UDP)++udpCount;
  }
  SPI.endTransaction();
  releaseExternalSpiDevices();
  Serial.printf("C1_UDP_SOCKET_COUNT=%u OK=%u\n",udpCount,udpCount==1);
  return udpCount==1;
}

void c1FailSetup(const char* reason){
  if(state.stopped)return;
  releaseExternalSpiDevices();
  state.lanAccessAllowed=false;
  state.stopped=true;
  Serial.printf("C1_SETUP_FAIL=1 REASON=%s\n",reason);
  Serial.printf("TEST_COMPLETE=FAIL TEST_MODE=%d TEST_MODE_NAME=%s "
                "REASON=%s FINAL_USB_STATE=%02X FINAL_HID_READY=%u "
                "HID_READY_DROP=%lu\n",USB_LAN_TEST_MODE,kModePlan.name,reason,
                state.usbTaskState,state.hidReady,
                (unsigned long)state.hidReadyDrop);
  c1ScopeMarker("TRIAL_COMPLETE","FAIL");
}

bool initializeC1(){
#if USB_LAN_TEST_MODE == 18
  Serial.println("DG_D_ARCHITECTURE=LAN_FIRST FIXED10HALF "
                 "USB_HEALTH_RX_NULL_DISCARD_TX");
  Serial.println("DG_D_TREATMENT=POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD "
                 "PAYLOAD_BYTES=32 NON_NULL_PAYLOAD_READ=0");
#else
  Serial.println("C1_ARCHITECTURE=LAN_FIRST FIXED10HALF UDP_TX_ONLY "
                 "ETHERNET_BEGIN=0 DHCP=0 SCOPE_RESULT=NOT_CAPTURED");
#endif
  Serial.printf("C1_PEER_IP=%u.%u.%u.%u PEER_PORT=%u "
                "PEER_IDENTITY=PC_ONLY_REQUIRED\n",Config::kC1PeerIp[0],
                Config::kC1PeerIp[1],Config::kC1PeerIp[2],
                Config::kC1PeerIp[3],Config::kPort);
  releaseExternalSpiDevices();
  Serial.printf("SPI_INIT_OWNER=C1_LAN COUNT=1 CALL=SPI.begin(%u,%u,%u,-1)\n",
                PIN_SPI_SCK,PIN_SPI_MISO,PIN_SPI_MOSI);
  SPI.begin(PIN_SPI_SCK,PIN_SPI_MISO,PIN_SPI_MOSI,-1);
  c1ScopeMarker("PRE_RESET");
  const uint32_t resetLowUs=micros()-state.lanResetLowUs;
  if(resetLowUs<500){
    delayMicroseconds(500-resetLowUs);
  }
  digitalWrite(Config::kLanReset,HIGH);
  state.w5500ResetReleased=true;
  state.resetReleaseMs=millis();
  state.resetReleaseUs=micros();
  c1ScopeMarker("RESET_RELEASE");
  delayMicroseconds(1000);

  prepareForLanAccess();
  Ethernet.init(Config::kLanCs);
  releaseExternalSpiDevices();
  prepareForLanAccess();
  const uint32_t initStartUs=micros();
  const uint8_t initResult=W5100.init(1);
  const uint32_t initElapsedUs=micros()-initStartUs;
  releaseExternalSpiDevices();
  c1.w5100Init=initResult==1;
  const uint8_t chip=W5100.getChip();
  c1.version=c1ReadVersion();
  Serial.printf("C1_W5100_INIT_COUNT=1 RESULT=%u DURATION_US=%lu CHIP=%u "
                "VERSIONR=%02X SSIZE=%u SMASK=%u\n",initResult,
                (unsigned long)initElapsedUs,chip,c1.version,W5100.SSIZE,
                W5100.SMASK);
  if(!c1.w5100Init){c1FailSetup("W5100_INIT");return false;}
  if(chip!=55){c1FailSetup("CHIP_ID");return false;}
  if(c1.version!=0x04){c1FailSetup("VERSIONR");return false;}
  if(!c1CheckBufferMap("C1_INIT_AFTER_W5100_INIT")){
    c1FailSetup("BUFFER_MAP_INIT");return false;
  }

  if(!applyW5500PhyProfile(
       kPhyProfiles[static_cast<uint8_t>(PhyProfileId::kFixed10Half)])){
    c1FailSetup("PHY_PROFILE");return false;
  }
  c1ScopeMarker("PHY_PROFILE_APPLIED");
  if(!c1CheckFixed10Half(false)){
    c1FailSetup("PHY_PROFILE_READBACK");return false;
  }
  if(!c1CheckBufferMap("C1_AFTER_FIXED10")){
    c1FailSetup("BUFFER_MAP_FIXED10");return false;
  }

  c1.networkConfig=c1ConfigureNetwork();
  if(!c1.networkConfig){c1FailSetup("NETWORK_CONFIG");return false;}
  if(!c1CheckFixed10Half(false)){
    c1FailSetup("PHY_AFTER_NETWORK_CONFIG");return false;
  }
  if(!c1CheckBufferMap("C1_AFTER_NETWORK_CONFIG")){
    c1FailSetup("BUFFER_MAP_NETWORK_CONFIG");return false;
  }

  const uint32_t linkWaitStartMs=millis();
  uint32_t linkStableStartMs=0;
  while(millis()-linkWaitStartMs<10000){
    uint8_t phy=0;
    const bool profileOk=c1CheckFixed10Half(false,&phy);
    if(!profileOk){
      c1FailSetup("LINK_PROFILE_CHANGED");return false;
    }
    if((phy&0x01)!=0){
      if(linkStableStartMs==0)linkStableStartMs=millis();
      if(millis()-linkStableStartMs>=500){c1.linkStable=true;break;}
    }else{
      linkStableStartMs=0;
    }
    delay(25);
  }
  if(!c1.linkStable){c1FailSetup("LINK_TIMEOUT");return false;}
  c1ScopeMarker("LINK_UP");

  Serial.println("UDP_BEGIN_ENTER");
  ++c1.udpBeginCount;
  prepareForLanAccess();
  const uint32_t udpBeginStartUs=micros();
  const uint8_t udpResult=udp.begin(Config::kPort);
  const uint32_t udpBeginUs=micros()-udpBeginStartUs;
  releaseExternalSpiDevices();
  c1.udpBeginMaxUs=udpBeginUs;
  c1.udpReady=udpResult==1;
  if(!c1.udpReady)++c1.udpBeginFail;
  Serial.printf("UDP_BEGIN_EXIT result=%u duration_us=%lu\n",udpResult,
                (unsigned long)udpBeginUs);
  if(!c1.udpReady){c1FailSetup("UDP_BEGIN");return false;}
  if(!c1AuditUdpSocket()){c1FailSetup("UDP_SOCKET");return false;}
  if(!c1CheckFixed10Half(true)){
    c1FailSetup("PHY_AFTER_UDP_BEGIN");return false;
  }
  if(!c1CheckBufferMap("C1_AFTER_UDP_BEGIN")){
    c1FailSetup("BUFFER_MAP_UDP_BEGIN");return false;
  }
  c1.version=c1ReadVersion();
  if(c1.version!=0x04){c1FailSetup("VERSION_AFTER_UDP_BEGIN");return false;}
  c1ScopeMarker("UDP_START");
  if(!c1CheckBufferMap("C1_BEFORE_USB_INIT")){
    c1FailSetup("BUFFER_MAP_USB_INIT");return false;
  }

  prepareForUsbAccess();
  initializeUsb();
  if(!state.usbInit||!state.parser){c1FailSetup("USB_INIT");return false;}
  const uint32_t usbWaitStartMs=millis();
  uint32_t usbStableStartMs=0;
  uint32_t lastLinkCheckMs=usbWaitStartMs;
  while(millis()-usbWaitStartMs<10000){
    serviceUsbTask();
    updateUsbIdentity();
    const uint32_t now=millis();
    if(targetHoriRunning()){
      if(usbStableStartMs==0)usbStableStartMs=now;
      if(now-usbStableStartMs>=1000){c1.usbStable=true;break;}
    }else{
      usbStableStartMs=0;
    }
    if(now-lastLinkCheckMs>=250){
      lastLinkCheckMs=now;
      if(!c1CheckFixed10Half(true)){
        c1FailSetup("PHY_DURING_USB_STABILITY");return false;
      }
    }
    delay(1);
  }
  if(!c1.usbStable){c1FailSetup("HORI_READY");return false;}
  state.usbStableWindowComplete=true;
  state.previousUsbTaskState=state.usbTaskState;
  state.previousHidReady=state.hidReady;
  state.startMs=millis();
  c1.trialStartMs=state.startMs;
  c1.nextDeadlineUs=micros()+20000UL;
  c1.lastRuntimeCheckMs=state.startMs;
  c1.lastHidReportMs=state.startMs;
  c1.lastHidReportTotal=state.hidReportTotal;
  state.maxUsbGapUs=0;
  state.maxUsbTaskUs=0;
  state.lanAccessAllowed=true;
  Serial.printf("C1_READY=1 USB_STATE=%02X HID_READY=%u VID=%04X PID=%04X "
                "USB_STABLE_MS=1000 LINK_STABLE_MS=500\n",state.usbTaskState,
                state.hidReady,state.vid,state.pid);
  Serial.println("DIAGNOSTIC_START");
  return true;
}

uint16_t c1Crc16(const uint8_t* data,size_t length){
  uint16_t crc=0xFFFF;
  for(size_t index=0;index<length;++index){
    crc^=static_cast<uint16_t>(data[index])<<8;
    for(uint8_t bit=0;bit<8;++bit){
      crc=(crc&0x8000)?static_cast<uint16_t>((crc<<1)^0x1021):
                       static_cast<uint16_t>(crc<<1);
    }
  }
  return crc;
}

void c1WriteU32Be(uint8_t* destination,uint32_t value){
  destination[0]=static_cast<uint8_t>(value>>24);
  destination[1]=static_cast<uint8_t>(value>>16);
  destination[2]=static_cast<uint8_t>(value>>8);
  destination[3]=static_cast<uint8_t>(value);
}

void c1BuildFrame(uint8_t frame[32],uint32_t sequence,uint32_t deviceMicros){
  frame[0]='C';frame[1]='1';frame[2]='U';frame[3]='D';
  frame[4]=1;frame[5]=1;
  frame[6]=static_cast<uint8_t>((targetHoriRunning()?0x01:0x00)|
                               (c1.linkStable?0x02:0x00));
  frame[7]=32;
  c1WriteU32Be(frame+8,sequence);
  c1WriteU32Be(frame+12,deviceMicros);
  for(uint8_t index=0;index<14;++index){
    frame[16+index]=static_cast<uint8_t>(sequence+index*17U+0x5AU);
  }
  const uint16_t crc=c1Crc16(frame,30);
  frame[30]=static_cast<uint8_t>(crc>>8);
  frame[31]=static_cast<uint8_t>(crc);
}

void c1UpdateMax(uint32_t value,uint32_t& maximum){
  if(value>maximum)maximum=value;
}

void c1SendFrame(){
  uint8_t frame[32]{};
  const uint32_t attemptUs=micros();
  if(c1.lastTxUs)c1UpdateMax(attemptUs-c1.lastTxUs,c1.udpMaxGapUs);
  c1.lastTxUs=attemptUs;
  c1BuildFrame(frame,c1.sequence,attemptUs);
  ++c1.udpTxTotal;
  bool sent=true;

  prepareForLanAccess();
  uint32_t phaseStartUs=micros();
  const int beginResult=udp.beginPacket(Config::kC1PeerIp,Config::kPort);
  c1UpdateMax(micros()-phaseStartUs,c1.udpBeginPacketMaxUs);
  releaseExternalSpiDevices();
  sent=beginResult==1;

  size_t writeResult=0;
  if(sent){
    prepareForLanAccess();
    phaseStartUs=micros();
    writeResult=udp.write(frame,sizeof(frame));
    c1UpdateMax(micros()-phaseStartUs,c1.udpWriteMaxUs);
    releaseExternalSpiDevices();
    sent=writeResult==sizeof(frame);
  }

  int endResult=0;
  if(sent){
    prepareForLanAccess();
    phaseStartUs=micros();
    endResult=udp.endPacket();
    c1UpdateMax(micros()-phaseStartUs,c1.udpEndPacketMaxUs);
    releaseExternalSpiDevices();
    sent=endResult==1;
  }
  releaseExternalSpiDevices();
  if(!sent)++c1.udpTxFail;
  ++c1.sequence;
}

void c1PrintStatistics(const char* prefix){
  Serial.printf("%s UDP_TX_TOTAL=%lu UDP_TX_FAIL=%lu UDP_BEGIN_COUNT=%lu "
                "UDP_BEGIN_FAIL=%lu UDP_BEGIN_MAX_US=%lu "
                "UDP_BEGIN_PACKET_MAX_US=%lu UDP_WRITE_MAX_US=%lu "
                "UDP_END_PACKET_MAX_US=%lu UDP_MAX_GAP_US=%lu "
                "SCHEDULER_MISSED_DEADLINE=%lu "
                "SCHEDULER_MAX_LATENESS_US=%lu LOOP_MAX_US=%lu "
                "HID_STALL_COUNT=%lu HID_MAX_NO_REPORT_MS=%lu\n",prefix,
                (unsigned long)c1.udpTxTotal,(unsigned long)c1.udpTxFail,
                (unsigned long)c1.udpBeginCount,(unsigned long)c1.udpBeginFail,
                (unsigned long)c1.udpBeginMaxUs,
                (unsigned long)c1.udpBeginPacketMaxUs,
                (unsigned long)c1.udpWriteMaxUs,
                (unsigned long)c1.udpEndPacketMaxUs,
                (unsigned long)c1.udpMaxGapUs,
                (unsigned long)c1.schedulerMissedDeadline,
                (unsigned long)c1.schedulerMaxLatenessUs,
                (unsigned long)c1.loopMaxUs,
                (unsigned long)c1.hidStallCount,
                (unsigned long)c1.hidMaxNoReportMs);
}

#if USB_LAN_TEST_MODE == 18
constexpr uint32_t DG_D_DRAIN_QUIET_REQUIRED_MS=100;
constexpr uint32_t DG_D_DRAIN_TIMEOUT_MS=1000;

const char* dgDPhaseText(){
  switch(c1.dgDPhase){
    case DgDPhase::kActive:return "ACTIVE";
    case DgDPhase::kDrain:return "DRAIN";
    case DgDPhase::kComplete:return "COMPLETE";
    case DgDPhase::kBlocked:return "BLOCKED";
  }
  return "BLOCKED";
}

void dgDPrintStatistics(const char* prefix){
  Serial.printf("%s RX_PARSE_CALL_STARTED_TOTAL=%lu "
                "RX_PARSE_CALL_COMPLETED_TOTAL=%lu RX_PARSE_ZERO_TOTAL=%lu "
                "RX_PARSE_POSITIVE_TOTAL=%lu RX_PARSE_NEGATIVE_TOTAL=%lu "
                "RX_POSITIVE_SIZE_32_TOTAL=%lu "
                "RX_POSITIVE_OTHER_SIZE_TOTAL=%lu "
                "RX_POSITIVE_OTHER_SIZE_FIRST=%ld "
                "RX_POSITIVE_OTHER_SIZE_LAST=%ld "
                "RX_PRE_PARSE_REMAINING_NONZERO=%lu "
                "RX_NULL_DISCARD_CALL_TOTAL=%lu "
                "RX_NULL_DISCARD_RETURN_TOTAL=%lu "
                "RX_NULL_DISCARD_REQUEST_BYTES_TOTAL=%lu "
                "RX_NULL_DISCARD_BYTES_TOTAL=%lu "
                "RX_NULL_DISCARD_FAIL_TOTAL=%lu "
                "RX_NULL_DISCARD_LAST_RETURN=%ld "
                "RX_POST_DISCARD_REMAINING_NONZERO=%lu "
                "RX_PARSE_MAX_US=%lu RX_NULL_DISCARD_MAX_US=%lu "
                "RX_TREATMENT_MAX_US=%lu DG_D_PHASE=%s\n",prefix,
                (unsigned long)c1.rxParseCallStartedTotal,
                (unsigned long)c1.rxParseCallCompletedTotal,
                (unsigned long)c1.rxParseZeroTotal,
                (unsigned long)c1.rxParsePositiveTotal,
                (unsigned long)c1.rxParseNegativeTotal,
                (unsigned long)c1.rxPositiveSize32Total,
                (unsigned long)c1.rxPositiveOtherSizeTotal,
                (long)c1.rxPositiveOtherSizeFirst,
                (long)c1.rxPositiveOtherSizeLast,
                (unsigned long)c1.rxPreParseRemainingNonzero,
                (unsigned long)c1.rxNullDiscardCallTotal,
                (unsigned long)c1.rxNullDiscardReturnTotal,
                (unsigned long)c1.rxNullDiscardRequestBytesTotal,
                (unsigned long)c1.rxNullDiscardBytesTotal,
                (unsigned long)c1.rxNullDiscardFailTotal,
                (long)c1.rxNullDiscardLastReturn,
                (unsigned long)c1.rxPostDiscardRemainingNonzero,
                (unsigned long)c1.rxParseMaxUs,
                (unsigned long)c1.rxNullDiscardMaxUs,
                (unsigned long)c1.rxTreatmentMaxUs,dgDPhaseText());
  Serial.printf("%s DRAIN_TARGET_TX_TOTAL=%lu DRAIN_ENTER_MS=%lu "
                "DRAIN_COMPLETE_MS=%lu DRAIN_TIMEOUT_MS=%lu "
                "DRAIN_QUIET_REQUIRED_MS=%lu DRAIN_QUIET_OBSERVED_MS=%lu "
                "DRAIN_PARSE_POSITIVE_START_TOTAL=%lu "
                "DRAIN_PARSE_POSITIVE_END_TOTAL=%lu "
                "DRAIN_ZERO_CONFIRMATION_TOTAL=%lu DRAIN_RESULT=%s "
                "DRAIN_BLOCK_REASON=%s\n",prefix,
                (unsigned long)c1.drainTargetTxTotal,
                (unsigned long)c1.drainEnterMs,
                (unsigned long)c1.drainCompleteMs,
                (unsigned long)DG_D_DRAIN_TIMEOUT_MS,
                (unsigned long)DG_D_DRAIN_QUIET_REQUIRED_MS,
                (unsigned long)c1.drainQuietObservedMs,
                (unsigned long)c1.drainParsePositiveStartTotal,
                (unsigned long)c1.drainParsePositiveEndTotal,
                (unsigned long)c1.drainZeroConfirmationTotal,
                c1.dgDPhase==DgDPhase::kComplete?"PASS":
                  (c1.dgDPhase==DgDPhase::kBlocked?"BLOCKED":"PENDING"),
                c1.dgDBlockReason);
}
#endif

void c1Finish(bool passed,const char* reason){
  if(state.stopped)return;
#if USB_LAN_TEST_MODE == 18
  if(passed){
    c1.dgDPhase=DgDPhase::kComplete;
    c1.dgDBlockReason="NONE";
  }else{
    c1.dgDPhase=DgDPhase::kBlocked;
    c1.dgDBlockReason=reason;
  }
  c1.drainParsePositiveEndTotal=c1.rxParsePositiveTotal;
  if(c1.drainQuietStartMs!=0){
    c1.drainQuietObservedMs=millis()-c1.drainQuietStartMs;
  }
#endif
  updateUsbIdentity();
  captureMaxSnapshot();
  c1.finalPhyOk=c1.w5100Init&&c1CheckFixed10Half(true);
  c1.version=c1.w5100Init?c1ReadVersion():0;
  c1.finalVersionOk=c1.version==0x04;
  c1.finalBufferMapOk=c1.w5100Init&&c1CheckBufferMap("C1_TRIAL_END");
  const bool finalUsbOk=state.usbTaskState==0x90&&state.hidReady;
  bool runtimePass=passed&&c1.udpTxTotal>0&&c1.udpTxFail==0&&
    c1.hidStallCount==0&&state.hidReadyDrop==0&&finalUsbOk&&
    c1.finalPhyOk&&c1.finalVersionOk&&c1.finalBufferMapOk&&
    state.maxSpiReadMismatch==0&&!state.spiCorruptionSuspected;
#if USB_LAN_TEST_MODE == 18
  runtimePass=runtimePass&&c1.dgDPhase==DgDPhase::kComplete&&
    c1.schedulerMissedDeadline==0&&c1.rxParsePositiveTotal>0&&
    c1.rxParseCallStartedTotal==c1.rxParseCallCompletedTotal&&
    c1.rxParseCallCompletedTotal==c1.rxParseZeroTotal+
      c1.rxParsePositiveTotal+c1.rxParseNegativeTotal&&
    c1.rxParseNegativeTotal==0&&c1.rxPositiveOtherSizeTotal==0&&
    c1.rxPositiveSize32Total==c1.rxParsePositiveTotal&&
    c1.rxPreParseRemainingNonzero==0&&
    c1.rxNullDiscardCallTotal==c1.rxParsePositiveTotal&&
    c1.rxNullDiscardReturnTotal==c1.rxParsePositiveTotal&&
    c1.rxNullDiscardRequestBytesTotal==32UL*c1.rxParsePositiveTotal&&
    c1.rxNullDiscardBytesTotal==32UL*c1.rxParsePositiveTotal&&
    c1.rxNullDiscardFailTotal==0&&
    c1.rxPostDiscardRemainingNonzero==0&&
    c1.rxParsePositiveTotal==c1.drainTargetTxTotal&&
    c1.rxNullDiscardReturnTotal==c1.drainTargetTxTotal&&
    c1.drainQuietObservedMs>=DG_D_DRAIN_QUIET_REQUIRED_MS;
#endif
  releaseExternalSpiDevices();
  state.lanAccessAllowed=false;
  state.stopped=true;
  c1PrintStatistics("C1_FINAL");
#if USB_LAN_TEST_MODE == 18
  dgDPrintStatistics("DG_D_FINAL");
#endif
  Serial.printf("TEST_COMPLETE=%s TEST_MODE=%d TEST_MODE_NAME=%s "
                "DURATION_MS=%lu TRIAL_RUNTIME_MS=%lu REASON=%s "
                "FINAL_USB_STATE=%02X FINAL_HID_READY=%u "
                "HID_READY_DROP=%lu HID_STALL_COUNT=%lu "
                "HID_MAX_NO_REPORT_MS=%lu VID=%04X PID=%04X "
                "HID_REPORT_TOTAL=%lu FINAL_PHY_OK=%u FINAL_VERSION_OK=%u "
                "FINAL_BUFFER_MAP_OK=%u VERSIONR=%02X "
                "MAX_REGISTER_TRIPLE_READ_MISMATCH=%lu "
                "SPI_CORRUPTION_SUSPECTED=%u SCOPE_RESULT=NOT_CAPTURED\n",
                runtimePass?"PASS":"FAIL",USB_LAN_TEST_MODE,kModePlan.name,
                (unsigned long)(millis()-c1.trialStartMs),
                (unsigned long)(millis()-c1.trialStartMs),reason,
                state.usbTaskState,
                state.hidReady,(unsigned long)state.hidReadyDrop,
                (unsigned long)c1.hidStallCount,
                (unsigned long)c1.hidMaxNoReportMs,state.vid,state.pid,
                (unsigned long)state.hidReportTotal,c1.finalPhyOk,
                c1.finalVersionOk,c1.finalBufferMapOk,c1.version,
                (unsigned long)state.maxSpiReadMismatch,
                state.spiCorruptionSuspected);
  c1ScopeMarker("TRIAL_COMPLETE",runtimePass?"PASS":"FAIL");
}

#if USB_LAN_TEST_MODE == 18
bool dgDProcessIncomingEcho(){
  const int preRemaining=udp.available();
  if(preRemaining!=0){
    ++c1.rxPreParseRemainingNonzero;
    c1Finish(false,"BLOCKED_DG_D_PRE_PARSE_REMAINING_NONZERO");
    return false;
  }

  const uint32_t treatmentStartUs=micros();
  prepareForLanAccess();
  ++c1.rxParseCallStartedTotal;
  const uint32_t parseStartUs=micros();
  const int packetSize=udp.parsePacket();
  c1UpdateMax(micros()-parseStartUs,c1.rxParseMaxUs);
  ++c1.rxParseCallCompletedTotal;
  c1.rxLastParseResult=packetSize;

  if(packetSize==0){
    ++c1.rxParseZeroTotal;
    releaseExternalSpiDevices();
    c1UpdateMax(micros()-treatmentStartUs,c1.rxTreatmentMaxUs);
    return true;
  }
  if(packetSize<0){
    ++c1.rxParseNegativeTotal;
    releaseExternalSpiDevices();
    c1UpdateMax(micros()-treatmentStartUs,c1.rxTreatmentMaxUs);
    c1Finish(false,"BLOCKED_DG_D_PARSE_API_NEGATIVE");
    return false;
  }

  ++c1.rxParsePositiveTotal;
  if(packetSize!=32){
    ++c1.rxPositiveOtherSizeTotal;
    if(c1.rxPositiveOtherSizeTotal==1){
      c1.rxPositiveOtherSizeFirst=packetSize;
    }
    c1.rxPositiveOtherSizeLast=packetSize;
    releaseExternalSpiDevices();
    c1UpdateMax(micros()-treatmentStartUs,c1.rxTreatmentMaxUs);
    c1Finish(false,"BLOCKED_DG_D_POSITIVE_SIZE_NOT_32");
    return false;
  }

  ++c1.rxPositiveSize32Total;
  ++c1.rxNullDiscardCallTotal;
  c1.rxNullDiscardRequestBytesTotal+=32;
  const uint32_t discardStartUs=micros();
  const int discarded=udp.read(static_cast<uint8_t*>(nullptr),
                               static_cast<size_t>(packetSize));
  c1UpdateMax(micros()-discardStartUs,c1.rxNullDiscardMaxUs);
  ++c1.rxNullDiscardReturnTotal;
  c1.rxNullDiscardLastReturn=discarded;
  if(discarded>0){
    c1.rxNullDiscardBytesTotal+=static_cast<uint32_t>(discarded);
  }
  const bool discardOk=discarded==32;
  if(!discardOk)++c1.rxNullDiscardFailTotal;
  releaseExternalSpiDevices();
  c1UpdateMax(micros()-treatmentStartUs,c1.rxTreatmentMaxUs);

  const int postRemaining=udp.available();
  const bool postOk=postRemaining==0;
  if(!postOk)++c1.rxPostDiscardRemainingNonzero;
  if(!discardOk){
    c1Finish(false,"BLOCKED_DG_D_NULL_DISCARD_RETURN_MISMATCH");
    return false;
  }
  if(!postOk){
    c1Finish(false,"BLOCKED_DG_D_POST_DISCARD_REMAINING_NONZERO");
    return false;
  }
  return true;
}

void dgDEnterDrain(uint32_t nowMs){
  c1.dgDPhase=DgDPhase::kDrain;
  c1.drainTargetTxTotal=c1.udpTxTotal;
  c1.drainEnterMs=nowMs;
  c1.drainParsePositiveStartTotal=c1.rxParsePositiveTotal;
  c1.drainQuietStartMs=0;
  Serial.printf("DG_D_DRAIN_ENTER=1 DRAIN_TARGET_TX_TOTAL=%lu "
                "DRAIN_ENTER_MS=%lu\n",
                (unsigned long)c1.drainTargetTxTotal,
                (unsigned long)c1.drainEnterMs);
}

bool dgDServiceDrain(uint32_t nowMs){
  if(c1.rxParsePositiveTotal>c1.drainTargetTxTotal ||
     c1.rxNullDiscardReturnTotal>c1.drainTargetTxTotal){
    c1Finish(false,"BLOCKED_DG_D_RECONCILIATION_MISMATCH");
    return false;
  }
  const bool countsEqual=
    c1.rxParsePositiveTotal==c1.drainTargetTxTotal&&
    c1.rxNullDiscardReturnTotal==c1.drainTargetTxTotal;
  if(countsEqual){
    if(c1.drainQuietStartMs==0)c1.drainQuietStartMs=nowMs;
    if(c1.rxLastParseResult==0)++c1.drainZeroConfirmationTotal;
    c1.drainQuietObservedMs=nowMs-c1.drainQuietStartMs;
    if(c1.drainQuietObservedMs>=DG_D_DRAIN_QUIET_REQUIRED_MS){
      c1.drainCompleteMs=nowMs;
      c1Finish(true,"DRAIN_COMPLETE");
      return false;
    }
  }
  if(nowMs-c1.drainEnterMs>=DG_D_DRAIN_TIMEOUT_MS){
    c1Finish(false,"BLOCKED_DG_D_DRAIN_TIMEOUT");
    return false;
  }
  return true;
}
#endif

void loopC1(){
  const uint32_t loopStartUs=micros();
  serviceUsbTask();
  updateUsbIdentity();
  const uint32_t nowMs=millis();
  if(!targetHoriRunning()){
    if(!c1.detachMarkerPrinted){
      c1.detachMarkerPrinted=true;
      c1ScopeMarker("USB_DETACH");
    }
    c1Finish(false,"USB_DETACH_OR_UNSUPPORTED");
    return;
  }
  if(state.hidReportTotal!=c1.lastHidReportTotal){
    c1.lastHidReportTotal=state.hidReportTotal;
    c1.lastHidReportMs=nowMs;
  }
  const uint32_t noReportMs=nowMs-c1.lastHidReportMs;
  c1UpdateMax(noReportMs,c1.hidMaxNoReportMs);
  if(noReportMs>100){
    ++c1.hidStallCount;
    c1Finish(false,"HID_STALL");
    return;
  }
  if(nowMs-c1.lastRuntimeCheckMs>=250){
    c1.lastRuntimeCheckMs=nowMs;
    captureMaxSnapshot();
    if(state.maxSpiReadMismatch!=0){
      state.spiCorruptionSuspected=true;
      c1Finish(false,"MAX_REGISTER_MISMATCH");
      return;
    }
    if(!c1CheckFixed10Half(true)){
      c1.linkStable=false;
      c1Finish(false,"LINK_OR_PHY_CHANGED");
      return;
    }
  }

#if USB_LAN_TEST_MODE == 18
  if(!dgDProcessIncomingEcho())return;
  if(c1.dgDPhase==DgDPhase::kActive &&
     nowMs-c1.trialStartMs>=USB_LAN_TEST_DURATION_MS){
    dgDEnterDrain(nowMs);
  }
  if(c1.dgDPhase==DgDPhase::kDrain && !dgDServiceDrain(nowMs))return;
#endif

  const uint32_t nowUs=micros();
  const int32_t lateness=static_cast<int32_t>(nowUs-c1.nextDeadlineUs);
  if(lateness>=0
#if USB_LAN_TEST_MODE == 18
     && c1.dgDPhase==DgDPhase::kActive
#endif
  ){
    const uint32_t latenessUs=static_cast<uint32_t>(lateness);
    c1UpdateMax(latenessUs,c1.schedulerMaxLatenessUs);
    const uint32_t skipped=latenessUs/20000UL;
    c1.schedulerMissedDeadline+=skipped;
    c1.nextDeadlineUs+=(skipped+1UL)*20000UL;
    c1SendFrame();
  }
  const uint32_t loopElapsedUs=micros()-loopStartUs;
  c1UpdateMax(loopElapsedUs,c1.loopMaxUs);
  if(nowMs-state.lastSerialMs>=1000){
    state.lastSerialMs=nowMs;
    c1PrintStatistics("C1_DIAG");
#if USB_LAN_TEST_MODE == 18
    dgDPrintStatistics("DG_D_DIAG");
#endif
  }
#if USB_LAN_TEST_MODE == 15
  if(nowMs-c1.trialStartMs>=USB_LAN_TEST_DURATION_MS){
    c1Finish(c1.udpTxFail==0,"DURATION_COMPLETE");
  }
#endif
}
#endif

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
    "LINK_POLL=%u FULL_DUPLEX=%u FAIL_FAST=%u RESET_REASON=%s\n",USB_LAN_TEST_MODE,
    USB_LAN_INIT_ORDER,Config::kDisplayEnabled,Config::kLanInitEnabled,
    Config::kLinkPollEnabled,Config::kFullDuplexEnabled,
    Config::kFailFastOnDetach,resetText());
  Serial.printf("MODE_PLAN TEST_MODE_NAME=%s DISPLAY=%u LAN_INIT=%u "
                "LINK_POLL=%u FULL_DUPLEX=%u FAIL_FAST=%u\n",
                kModePlan.name,Config::kDisplayEnabled,Config::kLanInitEnabled,
                Config::kLinkPollEnabled,Config::kFullDuplexEnabled,
                Config::kFailFastOnDetach);
  Serial.printf("TEST_MODE_NAME=%s\n",kModePlan.name);
  if(kModePlan.setup==SetupPlan::kLanOnlyPhyLinkTiming){
    Serial.printf("PHY_PROFILE=%s USB_INIT=0 USB_TASK=0 ETHERNET_BEGIN=0 "
                  "UDP=0 PHY_POLL_INTERVAL_MS=%lu\n",kPhyProfile.name,
                  (unsigned long)Config::kLanOnlyPhyPollMs);
  }else if(kModePlan.setup==SetupPlan::kUsbRunningThenPhyProfile){
    Serial.printf("PHY_PROFILE=%s PHY_POLL_INTERVAL_MS=%lu\n",kPhyProfile.name,
                  (unsigned long)Config::kUsbPhyPollMs);
  }
  bool setupReady=true;
  if(kModePlan.setup==SetupPlan::kUsbFixed10UdpTxOnly ||
     kModePlan.setup==
       SetupPlan::kUsbFixed10UdpPositiveParseImmediateNullDiscard){
#if USB_LAN_TEST_MODE == 15 || USB_LAN_TEST_MODE == 18
    initializeC1();
#endif
    return;
  }else if(kModePlan.setup==SetupPlan::kResetReleaseOnly){
    releaseW5500ResetOnly();
    initializeUsb();
  }else if(kModePlan.setup==SetupPlan::kInitThenResetHeld){
    initializeLan();
    setupReady=state.w5500Init&&state.lanConfig;
    holdW5500ResetAfterInit();
    if(setupReady)initializeUsb();
  }else if(kModePlan.setup==SetupPlan::kPhyPowerDown){
    initializeLan();
    setupReady=configureW5500PhyPowerDown();
    if(setupReady)initializeUsb();
  }else if(kModePlan.setup==SetupPlan::kUsbRunningResetHeld ||
           kModePlan.setup==SetupPlan::kUsbRunningThenResetRelease ||
           kModePlan.setup==SetupPlan::kUsbRunningThenPhyProfile){
    initializeUsbRunningResetPlan();
  }else if(kModePlan.setup==SetupPlan::kLanOnlyPhyLinkTiming){
    setupReady=initializeLanOnlyPhyTiming();
  }else if(USB_LAN_INIT_ORDER==1){
    initializeUsb();initializeLan();
  }else if(USB_LAN_INIT_ORDER==2){
    initializeLan();initializeUsb();
  }else{
    initializeUsb();
  }
  state.startMs=millis();
  state.lastRateMs=state.startMs;
  state.nextControlMs=state.startMs;
  if(!setupReady){
    releaseExternalSpiDevices();
    state.lanAccessAllowed=false;
    Serial.printf("TEST_RESULT=%s\n",
      kModePlan.setup==SetupPlan::kPhyPowerDown?"PHY_POWER_DOWN_FAILED":
      kModePlan.setup==SetupPlan::kLanOnlyPhyLinkTiming?
        "PHY_PROFILE_CONFIG_FAILED":"LAN_INIT_FAILED");
    stopTest(false,state.startMs);
    return;
  }
  if(kModePlan.setup==SetupPlan::kLanOnlyPhyLinkTiming){
    Serial.println("DIAGNOSTIC_START");
    return;
  }
  updateUsbIdentity();
  state.previousUsbTaskState=state.usbTaskState;
  const MaxSnapshot initial=captureMaxSnapshot();
  printSnapshot("INITIAL",initial);
  Serial.println("DIAGNOSTIC_START");
}

void loop(){
  if(state.stopped){delay(10);return;}
  if(kModePlan.setup==SetupPlan::kUsbFixed10UdpTxOnly ||
     kModePlan.setup==
       SetupPlan::kUsbFixed10UdpPositiveParseImmediateNullDiscard){
#if USB_LAN_TEST_MODE == 15 || USB_LAN_TEST_MODE == 18
    loopC1();
#endif
    return;
  }
  if(kModePlan.setup==SetupPlan::kLanOnlyPhyLinkTiming){
    const uint32_t now=millis();
    pollPhyProfile(now,Config::kLanOnlyPhyPollMs);
    if(now-state.startMs>=USB_LAN_TEST_DURATION_MS)stopTest(true,now);
    delay(1);
    return;
  }
  serviceUsbTask();
  uint32_t now=millis();
  updateUsbIdentity();
  checkUsbTransition(now);
  handleUsbRunningResetPlan(now);
  handleFailFastDetach(now);
  if(state.stopped)return;
  if(kModePlan.setup==SetupPlan::kUsbRunningThenPhyProfile){
    pollPhyProfile(now,Config::kUsbPhyPollMs);
  }
  M5.update();
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
    stopTest(false,now);
  }
  if(state.dropDetected && static_cast<int32_t>(now-state.stopMs)>=0){
    stopTest(false,now);
  }else if(!state.dropDetected && now-state.startMs>=USB_LAN_TEST_DURATION_MS){
    stopTest(true,now);
  }
}
