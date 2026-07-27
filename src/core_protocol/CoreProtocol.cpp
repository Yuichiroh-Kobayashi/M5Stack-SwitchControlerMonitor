#include "CoreProtocol.h"

#include <string.h>

namespace core_protocol {
namespace {

void encodeHeader(uint8_t* frame, uint8_t type, uint16_t sequence,
                  uint32_t uptimeMs) {
  memset(frame, 0, kFrameSize);
  frame[0] = kMagic0;
  frame[1] = kMagic1;
  frame[2] = kVersion;
  frame[3] = type;
  writeU16(frame + 4, sequence);
  writeU32(frame + 6, uptimeMs);
}

void finishFrame(uint8_t* frame) {
  writeU16(frame + kCrcOffset, crc16CcittFalse(frame, kCrcOffset));
}

DecodeResult validate(const uint8_t* frame, size_t length, uint8_t type,
                      FrameHeader& header) {
  if (length != kFrameSize) return DecodeResult::BadLength;
  if (frame[0] != kMagic0 || frame[1] != kMagic1)
    return DecodeResult::BadMagic;
  if (frame[2] != kVersion) return DecodeResult::BadVersion;
  if (frame[3] != type) return DecodeResult::BadType;
  if (readU16(frame + kCrcOffset) != crc16CcittFalse(frame, kCrcOffset))
    return DecodeResult::BadCrc;
  header.messageType = frame[3];
  header.sequence = readU16(frame + 4);
  header.uptimeMs = readU32(frame + 6);
  return DecodeResult::Ok;
}

}  // namespace

uint16_t crc16CcittFalse(const uint8_t* data, size_t length) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < length; ++i) {
    crc ^= static_cast<uint16_t>(data[i]) << 8;
    for (uint8_t bit = 0; bit < 8; ++bit)
      crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021)
                           : static_cast<uint16_t>(crc << 1);
  }
  return crc;
}

uint16_t readU16(const uint8_t* data) {
  return static_cast<uint16_t>((static_cast<uint16_t>(data[0]) << 8) |
                               data[1]);
}

uint32_t readU32(const uint8_t* data) {
  return (static_cast<uint32_t>(data[0]) << 24) |
         (static_cast<uint32_t>(data[1]) << 16) |
         (static_cast<uint32_t>(data[2]) << 8) | data[3];
}

void writeU16(uint8_t* data, uint16_t value) {
  data[0] = static_cast<uint8_t>(value >> 8);
  data[1] = static_cast<uint8_t>(value);
}

void writeU32(uint8_t* data, uint32_t value) {
  data[0] = static_cast<uint8_t>(value >> 24);
  data[1] = static_cast<uint8_t>(value >> 16);
  data[2] = static_cast<uint8_t>(value >> 8);
  data[3] = static_cast<uint8_t>(value);
}

ControlPayload neutralControl() {
  ControlPayload p{};
  p.dpad = 8;
  p.leftX = p.leftY = p.rightX = p.rightY = 128;
  p.senderBatteryPercent = 255;
  return p;
}

void encodeControl(uint8_t* frame, uint16_t sequence, uint32_t uptimeMs,
                   const ControlPayload& p) {
  encodeHeader(frame, kControlType, sequence, uptimeMs);
  writeU16(frame + 10, p.controlFlags);
  writeU16(frame + 12, p.buttons);
  frame[14] = p.dpad;
  frame[15] = p.leftX;
  frame[16] = p.leftY;
  frame[17] = p.rightX;
  frame[18] = p.rightY;
  frame[19] = p.leftTrigger;
  frame[20] = p.rightTrigger;
  frame[21] = p.senderBatteryPercent;
  finishFrame(frame);
}

void encodeStatus(uint8_t* frame, uint16_t sequence, uint32_t uptimeMs,
                  const StatusPayload& p) {
  encodeHeader(frame, kStatusType, sequence, uptimeMs);
  writeU16(frame + 10, p.statusFlags);
  writeU16(frame + 12, p.lastControlSequence);
  writeU16(frame + 14, p.controlAgeMs);
  writeU16(frame + 16, p.sequenceGapCount);
  writeU16(frame + 18, p.invalidFrameCount);
  frame[20] = p.receiverBatteryPercent;
  frame[21] = p.uartState;
  writeU16(frame + 22, p.errorCode);
  finishFrame(frame);
}

DecodeResult decodeControl(const uint8_t* frame, size_t length,
                           FrameHeader& h, ControlPayload& p) {
  const DecodeResult result = validate(frame, length, kControlType, h);
  if (result != DecodeResult::Ok) return result;
  p.controlFlags = readU16(frame + 10);
  p.buttons = readU16(frame + 12);
  p.dpad = frame[14];
  p.leftX = frame[15];
  p.leftY = frame[16];
  p.rightX = frame[17];
  p.rightY = frame[18];
  p.leftTrigger = frame[19];
  p.rightTrigger = frame[20];
  p.senderBatteryPercent = frame[21];
  if (p.dpad > 8) return DecodeResult::BadDpad;
  if (p.senderBatteryPercent > 100 && p.senderBatteryPercent != 255)
    return DecodeResult::BadBattery;
  return DecodeResult::Ok;
}

DecodeResult decodeStatus(const uint8_t* frame, size_t length,
                          FrameHeader& h, StatusPayload& p) {
  const DecodeResult result = validate(frame, length, kStatusType, h);
  if (result != DecodeResult::Ok) return result;
  p.statusFlags = readU16(frame + 10);
  p.lastControlSequence = readU16(frame + 12);
  p.controlAgeMs = readU16(frame + 14);
  p.sequenceGapCount = readU16(frame + 16);
  p.invalidFrameCount = readU16(frame + 18);
  p.receiverBatteryPercent = frame[20];
  p.uartState = frame[21];
  p.errorCode = readU16(frame + 22);
  if (p.receiverBatteryPercent > 100 && p.receiverBatteryPercent != 255)
    return DecodeResult::BadBattery;
  return DecodeResult::Ok;
}

SequenceRelation classifySequence(bool havePrevious, uint16_t previous,
                                  uint16_t current, uint16_t& missingCount) {
  missingCount = 0;
  if (!havePrevious) return SequenceRelation::First;
  const uint16_t delta = static_cast<uint16_t>(current - previous);
  if (delta == 0) return SequenceRelation::Duplicate;
  if (delta == 1) return SequenceRelation::InOrder;
  if (delta < 0x8000) {
    missingCount = static_cast<uint16_t>(delta - 1);
    return SequenceRelation::ForwardGap;
  }
  return SequenceRelation::StaleOrReverse;
}

bool selfTest() {
  uint8_t frame[kFrameSize];
  FrameHeader h{};
  ControlPayload control = neutralControl();
  encodeControl(frame, 0x1234, 0x01020304, control);
  ControlPayload decoded{};
  if (decodeControl(frame, sizeof(frame), h, decoded) != DecodeResult::Ok ||
      h.sequence != 0x1234 || h.uptimeMs != 0x01020304 ||
      decoded.dpad != 8 || decoded.leftX != 128 || frame[22] != 0 ||
      frame[29] != 0)
    return false;
  StatusPayload status{};
  status.statusFlags = kStatusReceiverReady | kStatusControlTimeout;
  status.receiverBatteryPercent = 255;
  status.uartState = 1;
  encodeStatus(frame, 0xABCD, 0x10203040, status);
  StatusPayload decodedStatus{};
  if (decodeStatus(frame, sizeof(frame), h, decodedStatus) != DecodeResult::Ok ||
      h.sequence != 0xABCD || decodedStatus.uartState != 1)
    return false;
  frame[0] ^= 1;
  return decodeStatus(frame, sizeof(frame), h, decodedStatus) ==
         DecodeResult::BadMagic;
}

}  // namespace core_protocol
