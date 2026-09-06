"""Create an isolated Mega candidate from the inspected junior robot sample.

Never modifies the input tree, opens a port, downloads a dependency or uploads.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]
CONTROL_SHA='F028899B65AD8CA8C73906A1CFD1559396A5291ABD02B550B34E9C4F1F305440'


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def replace_once(text, old, new):
    if text.count(old)!=1: raise ValueError('Sample source anchor is missing or ambiguous: '+old[:80])
    return text.replace(old,new,1)


def prepare(source: Path, output: Path):
    source=source.resolve(); output=output.resolve()
    if not output.is_relative_to(ROOT/'build-temp') or output.exists():
        raise ValueError('Use a new child of workspace/build-temp')
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('Input/output must not overlap')
    files=sorted(source.iterdir())
    if any(not p.is_file() or p.is_symlink() for p in files):
        raise ValueError('Expected flat sample without links/subdirectories')
    before={p.name:sha(p) for p in files}
    if before.get('controller.ino')!=CONTROL_SHA: raise ValueError('Controller source does not match inspected baseline')
    # Validate/prepare every edit before creating any output.
    edits={}
    main=(source/'CoRE2_sample.ino').read_text(encoding='utf-8-sig')
    main=replace_once(main,'#include "define.h"','#include "define.h"\n#include "CoREUartSafety.h"')
    main=replace_once(main,'ASCIIで7byte','CR v1 binary 32 bytes, 100Hz, CRC/sequence/100ms watchdog')
    main=replace_once(main,'  StartTime = millis();\n\n  RxController();','  RxController();')
    main=replace_once(main,'  SensorDebugLED();',
        '''  if (!OperationEnable) {
    CancelControllerActions(millis());
    MotorAllOFF();
    ServoON(SHOT, waitangle);
  }
  // Service UART and safety on every pass, control/CAN on a 10ms schedule.
  const uint32_t now=millis();
  if (uint32_t(now-StartTime)<period) return;
  StartTime=now;
  SensorDebugLED();''')
    main=replace_once(main,'  while ((millis() - StartTime) < (period)) {\n    delayMicroseconds(10);\n  }',
        '  // No busy wait: the next loop pass services UART and stop inputs.')
    edits['CoRE2_sample.ino']=main
    define=(source/'define.h').read_text(encoding='utf-8-sig')
    for name in ('StartTime','ControllerRxTime','RollerTime'):
        define=replace_once(define,'uint64_t '+name,'uint32_t '+name)
    edits['define.h']=define
    process=(source/'process.ino').read_text(encoding='utf-8-sig')
    start=process.index('void Roller(void) {'); end=process.index('\n/**',start)
    process=process[:start]+'''void Roller(void) {
  if (rollerSwitch.update(SW_ROLLER!=0,millis())) {
    RollerOnOff = !RollerOnOff;
    motor[ROLLER].TxVel = RollerOnOff ? 15000 : 0;
  }
}
'''+process[end:]
    edits['process.ino']=process
    motor=(source/'motor.ino').read_text(encoding='utf-8-sig')
    motor=replace_once(motor,'  digitalWrite(Dir[motor], !digitalRead(Dir[motor]));\n  // digitalWrite(Dir[motor], LOW);\n  analogWrite(motor, 0);',
        '  analogWrite(motor, 0);\n  digitalWrite(Dir[motor][0], LOW);')
    motor=replace_once(motor,'(MotorRxData.can_id > 0x0200) && (MotorRxData.can_id < 0x020F)',
        '(MotorRxData.can_id >= 0x0201) && (MotorRxData.can_id <= 0x0208) && (MotorRxData.can_dlc == 8)')
    motor=replace_once(motor,'      motor[i].TxVel = 0;  //モータの指令リセット',
        '      motor[i].TxVel = 0;\n      motor[i].TxAmp = 0;\n      PIDdiff[i] = 0;')
    motor=replace_once(motor,'  }\n\n  VelToAmp();','  } else {\n    VelToAmp();\n  }')
    edits['motor.ino']=motor
    output.mkdir(parents=True)
    sketch=output/'CoRE2_sample'; sketch.mkdir()
    for p in files: shutil.copy2(p,sketch/p.name)
    for name,text in edits.items(): (sketch/name).write_text(text,encoding='utf-8')
    for name in ('controller.ino','CoREUartSafety.h'):
        shutil.copy2(ROOT/'downstream/mega2560'/name,sketch/name)
    for relative in ('core_protocol/CoreProtocol.h','core_protocol/CoreProtocol.cpp',
                     'core_safety/UartInput.h','core_safety/RollerSwitch.h'):
        dest=sketch/'src'/relative; dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(ROOT/'src'/relative,dest)
    if before!={p.name:sha(p) for p in files}: raise ValueError('Input changed during preparation')
    after={p.relative_to(sketch).as_posix():sha(p) for p in sorted(sketch.rglob('*')) if p.is_file()}
    manifest=dict(schema='core-mega-uart-candidate-v1',source=str(source),before=before,after=after,
                  physical='NOT_RUN',changed=[n for n,v in after.items() if before.get(n)!=v])
    (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
    return sketch


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    print(prepare(args.source,args.output))
