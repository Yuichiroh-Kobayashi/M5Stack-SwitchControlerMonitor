#pragma once

#include <stddef.h>
#include <stdint.h>

namespace controller_profile {

constexpr uint32_t kInputTimeoutMs=100;

enum class Profile : uint8_t { Unsupported, HoriPadTurboSwitch2 };

inline Profile select(uint16_t vid, uint16_t pid) {
  return vid == 0x0F0D && pid == 0x0202 ? Profile::HoriPadTurboSwitch2
                                      : Profile::Unsupported;
}

inline const char* name(Profile profile) {
  return profile == Profile::HoriPadTurboSwitch2 ? "HORI_SWITCH2" : "UNSUPPORTED";
}

struct ControllerState {
  bool btnA=false, btnB=false, btnX=false, btnY=false;
  bool btnL=false, btnR=false, btnZL=false, btnZR=false;
  bool btnMinus=false, btnPlus=false, btnHome=false, btnCapture=false;
  bool btnLStick=false, btnRStick=false;
  uint8_t dpad=8, lX=128, lY=128, rX=128, rY=128;
  uint8_t lTrigger=0, rTrigger=0;
};

inline bool decode(Profile profile, bool hasReportId, const uint8_t* report,
                   size_t length, ControllerState& output) {
  // Fail closed before examining any input, including a null/short report.
  output = ControllerState{};
  if (profile != Profile::HoriPadTurboSwitch2 || hasReportId ||
      report == nullptr || length != 8) return false;
  const uint8_t hat = report[2] & 0x0F;
  // Captured HORI neutral is 0x0F, not the protocol's normalized value 8.
  if (hat > 7 && hat != 0x0F) return false;
  output.btnY=report[0]&0x01; output.btnB=report[0]&0x02;
  output.btnA=report[0]&0x04; output.btnX=report[0]&0x08;
  output.btnL=report[0]&0x10; output.btnR=report[0]&0x20;
  output.btnZL=report[0]&0x40; output.btnZR=report[0]&0x80;
  output.btnMinus=report[1]&0x01; output.btnPlus=report[1]&0x02;
  output.btnLStick=report[1]&0x04; output.btnRStick=report[1]&0x08;
  output.btnHome=report[1]&0x10; output.btnCapture=report[1]&0x20;
  output.dpad=hat == 0x0F ? 8 : hat;
  output.lX=report[3]; output.lY=report[4];
  output.rX=report[5]; output.rY=report[6];
  output.lTrigger=output.btnZL ? 255 : 0;
  output.rTrigger=output.btnZR ? 255 : 0;
  return true;
}

inline uint16_t buttons(const ControllerState& controller) {
  uint16_t value=0;
  if(controller.btnA)value|=1;
  if(controller.btnB)value|=2;
  if(controller.btnX)value|=4;
  if(controller.btnY)value|=8;
  if(controller.btnL)value|=0x10;
  if(controller.btnR)value|=0x20;
  if(controller.btnZL)value|=0x40;
  if(controller.btnZR)value|=0x80;
  if(controller.btnMinus)value|=0x100;
  if(controller.btnPlus)value|=0x200;
  if(controller.btnHome)value|=0x400;
  if(controller.btnCapture)value|=0x800;
  if(controller.btnLStick)value|=0x1000;
  if(controller.btnRStick)value|=0x2000;
  return value;
}

class Input {
 public:
  void observe(bool ready, uint16_t vid, uint16_t pid) {
    if (!ready) vid=pid=0;
    if (ready != ready_ || vid != vid_ || pid != pid_) invalidate();
    ready_=ready; vid_=vid; pid_=pid;
  }
  void invalidate() { value_=ControllerState{}; haveReport_=false; lastReportMs_=0; }
  bool accept(bool hasReportId, const uint8_t* report, size_t length, uint32_t now) {
    if (!ready_ || !decode(profile(), hasReportId, report, length, value_)) {
      invalidate();
      return false;
    }
    haveReport_=true; lastReportMs_=now;
    return true;
  }
  Profile profile() const { return select(vid_,pid_); }
  bool connected() const { return ready_ && profile()!=Profile::Unsupported; }
  bool valid(uint32_t now) const {
    return connected() && haveReport_ && uint32_t(now-lastReportMs_)<kInputTimeoutMs;
  }
  ControllerState effective(uint32_t now) const {
    return valid(now) ? value_ : ControllerState{};
  }
  const ControllerState& value() const { return value_; }
  bool haveReport() const { return haveReport_; }
  uint32_t lastReportMs() const { return lastReportMs_; }
 private:
  bool ready_=false, haveReport_=false;
  uint16_t vid_=0, pid_=0;
  uint32_t lastReportMs_=0;
  ControllerState value_{};
};

}  // namespace controller_profile
