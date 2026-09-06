#include <stdlib.h>
#include <iostream>
#include "src/controller_profile/UsbIntake.h"
using namespace controller_profile;
static unsigned checks=0;
static void check(bool value){++checks;if(!value){std::cerr<<"intake check "<<checks<<" failed\n";exit(1);}}
static USB device(unsigned length=32){
  USB usb;
  usb.config={9,2,27,0,1,1,0,0x80,50,9,4,0,0,1,3,0,0,0,9,0x21,0x11,1,0,1,0x22,uint8_t(length),uint8_t(length>>8)};
  usb.report.resize(length,0);Serial.text.clear();return usb;
}
static bool contains(const char* text){return Serial.text.find(text)!=std::string::npos;}
int main(){
  uint8_t bytes[512]{};uint16_t offset=0;
  {IntakeBytes capture;capture.Parse(512,bytes,offset);check(capture.length==512 && capture.complete);
   offset=512;capture.Parse(1,bytes,offset);check(!capture.complete && capture.length==512);}
  {IntakeBytes capture;offset=1;capture.Parse(1,bytes,offset);check(!capture.complete && capture.length==0);}
  {IntakeBytes capture;offset=0;capture.Parse(1,nullptr,offset);check(!capture.complete && capture.length==0);}
  for(unsigned length:{1u,32u,64u,128u,129u,512u}){
    auto usb=device(length);UsbIntake intake;intake.readDescriptorsOnce(usb,1);
    check(usb.configCalls==1 && usb.reportCalls==1 && usb.requestValid);
    check(contains("USB_INTAKE_DESCRIPTOR_COMPLETE=1"));
    intake.readDescriptorsOnce(usb,1);check(usb.configCalls==1 && usb.reportCalls==1);
  }
  for(unsigned length:{0u,513u}){
    auto usb=device(length);UsbIntake intake;intake.readDescriptorsOnce(usb,1);
    check(usb.reportCalls==0 && !contains("USB_INTAKE_DESCRIPTOR_COMPLETE=1"));
  }
  for(unsigned cut=0;cut<27;++cut){
    auto usb=device();usb.config.resize(cut);UsbIntake intake;intake.readDescriptorsOnce(usb,1);
    check(usb.reportCalls==0);
  }
  for(unsigned field:{0u,9u,18u}){
    auto usb=device();usb.config[field]=0;UsbIntake intake;intake.readDescriptorsOnce(usb,1);
    check(usb.reportCalls==0);
  }
  {auto usb=device();usb.config[23]=2;UsbIntake intake;intake.readDescriptorsOnce(usb,1);check(usb.reportCalls==0);}
  {auto usb=device();usb.config[12]=1;UsbIntake intake;intake.readDescriptorsOnce(usb,1);check(usb.reportCalls==0);}
  {auto usb=device();usb.config[14]=0xff;UsbIntake intake;intake.readDescriptorsOnce(usb,1);check(usb.reportCalls==0);}
  {auto usb=device();usb.configResult=1;UsbIntake intake;intake.readDescriptorsOnce(usb,1);
   check(usb.reportCalls==0);intake.readDescriptorsOnce(usb,1);check(usb.configCalls==1);}
  {auto usb=device();usb.reportResult=1;UsbIntake intake;intake.readDescriptorsOnce(usb,1);
   check(contains("USB_INTAKE_DESCRIPTOR_COMPLETE=0"));intake.readDescriptorsOnce(usb,1);check(usb.reportCalls==1);}
  {auto usb=device();usb.report.resize(31);UsbIntake intake;intake.readDescriptorsOnce(usb,1);
   check(contains("USB_INTAKE_DESCRIPTOR_COMPLETE=0"));}
  {UsbIntake intake;ControllerState value;const uint8_t raw[]={0,0,15,128,128,128,128,0};
   Serial.text.clear();intake.observe(false,8,raw,true,value);intake.log(1000,value,true);
   check(contains("SEEN=1 ACCEPTED=1 NON_NEUTRAL=0 LEN=8 ID_FLAG=0 COPIED=8 RAW=00000F8080808000"));
   check(contains("BUTTONS=0000 DP=8 LX=128 LY=128 RX=128 RY=128 LT=0 RT=0"));
   value.btnA=true;value.lX=255;value.rY=0;value.dpad=7;
   intake.observe(false,8,raw,true,value);Serial.text.clear();intake.log(2000,value,true);
   check(contains("NON_NEUTRAL=1"));check(contains("BUTTONS_OR=0001 HATS=0180 AXIS_MIN=128,128,128,0 AXIS_MAX=255,128,128,128"));
   intake.observe(true,255,nullptr,false,value);Serial.text.clear();intake.log(3000,ControllerState{},false);
   check(contains("SEEN=3 ACCEPTED=2 NON_NEUTRAL=1 LEN=255 ID_FLAG=1 COPIED=0 RAW= VALID=0"));
   check(contains("BUTTONS=0000 DP=8 LX=128 LY=128 RX=128 RY=128 LT=0 RT=0"));}
  std::cout<<"USB_INTAKE_TEST_PASS CHECKS="<<checks<<"\n";
}
