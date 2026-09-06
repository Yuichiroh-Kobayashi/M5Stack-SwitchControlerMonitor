#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace numeric_ui {
constexpr size_t kFieldCount=24, kCharacters=8;

class DirtyFields {
 public:
  void set(size_t index, const char* text, uint32_t now=0) {
    if (index>=kFieldCount || text==nullptr) return;
    const char* bounded=strlen(text)>kCharacters ? "OVERFLOW" : text;
    const bool changed=strcmp(desired_[index],bounded)!=0;
    const bool wasDirty=dirty_[index];
    memset(desired_[index],0,kCharacters+1);
    memcpy(desired_[index],bounded,strlen(bounded));
    dirty_[index]=!shown_[index] || strcmp(desired_[index],displayed_[index])!=0;
    if(changed) updatedAt_[index]=now;
    if(dirty_[index] && !wasDirty) dirtySince_[index]=now;
  }
  int next() const {
    // CTRL/PEER/LINK changes have priority over numeric/counter changes.
    for (size_t i=0;i<3;++i) if(dirty_[i]) return static_cast<int>(i);
    for (size_t n=0;n<kFieldCount;++n) {
      const size_t i=(cursor_+n)%kFieldCount;
      if(dirty_[i]) return static_cast<int>(i);
    }
    return -1;
  }
  const char* text(size_t index) const { return desired_[index]; }
  uint32_t updatedAt(size_t index) const { return updatedAt_[index]; }
  uint32_t dirtySince(size_t index) const { return dirtySince_[index]; }
  bool hasBeenShown(size_t index) const { return shown_[index]; }
  uint32_t pendingAge(uint32_t now) const {
    uint32_t maximum=0;
    for(size_t i=0;i<kFieldCount;++i)
      if(dirty_[i] && uint32_t(now-dirtySince_[i])>maximum) maximum=now-dirtySince_[i];
    return maximum;
  }
  void drawn(size_t index) {
    if (index>=kFieldCount) return;
    memcpy(displayed_[index],desired_[index],kCharacters+1);
    shown_[index]=true; dirty_[index]=false;
    cursor_=(index+1)%kFieldCount;
  }
 private:
  char desired_[kFieldCount][kCharacters+1]={};
  char displayed_[kFieldCount][kCharacters+1]={};
  bool dirty_[kFieldCount]={}, shown_[kFieldCount]={};
  uint32_t dirtySince_[kFieldCount]={},updatedAt_[kFieldCount]={};
  size_t cursor_=0;
};
}  // namespace numeric_ui
