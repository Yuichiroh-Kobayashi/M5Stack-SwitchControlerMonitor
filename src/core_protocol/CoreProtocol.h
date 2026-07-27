#pragma once

#include <stddef.h>
#include <stdint.h>

namespace core_protocol {

constexpr size_t kFrameSize = 32;
constexpr size_t kCrcOffset = 30;
constexpr uint8_t kMagic0 = 'C';
constexpr uint8_t kMagic1 = 'R';
constexpr uint8_t kVersion = 1;
constexpr uint8_t kControlType = 0x01;
constexpr uint8_t kStatusType = 0x02;

constexpr uint16_t kControlInputValid = 1u << 0;
constexpr uint16_t kControlControllerConnected = 1u << 1;
constexpr uint16_t kControlLanLinkOn = 1u << 2;
constexpr uint16_t kControlBatteryValid = 1u << 3;

constexpr uint16_t kStatusReceiverReady = 1u << 0;
constexpr uint16_t kStatusControlValid = 1u << 1;
constexpr uint16_t kStatusControlTimeout = 1u << 2;
constexpr uint16_t kStatusLanLinkOn = 1u << 3;
constexpr uint16_t kStatusUartTxEnabled = 1u << 4;
constexpr uint16_t kStatusProtocolError = 1u << 5;
constexpr uint16_t kStatusSequenceGap = 1u << 6;
constexpr uint16_t kStatusBatteryValid = 1u << 7;

enum class DecodeResult : uint8_t {
  Ok,
  BadLength,
  BadMagic,
  BadVersion,
  BadType,
  BadCrc,
  BadDpad,
  BadBattery,
};

enum class SequenceRelation : uint8_t {
  First,
  InOrder,
  Duplicate,
  ForwardGap,
  StaleOrReverse,
};

struct FrameHeader {
  uint8_t messageType;
  uint16_t sequence;
  uint32_t uptimeMs;
};

struct ControlPayload {
  uint16_t controlFlags;
  uint16_t buttons;
  uint8_t dpad;
  uint8_t leftX;
  uint8_t leftY;
  uint8_t rightX;
  uint8_t rightY;
  uint8_t leftTrigger;
  uint8_t rightTrigger;
  uint8_t senderBatteryPercent;
};

struct StatusPayload {
  uint16_t statusFlags;
  uint16_t lastControlSequence;
  uint16_t controlAgeMs;
  uint16_t sequenceGapCount;
  uint16_t invalidFrameCount;
  uint8_t receiverBatteryPercent;
  uint8_t uartState;
  uint16_t errorCode;
};

uint16_t crc16CcittFalse(const uint8_t* data, size_t length);
uint16_t readU16(const uint8_t* data);
uint32_t readU32(const uint8_t* data);
void writeU16(uint8_t* data, uint16_t value);
void writeU32(uint8_t* data, uint32_t value);

ControlPayload neutralControl();
void encodeControl(uint8_t frame[kFrameSize], uint16_t sequence,
                   uint32_t uptimeMs, const ControlPayload& payload);
void encodeStatus(uint8_t frame[kFrameSize], uint16_t sequence,
                  uint32_t uptimeMs, const StatusPayload& payload);
DecodeResult decodeControl(const uint8_t* frame, size_t length,
                           FrameHeader& header, ControlPayload& payload);
DecodeResult decodeStatus(const uint8_t* frame, size_t length,
                          FrameHeader& header, StatusPayload& payload);
SequenceRelation classifySequence(bool havePrevious, uint16_t previous,
                                  uint16_t current, uint16_t& missingCount);
bool selfTest();

static_assert(kFrameSize == 32, "CoRE frame size must remain 32 bytes");
static_assert(kCrcOffset + 2 == kFrameSize, "CRC must end the frame");

}  // namespace core_protocol
