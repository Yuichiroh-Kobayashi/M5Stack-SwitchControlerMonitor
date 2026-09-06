# Adopted UART / Mega2560 contract — 2026-09-06

The user approved the recommended Receiver-owned binary UART stream, Mega2560 consumer, explicit rearm and nonblocking roller implementation. Owner: #9; downstream integration: #15; physical acceptance: #7. Adoption is a software contract decision, not a physical PASS. The prior ASCII adapter remains unadopted.

## Producer

Receiver emits CONTROL every10ms using the existing CR v1,32-byte,CRC-16/CCITT-FALSE layout at115200 8N1. Sequence and uptime belong to Receiver UART, independently of LAN CONTROL and STATUS. Sequence increments for each attempted complete-frame write, wraps at65536, and restarts at0 on reboot. Uptime is Receiver millis and wraps at2^32. Reserved bytes remain0; LAN layout/port are unchanged.

Only accepted LAN CONTROL refreshes the source timestamp. Invalid source input emits newly encoded neutral, regardless of the received active payload.100ms source silence emits neutral. An invalid/timeout event latches until at least one complete neutral frame has been accepted by UART, even if valid source input returns first. Repeated UART sends never extend source freshness. Invalid neutral has flags/buttons/triggers0, dpad8, sticks128 and battery255.

The single UART writer checks available capacity before writing32 bytes, has no software TX queue, never flushes synchronously and never catches up missed sends. Backpressure skips output and latches neutral; partial writes are counted and never continued later. The downstream sliding parser resynchronizes after a truncated frame. A short write's sequence is not reused. STATUS uartState2 and protocol-error indicate a recorded TX failure; uartState1 means enabled. Neither is a delivery acknowledgment.

At startup, send neutral once Serial2 and self-test are ready. Existing blocking LAN initialization can pause the stream until runtime starts. Runtime deadlines start after setup without catch-up sends; a consumer must remain stopped during initialization/silence. A self-test failure does not authorize UART control output.

## Consumer and operation

Mega parses at most64 bytes per service call without String/read-until/delay. Only complete CRC-valid, forward-sequence CONTROL frames refresh its accepted-frame timestamp. Invalid flags stop immediately despite continuing UART traffic. CRC errors, duplicate/reverse or producer-uptime reversal disarm without extending the timestamp. A forward gap is counted and disarms.100ms silence resets sequence synchronization and disarms. A reboot with reversed continuity is rejected until timeout; modulo sequence/uptime wrap remains valid. This protocol has no session identifier, so header continuity alone is not proof of reboot identity; startup invalid-neutral and explicit rearm remain required.

After startup/loss/lock/emergency/referee stop, release all controls to valid neutral, then press L alone while centered. Hold L to operate. Held L at reconnect cannot arm. A nonneutral L press consumes the neutral-ready condition and requires another release. Neutral received while an external stop is active does not arm later.

The adapter preserves RxData for the existing robot tasks: LY→left wheel, RY→right wheel, RX→pitch, B→roller, A→shot. L is hold-to-enable; disabled state sets SW_LOCK. Axis center128 maps to0 and wheel endpoints to−100/+100. Pitch retains its existing0..255 servo mapping. Physical wheel direction and servo range require manual validation.

Roller uses four states: wait for press,50ms stable press,wait for release,50ms stable release. The repeat guard is500ms from the accepted press and is independent of Shot timing. Stops cancel pending roller/shot state; no delayed toggle survives recovery. UART and external-stop servicing continue on every main loop pass while actuator/CAN updates retain their10ms period.

The inspected sample's stop path also requires a scalar direction-pin index for MotorOFF and zero CAN current/PID state without recomputing velocity control during disable. CAN receive IDs are bounded to the eight allocated motor slots, with an8-byte payload check. These changes prevent the UART safety state from being undermined by the existing output/array handling. Zero current means commanded electrical output off; it does not establish braking distance or mechanical stopping time.

## Reproduction and remaining gates

`python tools/prepare_mega_uart.py --source <original-CoRE2_sample> --output build-temp/<fresh-candidate>` prepares an isolated sample without modifying its source. It checks the inspected controller hash and exact edit anchors, preserves original files, copies the shared protocol/safety sources, and saves before/after hashes. `downstream/mega2560` contains the maintained adapter. The full sample and raw local manifests are not needed in the public repo.

Host tests cover startup, source and consumer100ms boundaries, invalid/nonneutral input, CRC, gaps/duplicate/reverse, partial writes, capacity refusal, no catch-up, sequence/millis wrap, rearm and canceled roller waits. Target builds use existing isolated CoreS3 versions and Mega AVR1.8.8/Servo1.2.2. Tests/build identity are recorded by the implementation report; builds alone do not validate the live chain.

Physical USB mapping remains a prerequisite to LAN testing. The real Receiver/UART/Mega chain needs captures of input loss,LAN loss,UART loss,reconnect/reboot and stop/rearm. Measure source detection,UART serialization (about2.778ms/frame),consumer service and actuator response separately. Do not claim an end-to-end100ms stop from two independent100ms watchdogs.
