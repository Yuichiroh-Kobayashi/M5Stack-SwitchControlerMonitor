#include "src/numeric_ui/NumericDisplay.h"
#include <cstdio>
#include <cstdlib>
static unsigned checks=0;
static void check(bool pass,const char* reason){++checks;if(!pass){std::fprintf(stderr,"FAIL %s\n",reason);std::exit(1);}}
int main(){
  numeric_ui::NumericDisplay display;
  check(display.begin("test"),"allocate small sprite with fixed font");
  display.text(0,"OLD");
  fake::nowUs=9000;
  check(!display.service(10) && display.deferred==1 && fake::pushes.empty(),"near deadline never pushes pixels");
  display.text(0,"NEW");
  fake::nowUs=10000; fake::transferUs=700;
  check(display.service(20) && fake::pushes.size()==1,"one field per call");
  check(fake::pushes.back().text=="NEW","deferred old display value discarded");
  check(fake::pushes.back().w==48 && fake::pushes.back().h==8,"pixel transfer rectangle bound");
  check(display.maxUnitUs==700 && display.drawn==1,"synthetic long call duration recorded without masking");
  check(!display.service(20) && fake::pushes.size()==1,"minimum field spacing");
  fake::transferUs=0;
  for(unsigned i=0;i<23;++i){
    fake::nowUs+=2000;
    check(display.service(millis()+5),"remaining fields progress");
  }
  check(fake::pushes.size()==24,"exactly 24 fields for initial screen");
  for(const auto& push:fake::pushes){
    check(push.x>=0 && push.y>=0 && push.x+push.w<=320 && push.y+push.h<=240,"field fits panel");
    check(push.text.size()<=8,"field text bound");
  }
  fake::nowUs+=2000;
  check(!display.service(millis()+5),"no unchanged screen push");
  check(display.maxDirtyAgeMs==0 && display.maxSnapshotAgeMs==0,"startup paint excluded from update latency");
  fake::nowUs=100000;display.text(0,"WAIT");
  fake::nowUs=140000;display.text(0,"LATEST");
  fake::nowUs=150000;
  check(display.pendingAgeMs()==50,"oldest pending update exposed before drawing");
  fake::transferUs=2000;
  check(display.service(160),"delayed update drawn");
  check(display.maxDirtyAgeMs==52 && display.maxSnapshotAgeMs==12,"latency includes draw completion and distinguishes coalescing");
  check(display.pendingAgeMs()==0,"no pending updates after draw");
  fake::allocate=false;
  numeric_ui::NumericDisplay failedAllocation;
  check(!failedAllocation.begin("fail") && !failedAllocation.service(millis()+5),"allocation failure disables drawing");
  fake::allocate=true;fake::fontHeight=16;
  numeric_ui::NumericDisplay failedFont;
  check(!failedFont.begin("fail") && !failedFont.service(millis()+5),"wrong font metrics disable drawing");
  std::printf("NUMERIC_DISPLAY_TEST_PASS checks=%u\n",checks);
}
