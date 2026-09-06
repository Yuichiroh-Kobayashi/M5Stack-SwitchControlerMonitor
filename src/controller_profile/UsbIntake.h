#pragma once

// Opt-in USB-only intake. Standard GET_DESCRIPTOR reads and serial evidence;
// never sends HID output reports and never retries/resets a failed device.
#include <usbhid.h>
#include "ControllerProfile.h"

namespace controller_profile {
class IntakeBytes : public USBReadParser {
 public:
  uint8_t bytes[512]{};
  uint16_t length=0;
  bool complete=true;
  void Parse(const uint16_t size,const uint8_t* data,const uint16_t& offset) override {
    if(!data || offset!=length || size>sizeof(bytes)-length){complete=false;return;}
    for(uint16_t i=0;i<size;++i) bytes[length++]=data[i];
  }
  void print(const char* kind,uint8_t result) const {
    Serial.printf("USB_INTAKE_DESCRIPTOR TYPE=%s RESULT=%02X LENGTH=%u CONTIGUOUS=%u HEX=",
      kind,result,length,complete);
    for(uint16_t i=0;i<length;++i) Serial.printf("%02X",bytes[i]);
    Serial.println();
  }
};

class UsbIntake {
 public:
  void observe(bool reportId,uint8_t length,const uint8_t* bytes,bool accepted,
               const ControllerState& value) {
    lastLength_=length; lastId_=reportId; lastCopied_=bytes ? (length<8?length:8) : 0;
    for(uint8_t i=0;i<8;++i) last_[i]=i<lastCopied_?bytes[i]:0;
    ++seen_;
    if(!accepted) return;
    ++accepted_;
    allButtons_|=buttons(value);
    const uint8_t axes[]={value.lX,value.lY,value.rX,value.rY};
    for(uint8_t i=0;i<4;++i){
      if(axes[i]<minimum_[i]) minimum_[i]=axes[i];
      if(axes[i]>maximum_[i]) maximum_[i]=axes[i];
    }
    hats_|=uint16_t(1)<<value.dpad;
    if(buttons(value) || value.dpad!=8 || value.lTrigger || value.rTrigger ||
       value.lX!=128 || value.lY!=128 || value.rX!=128 || value.rY!=128) ++nonNeutral_;
  }

  void log(uint32_t now,const ControllerState& effective,bool valid) const {
    Serial.printf("USB_INTAKE_INPUT UPTIME=%lu SEEN=%lu ACCEPTED=%lu NON_NEUTRAL=%lu LEN=%u ID_FLAG=%u COPIED=%u RAW=",
      (unsigned long)now,(unsigned long)seen_,(unsigned long)accepted_,
      (unsigned long)nonNeutral_,lastLength_,lastId_,lastCopied_);
    for(uint8_t i=0;i<lastCopied_;++i) Serial.printf("%02X",last_[i]);
    Serial.printf(" VALID=%u BUTTONS=%04X DP=%u LX=%u LY=%u RX=%u RY=%u LT=%u RT=%u BUTTONS_OR=%04X HATS=%04X AXIS_MIN=%u,%u,%u,%u AXIS_MAX=%u,%u,%u,%u\n",
      valid,buttons(effective),effective.dpad,effective.lX,effective.lY,effective.rX,effective.rY,
      effective.lTrigger,effective.rTrigger,allButtons_,hats_,minimum_[0],minimum_[1],minimum_[2],minimum_[3],
      maximum_[0],maximum_[1],maximum_[2],maximum_[3]);
  }

  void readDescriptorsOnce(USB& usb,uint8_t address) {
    if(attempted_) return;
    attempted_=true;
    IntakeBytes config;
    const uint8_t configResult=usb.getConfDescr(address,0,uint8_t(0),&config);
    config.print("CONFIGURATION",configResult);
    if(configResult || !config.complete || config.length<9 || config.bytes[1]!=2 ||
       uint16_t(config.bytes[2]|uint16_t(config.bytes[3])<<8)!=config.length) return;
    int16_t interfaceNumber=-1;
    uint16_t reportLength=0;
    uint8_t reportInterface=0,reportDescriptors=0;
    for(uint16_t offset=0;offset<config.length;){
      const uint8_t size=config.bytes[offset];
      if(size<2 || offset+size>config.length) return;
      const uint8_t* item=config.bytes+offset;
      if(item[1]==4){
        interfaceNumber=(size>=9 && item[5]==3 && item[3]==0)?item[2]:-1;
      } else if(item[1]==0x21 && interfaceNumber>=0 && size>=6){
        if(6+3*item[5]>size) return;
        for(uint8_t index=0;index<item[5];++index){
          const uint8_t* entry=item+6+3*index;
          if(entry[0]==0x22){
            ++reportDescriptors;reportInterface=uint8_t(interfaceNumber);
            reportLength=uint16_t(entry[1])|uint16_t(entry[2])<<8;
          }
        }
      }
      offset+=size;
    }
    Serial.printf("USB_INTAKE_HID REPORT_DESCRIPTORS=%u INTERFACE=%u ADVERTISED_LENGTH=%u\n",
      reportDescriptors,reportInterface,reportLength);
    if(reportDescriptors!=1 || !reportLength || reportLength>512) return;
    IntakeBytes report;
    uint8_t buffer[64]{};
    const uint8_t result=usb.ctrlReq(address,0,bmREQ_HID_REPORT,USB_REQUEST_GET_DESCRIPTOR,
      0,HID_DESCRIPTOR_REPORT,reportInterface,reportLength,
      reportLength<sizeof(buffer)?reportLength:sizeof(buffer),buffer,&report);
    report.print("REPORT",result);
    Serial.printf("USB_INTAKE_DESCRIPTOR_COMPLETE=%u\n",
      result==0 && report.complete && report.length==reportLength);
  }
 private:
  bool attempted_=false,lastId_=false;
  uint8_t lastLength_=0,lastCopied_=0,last_[8]{},minimum_[4]{255,255,255,255},maximum_[4]{};
  uint16_t allButtons_=0,hats_=0;
  uint32_t seen_=0,accepted_=0,nonNeutral_=0;
};
}  // namespace controller_profile
