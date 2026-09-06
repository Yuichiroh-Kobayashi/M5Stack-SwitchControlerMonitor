#pragma once
// Minimal rendering API double. No hardware behavior or timing is inferred.
#include <stdint.h>
#include <string>
#include <vector>
#include <cstring>
constexpr uint16_t WHITE=0xFFFF,BLACK=0;
namespace fonts { static const int Font0=0; }
namespace fake {
struct Push {int x,y,w,h;std::string text;};
static uint32_t nowUs=0,transferUs=0;
static bool allocate=true;
static int fontHeight=8;
static std::vector<Push> pushes;
}
inline uint32_t micros(){return fake::nowUs;}
inline uint32_t millis(){return fake::nowUs/1000;}
struct FakeDisplay {
  void setFont(const int*){} void setTextSize(int){} void setTextColor(int,int){}
  void setCursor(int,int){} void print(const char*){}
};
struct FakeM5 {FakeDisplay Display;} static M5;
class M5Canvas {
 public:
  explicit M5Canvas(FakeDisplay*){}
  void setColorDepth(int value){depth_=value;}
  bool createSprite(int w,int h){w_=w;h_=h;return fake::allocate;}
  void setFont(const int*){} void setTextSize(int){} void setTextWrap(bool){}
  int fontHeight(){return fake::fontHeight;}
  int textWidth(const char* text){return static_cast<int>(std::strlen(text))*6;}
  void setTextColor(int,int){} void setCursor(int,int){}
  void fillSprite(int){text_.clear();}
  void print(const char* text){text_=text;}
  void pushSprite(int x,int y){
    fake::pushes.push_back({x,y,w_,h_,text_}); fake::nowUs+=fake::transferUs;
  }
 private:
  int depth_=0,w_=0,h_=0;
  std::string text_;
};
