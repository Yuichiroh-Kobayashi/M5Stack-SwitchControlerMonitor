#pragma once
#include "../core_protocol/CoreProtocol.h"
#include "../core_runtime/Deadline.h"

namespace core_safety {
// One writer, no blocking flush, no replay of missed deadlines. The transport
// must report the space it can accept immediately (ESP32 uses its TX FIFO).
class UartOutput {
 public:
  void update(const core_protocol::ControlPayload& payload, uint32_t now) {
    expire(now);
    payload_=payload;
    haveSource_=true; sourceMs_=now;
    if(!(payload.controlFlags&core_protocol::kControlInputValid)) forceNeutral_=true;
  }
  void expire(uint32_t now) {
    if(haveSource_ && uint32_t(now-sourceMs_)>=100) {
      haveSource_=false; forceNeutral_=true; ++sourceTimeouts;
    }
  }
  void invalidate() { haveSource_=false; forceNeutral_=true; }
  bool sourceValid(uint32_t now) const {
    return haveSource_ && uint32_t(now-sourceMs_)<100 &&
      (payload_.controlFlags&core_protocol::kControlInputValid);
  }
  template<typename Serial> void service(Serial& serial,uint32_t now) {
    expire(now);
    const auto due=core_runtime::takeDeadline(now,nextMs,10);
    if(!due.ready) return;
    skips+=due.skipped;
    if(due.lateness>maxLateMs) maxLateMs=due.lateness;
    if(serial.availableForWrite()<int(core_protocol::kFrameSize)) {
      ++backpressure; forceNeutral_=true; return;
    }
    const bool active=!forceNeutral_ && sourceValid(now);
    const auto payload=active ? payload_ : core_protocol::neutralControl();
    uint8_t frame[core_protocol::kFrameSize];
    core_protocol::encodeControl(frame,sequence_++,now,payload);
    const size_t count=serial.write(frame,sizeof(frame));
    if(count!=sizeof(frame)) { ++shortWrites; forceNeutral_=true; return; }
    ++sent;
    if(!active) { ++neutralSent; forceNeutral_=false; }
  }
  uint32_t nextMs=0,sent=0,neutralSent=0,skips=0,maxLateMs=0;
  uint32_t backpressure=0,shortWrites=0,sourceTimeouts=0;
 private:
  core_protocol::ControlPayload payload_=core_protocol::neutralControl();
  uint32_t sourceMs_=0;
  uint16_t sequence_=0;
  bool haveSource_=false,forceNeutral_=true;
};
}
