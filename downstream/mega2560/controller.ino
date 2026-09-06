/** CR v1 binary receiver. No String, read-until, delay or partial-frame wait. */
bool RxController(void) {
  controller.inhibit(AF_Signal1!=0 || EMG_Stop!=0);
  controller.service(millis());
  // At most two frames' bytes per call; return to the main safety checks.
  for(uint8_t count=0;count<64 && Serial1.available();++count) {
    const int value=Serial1.read();
    if(value>=0) controller.feed(static_cast<uint8_t>(value),millis());
  }
  const uint32_t now=millis();
  controller.service(now);
  ControllerRxTime=controller.lastFrameMs();
  ControllerTimeout=!controller.valid(now);
  const bool enabled=controller.enabled(now);
  const auto p=controller.effective(now);
  for(uint8_t i=0;i<10;++i) RxData[i]=0;
  RxData[0]=p.rightX; // Existing Pitch() expects 0..255 (neutral128).
  RxData[2]=core_safety::axisPercent(p.rightY);
  RxData[3]=core_safety::axisPercent(p.leftY);
  RxData[4]=enabled ? ((p.buttons&0x0002 ? 2 : 0) | (p.buttons&0x0001 ? 4 : 0)) : 1;
  return ControllerTimeout;
}
