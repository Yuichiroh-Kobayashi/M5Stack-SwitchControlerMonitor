#pragma once
#include "../core_protocol/CoreProtocol.h"
#include <string.h>

namespace core_safety {
constexpr uint16_t kEnableButton=1u<<4; // HORI L, hold to operate
inline bool centered(const core_protocol::ControlPayload& p) {
  return p.dpad==8 && p.leftX==128 && p.leftY==128 &&
    p.rightX==128 && p.rightY==128 && !p.leftTrigger && !p.rightTrigger;
}
inline int axisPercent(uint8_t value) {
  const int v=int(value)-128;
  return v<0 ? v*100/128 : v*100/127;
}

class UartInput {
 public:
  void inhibit(bool value) {
    inhibited_=value;
    if(value) disarm();
  }
  void disarm() { armed_=false; neutralSeen_=false; }
  void service(uint32_t now) {
    if(haveFrame_ && uint32_t(now-lastFrameMs_)>=100) {
      haveFrame_=false; valid_=false; disarm(); ++timeouts;
    }
    if(length_ && uint32_t(now-lastByteMs_)>=100) length_=0;
  }
  bool valid(uint32_t now) const { return haveFrame_ && valid_ && uint32_t(now-lastFrameMs_)<100; }
  bool enabled(uint32_t now) const { return valid(now) && armed_ && !inhibited_; }
  core_protocol::ControlPayload effective(uint32_t now) const {
    return enabled(now) ? payload_ : core_protocol::neutralControl();
  }
  uint32_t lastFrameMs() const { return lastFrameMs_; }
  bool feed(uint8_t value,uint32_t now) {
    service(now); lastByteMs_=now;
    if(length_==0 && value!=core_protocol::kMagic0) return false;
    if(length_==1 && value!=core_protocol::kMagic1) {
      length_=value==core_protocol::kMagic0 ? 1 : 0; return false;
    }
    buffer_[length_++]=value;
    if(length_<core_protocol::kFrameSize) return false;
    core_protocol::FrameHeader h{};
    core_protocol::ControlPayload p{};
    const auto result=core_protocol::decodeControl(buffer_,sizeof(buffer_),h,p);
    if(result!=core_protocol::DecodeResult::Ok) {
      if(result==core_protocol::DecodeResult::BadCrc) ++crcErrors; else ++invalidFrames;
      valid_=false; disarm();
      // Slide by one and retain an overlapping frame prefix after corruption.
      memmove(buffer_,buffer_+1,--length_);
      while(length_ && buffer_[0]!=core_protocol::kMagic0)
        memmove(buffer_,buffer_+1,--length_);
      return false;
    }
    length_=0;
    uint16_t missing=0;
    const auto relation=core_protocol::classifySequence(haveFrame_,lastSequence_,h.sequence,missing);
    if(relation==core_protocol::SequenceRelation::Duplicate ||
       relation==core_protocol::SequenceRelation::StaleOrReverse ||
       (haveFrame_ && uint32_t(h.uptimeMs-lastUptime_)>=0x80000000UL)) {
      ++sequenceRejects; valid_=false; disarm(); return false;
    }
    if(missing) { gaps+=missing; disarm(); }
    haveFrame_=true; lastFrameMs_=now; lastSequence_=h.sequence; lastUptime_=h.uptimeMs;
    ++accepted;
    valid_=(p.controlFlags&core_protocol::kControlInputValid)!=0;
    payload_=valid_ ? p : core_protocol::neutralControl();
    if(!valid_ || inhibited_) { disarm(); return true; }
    const bool enable=(p.buttons&kEnableButton)!=0;
    if(!enable) {
      armed_=false;
      neutralSeen_=p.buttons==0 && centered(p);
    } else if(!armed_) {
      armed_=neutralSeen_ && p.buttons==kEnableButton && centered(p);
      neutralSeen_=false;
    }
    return true;
  }
  uint32_t accepted=0,crcErrors=0,invalidFrames=0,sequenceRejects=0,gaps=0,timeouts=0;
 private:
  uint8_t buffer_[core_protocol::kFrameSize]={},length_=0;
  core_protocol::ControlPayload payload_=core_protocol::neutralControl();
  uint32_t lastFrameMs_=0,lastByteMs_=0,lastUptime_=0;
  uint16_t lastSequence_=0;
  bool haveFrame_=false,valid_=false,armed_=false,neutralSeen_=false,inhibited_=false;
};
}
