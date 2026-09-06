#pragma once
#include <M5Unified.h>
#include <stdio.h>
#include "DirtyFields.h"
#include "../core_runtime/Deadline.h"

#ifndef PRODUCT_NUMERIC_UI
#define PRODUCT_NUMERIC_UI 1
#endif
static_assert(PRODUCT_NUMERIC_UI==0 || PRODUCT_NUMERIC_UI==1,"Numeric UI must be 0 or 1");

namespace numeric_ui {
class NumericDisplay {
 public:
  NumericDisplay():tile_(&M5.Display) {}
  bool begin(const char* title) {
    tile_.setColorDepth(16);
    if (!tile_.createSprite(48,8)) return false;
    tile_.setFont(&fonts::Font0);
    tile_.setTextSize(1);
    tile_.setTextWrap(false);
    if(tile_.fontHeight()>8 || tile_.textWidth("88888888")>48) return false;
    M5.Display.setFont(&fonts::Font0);
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(WHITE,BLACK);
    M5.Display.setCursor(0,8);
    M5.Display.print(title);
    const char* labels[kFieldCount]={"CTRL","PEER","LINK","LX","LY","RX","RY","DP",
      "BUTTONS","LT","RT","INPUT/s","TX","RXPKT","AGE ms","BAT %","CRC","GAPS",
      "SKIP","LATE ms","USB us","LCD us","DEFER","REJECT"};
    for(size_t i=0;i<kFieldCount;++i){
      M5.Display.setCursor(x(i),y(i));
      M5.Display.print(labels[i]);
      fields_.set(i,"--");
    }
    ready_=true;
    return true;
  }
  void text(size_t index,const char* value){fields_.set(index,value);}
  void number(size_t index,uint32_t value){
    char buffer[16]; snprintf(buffer,sizeof(buffer),"%lu",static_cast<unsigned long>(value)); fields_.set(index,buffer);
  }
  void hex(size_t index,uint16_t value){
    char buffer[9]; snprintf(buffer,sizeof(buffer),"%04X",static_cast<unsigned>(value)); fields_.set(index,buffer);
  }
  template<typename Pad> void pad(const Pad& p){
    number(3,p.lX); number(4,p.lY); number(5,p.rX); number(6,p.rY); number(7,p.dpad);
    const bool bits[]={p.btnA,p.btnB,p.btnX,p.btnY,p.btnL,p.btnR,p.btnZL,p.btnZR,
      p.btnMinus,p.btnPlus,p.btnHome,p.btnCapture,p.btnLStick,p.btnRStick};
    uint16_t buttons=0;
    for(unsigned bit=0;bit<14;++bit) if(bits[bit]) buttons|=1u<<bit;
    hex(8,buttons); number(9,p.lTrigger); number(10,p.rTrigger);
  }
  bool service(uint32_t nextCommunicationMs){
    if(!ready_ || fields_.next()<0) return false;
    const uint32_t start=micros();
    if(static_cast<int32_t>(start-nextUnitUs_)<0) return false;
    // Never catch up queued draw slots. Check fresh time after all prior work.
    nextUnitUs_=start+1000;
    if(!core_runtime::displaySlot(millis(),nextCommunicationMs)){++deferred;return false;}
    const size_t field=static_cast<size_t>(fields_.next());
    tile_.fillSprite(BLACK);
    tile_.setTextColor(WHITE,BLACK);
    tile_.setCursor(0,0);
    tile_.print(fields_.text(field));
    tile_.pushSprite(x(field)+54,y(field));
    fields_.drawn(field);
    const uint32_t duration=micros()-start;
    if(duration>maxUnitUs) maxUnitUs=duration;
    ++drawn;
    return true;
  }
  uint32_t maxUnitUs=0,deferred=0,drawn=0;
 private:
  static int x(size_t index){return static_cast<int>(index%3)*106;}
  static int y(size_t index){return 34+static_cast<int>(index/3)*24;}
  M5Canvas tile_;
  DirtyFields fields_;
  bool ready_=false;
  uint32_t nextUnitUs_=0;
};
}  // namespace numeric_ui
