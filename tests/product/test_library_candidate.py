import importlib.util
from pathlib import Path
import unittest

path=Path(__file__).resolve().parents[2]/'tools/prepare_product_libraries.py'
spec=importlib.util.spec_from_file_location('candidate',path)
candidate=importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)

class CandidatePatchTests(unittest.TestCase):
    ethernet=(b'#define SPI_ETHERNET_SETTINGS SPISettings(26000000, MSBFIRST, SPI_MODE0)\r\n'
              b'#define SPI_ETHERNET_40_SETTINGS SPISettings(40000000, MSBFIRST, SPI_MODE0)\r\n'
              b'// unchanged RX, PHY and initialization\r\n')
    usb=b'USB_SPI.beginTransaction(SPISettings(26000000, MSBFIRST, SPI_MODE0));\n'*4
    def test_both_ethernet_paths_lowered(self):
        result=candidate.patch_clock(self.ethernet,8_000_000,8_000_000,26_000_000,'ethernet')
        self.assertEqual(result,self.ethernet.replace(b'26000000',b'8000000').replace(b'40000000',b'8000000'))
    def test_usb_independent_baseline_preserved(self):
        self.assertEqual(candidate.patch_clock(self.usb,8_000_000,8_000_000,26_000_000,'usb'),self.usb)
    def test_all_four_usb_paths(self):
        self.assertEqual(candidate.patch_clock(self.usb,8_000_000,8_000_000,8_000_000,'usb'),self.usb.replace(b'26000000',b'8000000'))
    def test_missing_or_duplicate_macro_rejected(self):
        for data in (b'',self.ethernet*2):
            with self.assertRaises(ValueError): candidate.patch_clock(data,8_000_000,8_000_000,26_000_000,'ethernet')
    def test_partial_usb_patch_rejected(self):
        with self.assertRaises(ValueError): candidate.patch_clock(self.usb[:-1]+self.usb,8_000_000,8_000_000,8_000_000,'usb')
    def test_unreviewed_clock_rejected(self):
        with self.assertRaises(ValueError): candidate.patch_clock(self.ethernet,80_000_000,8_000_000,26_000_000,'ethernet')
    def test_outside_workspace_rejected_before_read(self):
        with self.assertRaises(ValueError): candidate.prepare(Path('/outside/source'),Path('/outside/output'))

if __name__=='__main__': unittest.main()
