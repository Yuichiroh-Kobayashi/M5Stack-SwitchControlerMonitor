#include "src/controller_profile/ControllerProfile.h"
#include "src/core_protocol/CoreProtocol.h"
#include <cstdio>
#include <cstdlib>

using namespace controller_profile;
static unsigned checks=0;
static void check(bool pass, const char* reason) {
  ++checks;
  if (!pass) { std::fprintf(stderr,"FAIL %s\n",reason); std::exit(1); }
}
static bool neutral(const ControllerState& s) {
  return !s.btnA && !s.btnB && !s.btnX && !s.btnY && !s.btnL && !s.btnR &&
    !s.btnZL && !s.btnZR && !s.btnMinus && !s.btnPlus && !s.btnHome &&
    !s.btnCapture && !s.btnLStick && !s.btnRStick && s.dpad==8 &&
    s.lX==128 && s.lY==128 && s.rX==128 && s.rY==128 &&
    s.lTrigger==0 && s.rTrigger==0;
}
int main() {
  check(core_protocol::selfTest(),"frozen core protocol golden and rejection vectors");
  check(select(0x0F0D,0x0202)==Profile::HoriPadTurboSwitch2,"HORI identity");
  check(select(0x054C,0x0CE6)==Profile::Unsupported,"DualSense suspended");
  check(select(0x0F0D,0x0201)==Profile::Unsupported,"wrong PID");
  check(select(0x0F0C,0x0202)==Profile::Unsupported,"wrong VID");
  const uint8_t capturedNeutral[]={0,0,0x0F,128,128,128,128,0};
  ControllerState value{};
  check(decode(Profile::HoriPadTurboSwitch2,false,capturedNeutral,8,value) && neutral(value),"captured neutral 0F normalized to 8");
  // Independent legacy button table: byte, mask, named output member.
  struct Button { unsigned byte; uint8_t mask; bool ControllerState::*member; };
  const Button buttons[]={
    {0,1,&ControllerState::btnY},{0,2,&ControllerState::btnB},
    {0,4,&ControllerState::btnA},{0,8,&ControllerState::btnX},
    {0,16,&ControllerState::btnL},{0,32,&ControllerState::btnR},
    {0,64,&ControllerState::btnZL},{0,128,&ControllerState::btnZR},
    {1,1,&ControllerState::btnMinus},{1,2,&ControllerState::btnPlus},
    {1,4,&ControllerState::btnLStick},{1,8,&ControllerState::btnRStick},
    {1,16,&ControllerState::btnHome},{1,32,&ControllerState::btnCapture}};
  const uint16_t expectedWire[]={8,2,1,4,16,32,64,128,256,512,4096,8192,1024,2048};
  unsigned buttonIndex=0;
  for (const auto& button:buttons) {
    uint8_t raw[]={0,0,15,128,128,128,128,0}; raw[button.byte]=button.mask;
    check(decode(Profile::HoriPadTurboSwitch2,false,raw,8,value),"button report accepted");
    for (const auto& other:buttons) check(value.*(other.member)==(other.member==button.member),"one-hot button isolation");
    check(value.lTrigger==(button.member==&ControllerState::btnZL?255:0),"digital left trigger");
    check(value.rTrigger==(button.member==&ControllerState::btnZR?255:0),"digital right trigger");
    check(controller_profile::buttons(value)==expectedWire[buttonIndex++],"wire button mapping");
  }
  for(unsigned hat=0;hat<16;++hat){
    uint8_t raw[]={0,0,static_cast<uint8_t>(hat),0,255,1,254,0};
    const bool accepted=decode(Profile::HoriPadTurboSwitch2,false,raw,8,value);
    check(accepted==(hat<8 || hat==15),"hat domain");
    if(accepted)check(value.dpad==(hat==15?8:hat) && value.lX==0 && value.lY==255 && value.rX==1 && value.rY==254,"hat and distinct axes");
    else check(neutral(value),"invalid hat clears previous axes");
  }
  for(size_t length=0;length<=65;++length){
    uint8_t raw[65]={0,0,15,128,128,128,128,0}; value.btnA=true;
    check(decode(Profile::HoriPadTurboSwitch2,false,raw,length,value)==(length==8),"strict report length");
    if(length!=8)check(neutral(value),"length rejection neutral");
  }
  check(!decode(Profile::HoriPadTurboSwitch2,false,nullptr,8,value) && neutral(value),"null report");
  check(!decode(Profile::HoriPadTurboSwitch2,true,capturedNeutral,8,value) && neutral(value),"report ID rejected");
  check(!decode(Profile::Unsupported,false,capturedNeutral,8,value) && neutral(value),"unsupported decode");
  Input input;
  uint8_t active[]={0xC4,0x10,0,0,255,1,254,0};
  check(!input.accept(false,active,8,1) && neutral(input.effective(1)),"not connected");
  input.observe(true,0x0F0D,0x0202);
  check(!input.valid(10),"connection requires fresh report");
  check(input.accept(false,active,8,10) && input.valid(10),"active report");
  check(input.valid(109) && !input.valid(110) && neutral(input.effective(110)),"100ms exact boundary");
  check(input.lastReportMs()==10,"reading output never refreshes input");
  input.observe(false,0,0);
  check(!input.haveReport() && neutral(input.effective(111)),"detach clears active input");
  input.observe(true,0x0F0D,0x0202);
  check(!input.valid(112),"reconnect cannot resurrect input");
  check(input.accept(false,active,8,113),"fresh reconnect report");
  check(!input.accept(false,active,7,114) && !input.valid(114) && neutral(input.effective(114)),"malformed after valid clears immediately");
  check(input.accept(false,active,8,115),"recover after malformed");
  input.observe(true,0x054C,0x0CE6);
  check(!input.connected() && !input.valid(116) && neutral(input.effective(116)),"identity change without ready edge");
  input.observe(true,0x0F0D,0x0202);
  check(input.accept(false,active,8,0xFFFFFFF0u),"wrap input accepted");
  check(input.valid(0x53u) && !input.valid(0x54u),"unsigned time wrap");
  check(input.accept(false,capturedNeutral,8,1000) && neutral(input.effective(1000)),"release returns neutral");
  std::printf("CONTROLLER_PROFILE_TEST_PASS checks=%u\n",checks);
}
