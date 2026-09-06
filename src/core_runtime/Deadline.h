#pragma once
#include <stdint.h>

namespace core_runtime {
#ifndef PRODUCT_TRANSPORT_PERIOD_MS
#define PRODUCT_TRANSPORT_PERIOD_MS 10
#endif
static_assert(PRODUCT_TRANSPORT_PERIOD_MS==10 || PRODUCT_TRANSPORT_PERIOD_MS==20,
              "Only 10ms target and 20ms comparison baseline are defined");
constexpr uint32_t kTransportPeriodMs=PRODUCT_TRANSPORT_PERIOD_MS;
constexpr uint32_t kDisplayPeriodMs=40;

struct Due {
  bool ready=false;
  uint32_t skipped=0, lateness=0;
};

// Calls must be within half the uint32_t time range. Advance once in O(1),
// preserving phase while skipping obsolete work instead of replaying a burst.
inline Due takeDeadline(uint32_t now, uint32_t& next, uint32_t period) {
  Due result;
  if (period==0 || static_cast<int32_t>(now-next)<0) return result;
  result.ready=true;
  result.lateness=now-next;
  result.skipped=result.lateness/period;
  next+=(result.skipped+1)*period;
  return result;
}

inline bool displaySlot(uint32_t nowMs, uint32_t communicationDeadlineMs) {
  // Leave at least two whole milliseconds before the next nominal send.
  return static_cast<int32_t>(communicationDeadlineMs-nowMs)>1;
}
}  // namespace core_runtime
