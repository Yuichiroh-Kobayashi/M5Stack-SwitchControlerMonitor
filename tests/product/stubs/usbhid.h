#pragma once
// Standard-request API double for the opt-in intake; no USB timing model.
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string>
#include <vector>
struct IntakeSerial {
  std::string text;
  void printf(const char* format,...) {
    char buffer[1024]; va_list args; va_start(args,format);
    vsnprintf(buffer,sizeof(buffer),format,args); va_end(args); text+=buffer;
  }
  void println(){text+='\n';}
};
static IntakeSerial Serial;
constexpr uint8_t bmREQ_HID_REPORT=0x81,USB_REQUEST_GET_DESCRIPTOR=6,HID_DESCRIPTOR_REPORT=0x22;
class USBReadParser {
 public:
  virtual void Parse(const uint16_t,const uint8_t*,const uint16_t&)=0;
};
class USB {
 public:
  std::vector<uint8_t> config,report;
  uint8_t configResult=0,reportResult=0;
  unsigned configCalls=0,reportCalls=0;
  bool requestValid=false;
  static void feed(USBReadParser* parser,const std::vector<uint8_t>& data){
    for(uint16_t offset=0;offset<data.size();){
      const uint16_t size=data.size()-offset<64?uint16_t(data.size()-offset):64;
      parser->Parse(size,data.data()+offset,offset); offset+=size;
    }
  }
  uint8_t getConfDescr(uint8_t,uint8_t,uint8_t,USBReadParser* parser){
    ++configCalls;feed(parser,config);return configResult;
  }
  uint8_t ctrlReq(uint8_t address,uint8_t ep,uint8_t requestType,uint8_t request,
      uint8_t valueLow,uint8_t valueHigh,uint16_t index,uint16_t total,
      uint16_t chunk,uint8_t*,USBReadParser* parser){
    ++reportCalls;
    requestValid=address==1 && ep==0 && requestType==0x81 && request==6 &&
      valueLow==0 && valueHigh==0x22 && index==0 && total==report.size() &&
      chunk==(total<64?total:64);
    feed(parser,report);return reportResult;
  }
};
