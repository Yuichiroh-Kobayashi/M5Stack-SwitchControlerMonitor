#pragma once

// Focused PC-peer diagnostic profile. PHY register access is taken from the
// existing isolation diagnostic (read/writeW5500PhyCfgr, applyW5500PhyProfile).
// Not included in ordinary product or USB-only builds. No recovery loop.
#include <utility/w5100.h>
namespace pc_peer_test {
inline uint8_t readPhy() {
  digitalWrite(USB_HOST_SHIELD_SS_GPIO,HIGH);
  SPI.beginTransaction(SPI_ETHERNET_SETTINGS);
  const uint8_t value=W5100.readPHYCFGR_W5500();
  SPI.endTransaction();
  digitalWrite(13,HIGH);
  return value;
}
inline void writePhy(uint8_t value) {
  digitalWrite(USB_HOST_SHIELD_SS_GPIO,HIGH);
  SPI.beginTransaction(SPI_ETHERNET_SETTINGS);
  W5100.writePHYCFGR_W5500(value);
  SPI.endTransaction();
  digitalWrite(13,HIGH);
}
inline bool configured(uint8_t value) { return (value&0xF8)==0xC0; }
inline bool applyFixed10Half() {
  const uint8_t before=readPhy();
  const uint8_t configuredValue=(before&uint8_t(~0x38))|0x40;
  writePhy(configuredValue&uint8_t(~0x80));
  delay(1);
  writePhy(configuredValue|0x80);
  const uint8_t after=readPhy();
  Serial.printf("PC_TEST_PHY_BEFORE=%02X PC_TEST_PHY_AFTER=%02X PC_TEST_PHY_OK=%u\n",
    before,after,configured(after));
  return configured(after);
}
}  // namespace pc_peer_test
