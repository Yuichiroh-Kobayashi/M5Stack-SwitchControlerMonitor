# Mega2560 adapter

These files adapt the inspected junior robot sample to the [adopted binary contract](../../docs/uart-mega-contract.md). They are not a standalone replacement for the robot sketch. Generate a reviewable complete candidate with `tools/prepare_mega_uart.py`; the original sample remains untouched during preparation. The generator updates main scheduling, Roller(), stop outputs and millis variable widths, and copies the exact shared protocol/parser sources under the candidate's `src/` directory.

Build the complete generated `CoRE2_sample` with `arduino:avr:mega:cpu=atmega2560`, existing AVR1.8.8 and Servo1.2.2. Use workspace-isolated copies and fresh build directories. Apply only after reviewing the before/after manifest and verifying the target is unchanged. Firmware upload is a separate operation requiring exact device identity and a physical gate.

Controls: neutral/release then press L alone to enable, hold L while operating. LY/RY drive left/right wheels, RX retains the existing pitch mapping, B toggles the roller after stable press/release, A operates shot. Release L or assert emergency/referee stop to disarm and cancel pending actions. Reconnection with L held cannot rearm. Actual wheel polarity, servo travel and mechanical stopping remain unvalidated.
