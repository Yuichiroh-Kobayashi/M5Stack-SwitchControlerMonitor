"""Create a new, hashed low-clock library candidate; never edit source/global libraries."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]
PINS={'M5Unified':'0.2.19','M5GFX':'0.2.26','M5-Ethernet':'4.0.0',
      'USB_Host_Shield_Library_2.0':'1.7.0'}
AUTHORITY={
 'M5-Ethernet/src/utility/w5100.h':'bb0e366206a99e283d1f1492f03bb326dcc9ee2731b38bfc7303924f88f16f0c',
 'USB_Host_Shield_Library_2.0/usbhost.h':'00f9217a5d32691794560a8029d32b610903d2a92837d758e11836058db98d82'}

def digest(data):
    return hashlib.sha256(data).hexdigest()

def replace_exact(data, old, new, count):
    if data.count(old)!=count:
        raise ValueError(f'Patch occurrence mismatch: expected {count}')
    return data.replace(old,new)

def patch_clock(data, normal, tx, usb, kind):
    if normal not in (4_000_000,8_000_000,26_000_000) or tx not in (4_000_000,8_000_000,40_000_000) or usb not in (8_000_000,26_000_000):
        raise ValueError('Clock outside reviewed comparison choices')
    if kind=='ethernet':
        for macro,before,after in (('SPI_ETHERNET_SETTINGS',26_000_000,normal),('SPI_ETHERNET_40_SETTINGS',40_000_000,tx)):
            old=f'#define {macro} SPISettings({before}, MSBFIRST, SPI_MODE0)'.encode()
            new=f'#define {macro} SPISettings({after}, MSBFIRST, SPI_MODE0)'.encode()
            data=replace_exact(data,old,new,1)
        return data
    if kind=='usb':
        return replace_exact(data,b'USB_SPI.beginTransaction(SPISettings(26000000, MSBFIRST, SPI_MODE0))',
                             f'USB_SPI.beginTransaction(SPISettings({usb}, MSBFIRST, SPI_MODE0))'.encode(),4)
    raise ValueError('Unknown patch kind')

def inventory(path):
    result={}
    for folder in PINS:
        for item in sorted((path/folder).rglob('*')):
            if item.is_symlink():
                raise ValueError('Symlink in source library tree')
            if item.is_file():
                result[item.relative_to(path).as_posix()]=digest(item.read_bytes())
    return result

def prepare(source, output, normal=8_000_000, tx=8_000_000, usb=26_000_000):
    source=source.resolve(); output=output.resolve()
    if not source.is_relative_to(ROOT/'build-temp') or not output.is_relative_to(ROOT/'build-temp'):
        raise ValueError('Both source and output must be inside workspace build-temp')
    if output.exists() or output.is_relative_to(source) or source.is_relative_to(output):
        raise ValueError('Output must be fresh and disjoint from source')
    for folder,version in PINS.items():
        props=dict(line.split('=',1) for line in (source/folder/'library.properties').read_text(encoding='utf-8-sig').splitlines() if '=' in line)
        if props.get('version')!=version:
            raise ValueError(f'Pinned version mismatch: {folder}')
    before=inventory(source)
    patches={}
    for path,sha in AUTHORITY.items():
        if before.get(path)!=sha:
            raise ValueError(f'Unknown baseline bytes: {path}')
        patches[path]=patch_clock((source/path).read_bytes(),normal,tx,usb,
                                  'ethernet' if path.startswith('M5-') else 'usb')
    output.mkdir(parents=True)
    libraries=output/'libraries'
    for folder in PINS:
        shutil.copytree(source/folder,libraries/folder)
    for path,data in patches.items():
        (libraries/path).write_bytes(data)
    after=inventory(libraries)
    if inventory(source)!=before:
        raise ValueError('Source changed during preparation; discard candidate from consideration')
    expected=dict(before)
    expected.update({path:digest(data) for path,data in patches.items()})
    if after!=expected:
        raise ValueError('Unexpected candidate tree change')
    manifest={'versions':PINS,'clock_hz':{'ethernet_normal':normal,'ethernet_tx':tx,'usb':usb},
              'before':before,'after':after,'changed_files':[p for p in before if before[p]!=after[p]],
              'physical':'NOT_RUN','claim':'SOURCE_PREPARED_NOT_BUILD_OR_PHYSICAL_PASS'}
    target=output/'manifest.json'
    target.write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n',encoding='utf-8')
    print(f'LIBRARY_CANDIDATE={output.name} MANIFEST_SHA256={digest(target.read_bytes())}')
    return manifest

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=ROOT/'build-temp/usb-lan-isolation/libraries')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--normal-hz',type=int,default=8_000_000)
    parser.add_argument('--tx-hz',type=int,default=8_000_000)
    parser.add_argument('--usb-hz',type=int,default=26_000_000)
    args=parser.parse_args()
    prepare(args.source,args.output,args.normal_hz,args.tx_hz,args.usb_hz)
