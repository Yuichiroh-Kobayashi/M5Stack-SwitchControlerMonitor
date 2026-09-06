#include <stdint.h>
#include <deque>
#include <cstdio>
#include <cstdlib>
static uint32_t nowMs=0;
uint32_t millis(){return nowMs;}
struct FakeSerial {
  std::deque<uint8_t> data;
  int available(){return int(data.size());}
  int read(){if(data.empty())return -1;int v=data.front();data.pop_front();return v;}
} Serial1;
static bool AF_Signal1=false,EMG_Stop=false,ControllerTimeout=true;
static uint32_t ControllerRxTime=0;
static int RxData[10]={};
static uint8_t RollerSeq=0,RollerOnOff=0,ShotSeq=0,Shotmove=0;
constexpr uint8_t RMmotorNUM=8;
struct Motor {int32_t TxVel,TxAmp;} motor[RMmotorNUM]={};
static float PIDdiff[RMmotorNUM]={};
#include "downstream/mega2560/CoREUartSafety.h"
#include "downstream/mega2560/controller.ino"
static unsigned checks=0;
void check(bool p,const char* why){++checks;if(!p){std::fprintf(stderr,"FAIL %s\n",why);std::exit(1);}}
void enqueue(uint16_t sequence,core_protocol::ControlPayload p){uint8_t frame[32];core_protocol::encodeControl(frame,sequence,sequence*10,p);for(auto b:frame)Serial1.data.push_back(b);}
int main(){
  auto p=core_protocol::neutralControl();p.controlFlags=1;
  check(RxController() && RxData[4]==1,"adapter boots with lock and timeout");
  enqueue(0,p);p.buttons=0x10;enqueue(1,p);
  p.buttons=0x13;p.rightY=255;p.leftY=0;p.rightX=255;enqueue(2,p);
  check(!RxController() && Serial1.available()==32,"adapter bounds drain to64 bytes");
  check(RxData[4]==0 && RxData[2]==0 && RxData[3]==0,"neutral enable does not request action");
  nowMs=10;RxController();
  check(RxData[0]==255 && RxData[2]==100 && RxData[3]==-100 && RxData[4]==6,"actual RxData mapping and lock polarity");
  EMG_Stop=true;RxController();check(RxData[4]==1 && RxData[2]==0,"hardware stop locks even without UART bytes");
  EMG_Stop=false;enqueue(3,p);nowMs=20;RxController();check(RxData[4]==1,"held L after stop cannot resume");
  p=core_protocol::neutralControl();p.controlFlags=1;enqueue(4,p);p.buttons=0x10;enqueue(5,p);RxController();
  check(RxData[4]==0,"release and L rearm via actual adapter");
  nowMs=120;check(RxController() && RxData[4]==1 && ControllerRxTime==20,"watchdog not renewed by polling");
  RollerSeq=2;RollerOnOff=1;ShotSeq=1;Shotmove=1;
  for(uint8_t i=0;i<RMmotorNUM;++i){motor[i].TxVel=15000;motor[i].TxAmp=100;PIDdiff[i]=99;}
  rollerSwitch.update(true,500);rollerSwitch.update(true,550);rollerSwitch.update(false,551);
  CancelControllerActions(580);
  check(!RollerSeq && !RollerOnOff && !ShotSeq && !Shotmove && !rollerSwitch.update(false,1000),"cancel both action and pending debounce states");
  for(uint8_t i=0;i<RMmotorNUM;++i)check(!motor[i].TxVel && !motor[i].TxAmp && !PIDdiff[i],"zero motor command and PID memory");
  std::printf("MEGA_ADAPTER_TEST_PASS checks=%u\n",checks);
}
