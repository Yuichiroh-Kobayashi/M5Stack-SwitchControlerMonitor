import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
import core_protocol_reference as wire

class UartReference(unittest.TestCase):
    def test_header_and_lease(self):
        p=bytearray(wire.control_frame(300,9000));p[11]=1;p[12:14]=b'\x00\x13';p[15]=255
        source=wire.finish(p)
        output=wire.decode(wire.uart_control_frame(7,100,source,99))
        self.assertEqual((output['sequence'],output['uptime_ms'],output['buttons']),(7,100,19))
        for age,forced in [(100,False),(0,True)]:
            stopped=wire.decode(wire.uart_control_frame(8,110,source,age,forced))
            self.assertEqual((stopped['control_flags'],stopped['buttons'],stopped['left_x']),(0,0,128))

    def test_invalid_non_neutral_and_corrupt(self):
        p=bytearray(wire.control_frame());p[15]=255
        frame=wire.uart_control_frame(0,0,wire.finish(p),0)
        self.assertEqual(wire.decode(frame)['left_x'],128)
        p[15]^=1
        with self.assertRaises(ValueError):wire.uart_control_frame(0,0,bytes(p),0)
