#pragma once
#include <stdint.h>
namespace core_safety {
// A stable press and stable release each take 50ms; accepted press starts the
// independent 500ms repeat guard. No delay(), allocation or hardware access.
class RollerSwitch {
 public:
  void cancel(uint32_t now) { phase_=Idle; started_=lastPress_=now; }
  bool update(bool pressed,uint32_t now) {
    switch(phase_) {
      case Idle:
        if(pressed && uint32_t(now-lastPress_)>=500) {
          phase_=PressWait; started_=lastPress_=now;
        }
        break;
      case PressWait:
        if(!pressed) phase_=Idle;
        else if(uint32_t(now-started_)>=50) phase_=ReleaseWait;
        break;
      case ReleaseWait:
        if(!pressed) { phase_=ReleaseSettle; started_=now; }
        break;
      case ReleaseSettle:
        if(pressed) phase_=ReleaseWait;
        else if(uint32_t(now-started_)>=50) { phase_=Idle; return true; }
        break;
    }
    return false;
  }
 private:
  enum Phase:uint8_t {Idle,PressWait,ReleaseWait,ReleaseSettle};
  Phase phase_=Idle;
  uint32_t started_=0,lastPress_=0;
};
}
