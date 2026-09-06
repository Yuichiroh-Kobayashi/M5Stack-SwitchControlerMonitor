"""Compile and execute actual product C++ on the host; never communicates with hardware."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='core-host-') as temp:
    executable=Path(temp)/('controller-tests.exe' if os.name=='nt' else 'controller-tests')
    subprocess.run([os.environ.get('CXX','g++'),'-std=c++11','-Wall','-Wextra','-Werror',
                    '-pedantic','-I',str(ROOT),str(ROOT/'tests/product/controller_profile_test.cpp'),
                    str(ROOT/'src/core_protocol/CoreProtocol.cpp'),'-o',str(executable)],check=True)
    subprocess.run([str(executable)],check=True)
subprocess.run(['python',str(ROOT/'tools/core_protocol_reference.py')],check=True)
