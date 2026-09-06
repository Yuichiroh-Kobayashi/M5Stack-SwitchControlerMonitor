"""Compile and execute actual product C++ on the host; never communicates with hardware."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='core-host-') as temp:
    for source in ('controller_profile_test.cpp','runtime_test.cpp','numeric_display_test.cpp','usb_intake_test.cpp','uart_safety_test.cpp','mega_adapter_test.cpp'):
        executable=Path(temp)/(source+('.exe' if os.name=='nt' else '.out'))
        subprocess.run([os.environ.get('CXX','g++'),'-std=c++11','-Wall','-Wextra','-Werror',
                        '-pedantic','-I',str(ROOT/'tests/product/stubs'),'-I',str(ROOT),str(ROOT/'tests/product'/source),
                        str(ROOT/'src/core_protocol/CoreProtocol.cpp'),'-o',str(executable)],check=True)
        subprocess.run([str(executable)],check=True)
subprocess.run(['python',str(ROOT/'tools/core_protocol_reference.py')],check=True)
subprocess.run(['python','-m','unittest','discover','-s',str(ROOT/'tests/product'),'-p','test_*.py'],check=True)
