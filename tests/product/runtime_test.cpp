#include "src/core_runtime/Deadline.h"
#include "src/numeric_ui/DirtyFields.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
static unsigned checks=0;
static void check(bool pass,const char* reason){++checks;if(!pass){std::fprintf(stderr,"FAIL %s\n",reason);std::exit(1);}}
int main(){
  uint32_t next=100;
  check(!core_runtime::takeDeadline(99,next,10).ready && next==100,"not early");
  auto due=core_runtime::takeDeadline(100,next,10);
  check(due.ready && due.skipped==0 && due.lateness==0 && next==110,"exact deadline");
  due=core_runtime::takeDeadline(139,next,10);
  check(due.ready && due.skipped==2 && due.lateness==29 && next==140,"phase preserved and skips counted");
  check(!core_runtime::takeDeadline(139,next,10).ready,"no same-loop catch-up burst");
  due=core_runtime::takeDeadline(140,next,10);
  check(due.ready && due.skipped==0 && next==150,"resume original phase");
  next=0xFFFFFFFAu;
  check(!core_runtime::takeDeadline(0xFFFFFFF9u,next,10).ready,"wrap not early");
  due=core_runtime::takeDeadline(4,next,10);
  check(due.ready && due.skipped==1 && due.lateness==10 && next==14,"wrap skip");
  next=0;
  due=core_runtime::takeDeadline(1000000000u,next,10);
  check(due.skipped==100000000 && next==1000000010u,"long delay constant-time");
  check(!core_runtime::takeDeadline(next,next,0).ready,"zero period rejected");
  check(!core_runtime::displaySlot(100,100) && !core_runtime::displaySlot(101,100),"due/overdue communication wins");
  check(!core_runtime::displaySlot(99,100) && core_runtime::displaySlot(98,100),"display guard interval");
  check(core_runtime::displaySlot(0xFFFFFFFEu,1) && !core_runtime::displaySlot(0,1),"display guard wrap");
  numeric_ui::DirtyFields fields;
  check(fields.next()==-1,"nothing pending");
  fields.set(8,"0001"); fields.set(0,"TIMEOUT");
  check(fields.next()==0,"safety state priority");
  fields.drawn(0);check(fields.next()==8,"numeric follows status");
  fields.set(8,"0002");check(std::strcmp(fields.text(8),"0002")==0,"latest value replaces deferred value");
  fields.drawn(8);fields.set(8,"0002");check(fields.next()==-1,"unchanged field not redrawn");
  fields.set(8,"0003");fields.set(8,"0002");check(fields.next()==-1,"return to displayed value cancels stale work");
  fields.set(23,"4294967295");check(std::strcmp(fields.text(23),"OVERFLOW")==0,"long counter fits cell");
  fields.drawn(23);fields.set(24,"bad");fields.set(0,nullptr);check(fields.next()==-1,"bad set ignored");
  for(size_t i=0;i<24;++i)fields.set(i,"new");
  unsigned visited=0;
  while(fields.next()>=0){fields.drawn(static_cast<size_t>(fields.next()));++visited;check(visited<=24,"no unbounded queue");}
  check(visited==24,"all 24 fields served");
  std::printf("RUNTIME_TEST_PASS checks=%u\n",checks);
}
