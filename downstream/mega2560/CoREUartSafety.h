#pragma once
#include "src/core_safety/UartInput.h"
#include "src/core_safety/RollerSwitch.h"
core_safety::UartInput controller;
core_safety::RollerSwitch rollerSwitch;

// Keep all pending action state on the same stop path as the drive outputs.
inline void CancelControllerActions(uint32_t now) {
  rollerSwitch.cancel(now);
  RollerSeq=0; RollerOnOff=0; ShotSeq=0; Shotmove=0;
  for(uint8_t i=0;i<RMmotorNUM;++i) {
    motor[i].TxVel=0; motor[i].TxAmp=0; PIDdiff[i]=0;
  }
}
