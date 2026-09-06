#include "src/core_safety/UartOutput.h"
#include "src/core_safety/UartInput.h"
#include "src/core_safety/RollerSwitch.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
using namespace core_protocol;
static unsigned checks=0;
static void check(bool p,const char* why){++checks;if(!p){std::fprintf(stderr,"FAIL %s\n",why);std::exit(1);}}
struct Wire {
  int space=128; size_t written=32; std::vector<uint8_t> bytes;
  int availableForWrite(){return space;}
  size_t write(const uint8_t* p,size_t n){const size_t count=written<n?written:n;bytes.insert(bytes.end(),p,p+count);return count;}
  ControlPayload last(FrameHeader& h){ControlPayload p{};check(bytes.size()>=32,"wire has frame");check(decodeControl(bytes.data()+bytes.size()-32,32,h,p)==DecodeResult::Ok,"valid output CRC");return p;}
};
static ControlPayload valid(uint16_t buttons=0){auto p=neutralControl();p.controlFlags=kControlInputValid;p.buttons=buttons;return p;}
static void feed(core_safety::UartInput& input,uint16_t seq,uint32_t remote,uint32_t local,const ControlPayload& p){uint8_t bytes[32];encodeControl(bytes,seq,remote,p);for(uint8_t b:bytes)input.feed(b,local);}
int main(){
  Wire wire;FrameHeader h{};core_safety::UartOutput output;
  output.service(wire,0);auto p=wire.last(h);
  check(!p.controlFlags && p.buttons==0 && p.leftX==128 && h.sequence==0,"startup invalid neutral");
  auto active=valid(0x13);active.leftY=255;
  output.update(active,1);output.service(wire,10);p=wire.last(h);
  check(p.buttons==0x13 && h.uptimeMs==10 && h.sequence==1,"UART header belongs to receiver");
  output.service(wire,100);check(wire.last(h).controlFlags==1,"fresh at99ms");
  output.service(wire,110);check(wire.last(h).controlFlags==0,"source timeout not extended by UART resends");
  output.update(active,111);output.service(wire,120);check(wire.last(h).buttons==active.buttons,"output resumes independently of source sequence");
  auto bad=active;bad.controlFlags=0;output.update(bad,121);output.update(active,122);
  output.service(wire,130);p=wire.last(h);
  check(p.buttons==0 && p.leftY==128 && !p.controlFlags,"invalid/nonneutral cannot be coalesced away");
  output.service(wire,140);check(wire.last(h).buttons==active.buttons,"valid latest snapshot after neutral");
  wire.space=31;const auto count=wire.bytes.size();output.service(wire,150);
  check(wire.bytes.size()==count && output.backpressure==1,"backpressure never writes/blocks");
  wire.space=128;output.service(wire,160);check(wire.last(h).controlFlags==0,"backpressure forces neutral before resume");
  wire.written=7;output.service(wire,170);check(output.shortWrites==1,"short write recorded");
  wire.written=32;output.service(wire,180);check(wire.last(h).controlFlags==0,"partial tail never resumed as stale active");
  const auto sent=output.sent;output.service(wire,1000);output.service(wire,1000);
  check(output.sent==sent+1 && output.skips>0,"late scheduler sends only one frame");
  core_safety::UartOutput wrapped;Wire wrapWire;
  for(uint32_t i=0;i<=65536;++i){wrapped.service(wrapWire,i*10);wrapWire.bytes.erase(wrapWire.bytes.begin(),wrapWire.bytes.end()-32);}
  wrapWire.last(h);check(h.sequence==0,"UART sequence wraps uint16");

  core_safety::UartInput input;
  check(!input.enabled(0),"boot stopped");
  feed(input,0,0,0,active);check(!input.enabled(0),"held enable on boot cannot arm");
  feed(input,1,10,10,valid());feed(input,2,20,20,valid(0x10));
  check(input.enabled(20),"neutral then fresh enable arms");
  feed(input,3,30,30,active);check(input.effective(30).leftY==255,"armed input applied");
  feed(input,4,40,40,bad);check(!input.enabled(40) && input.effective(40).leftY==128,"invalid flag stops immediately");
  feed(input,5,50,50,active);check(!input.enabled(50),"valid active alone never resumes");
  feed(input,6,60,60,valid());feed(input,7,70,70,valid(0x10));check(input.enabled(70),"rearm after neutral");
  feed(input,7,70,160,valid(0x10));check(!input.enabled(160),"duplicate stops and does not refresh age");
  input.service(170);check(!input.valid(170) && input.timeouts==1,"exact100ms watchdog after duplicate");
  feed(input,0,0,180,valid());feed(input,1,10,190,valid(0x10));check(input.enabled(190),"reboot resync only after timeout and neutral/enable");
  feed(input,2,0,200,active);check(!input.enabled(200) && input.sequenceRejects==2,"uptime reversal disarms without sequence bypass");
  input.service(290);
  feed(input,100,1000,300,valid());feed(input,101,1010,310,valid(0x10));
  input.inhibit(true);check(!input.enabled(310),"external emergency stops");
  feed(input,102,1020,320,valid());input.inhibit(false);
  feed(input,103,1030,330,valid(0x10));check(!input.enabled(330),"neutral during emergency cannot arm on release");
  feed(input,104,1040,340,valid());feed(input,105,1050,350,valid(0x10));
  feed(input,107,1070,370,active);check(!input.enabled(370) && input.gaps==1,"gap disarms rather than silently retaining enable");
  uint8_t bytes[32];encodeControl(bytes,108,1080,valid());bytes[15]^=1;
  for(uint8_t b:bytes)input.feed(b,380);
  check(input.crcErrors==1,"CRC corruption rejected");
  // Recover after a truncated record, magic bytes in noise and an invalid CRC.
  for(unsigned i=0;i<11;++i) input.feed(bytes[i],381);
  for(unsigned i=0;i<100;++i) input.feed(uint8_t(i),382);
  feed(input,109,1090,390,valid());feed(input,110,1100,400,valid(0x10));
  check(input.enabled(400),"stream sliding resynchronizes and needs neutral/enable");
  core_safety::UartInput rollover;
  feed(rollover,65535,0xFFFFFFF0UL,0xFFFFFFF0UL,valid());
  feed(rollover,0,4,4,valid(0x10));check(rollover.enabled(4),"millis uptime and sequence wrap accepted");
  rollover.service(104);check(!rollover.enabled(104),"watchdog wrap boundary");
  check(core_safety::axisPercent(0)==-100 && core_safety::axisPercent(128)==0 && core_safety::axisPercent(255)==100,"Mega exact center/endpoints");
  for(int i=0;i<256;++i) check(core_safety::axisPercent(uint8_t(i))>=-100 && core_safety::axisPercent(uint8_t(i))<=100,"axis range bounded");
  core_safety::RollerSwitch roller;
  check(!roller.update(true,500) && !roller.update(true,549),"press wait does not toggle");
  check(!roller.update(true,550) && !roller.update(false,551) && !roller.update(false,600),"release waits50ms");
  check(roller.update(false,601) && !roller.update(false,602),"exactly one toggle per stable press/release");
  check(!roller.update(true,700) && !roller.update(false,760),"500ms repeat guard");
  roller.update(true,1000);roller.update(true,1050);roller.update(false,1051);roller.cancel(1070);
  check(!roller.update(false,1200),"stop cancels delayed toggle");
  roller.cancel(0xFFFFFC00UL);roller.update(true,0xFFFFFFF0UL);roller.update(true,34);roller.update(false,35);
  check(roller.update(false,85),"roller waits wrap safely");
  std::printf("UART_SAFETY_TEST_PASS checks=%u\n",checks);
}
