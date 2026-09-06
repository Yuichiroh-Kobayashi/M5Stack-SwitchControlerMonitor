#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace numeric_ui {
constexpr size_t kFieldCount=24, kCharacters=8;

class DirtyFields {
 public:
  void set(size_t index, const char* text) {
    if (index>=kFieldCount || text==nullptr) return;
    const char* bounded=strlen(text)>kCharacters ? "OVERFLOW" : text;
    memset(desired_[index],0,kCharacters+1);
    memcpy(desired_[index],bounded,strlen(bounded));
    dirty_[index]=!shown_[index] || strcmp(desired_[index],displayed_[index])!=0;
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
  size_t cursor_=0;
};
}  // namespace numeric_ui
