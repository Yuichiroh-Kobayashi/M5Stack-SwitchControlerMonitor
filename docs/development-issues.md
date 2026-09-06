# Active CoRE development outcomes

Baseline saved to origin: `68619ddd254da008bbe1bf3add4823b527e55241`, branch `feat/cores3se-dualsense-lan-stack-diagnostic`. Main/upstream were not changed. The initial snapshot contains45 relevant source/document/test files; reference PDFs and historical handoff artifacts remain local. Raw captures and build-temp freezes are not Git-clone artifacts.

| Issue | Outcome | Dependency / boundary |
|---|---|---|
| [#7](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/7) | 100Hz /25Hz /safe UART physical integration | Parent; never closes on build alone |
| [#8](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/8) | HORI product profile, invalid-input neutralization | Software candidate; USB-only physical gate owned by #7 |
| [#9](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/9) | UART safety on invalid input and timeout | Sequence/reconnect contract requires design |
| [#10](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/10) | Isolated low-SPI candidates | Separate clock, USB, LCD and PHY comparison factors |
| [#11](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/11) | Deadline-based100Hz CONTROL/STATUS | Physical LAN validation follows USB-only mapping |
| [#12](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/12) | Communication-prioritized25Hz numeric display | Measured blocking and dirty-field scheduling |
| [#13](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/13) | Reproducible pinned builds and native host tests | No global package changes or uploads |
| [#14](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/14) | USB/LAN instability cause separation | No reset workaround or unmeasured electrical claim |
| [#15](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/15) | Downstream UART compatibility decision | ASCII adapter not adopted |

Individual historical Gate attempts belong to these Issues' evidence/checklists, not separate Issues. Issue status and actual validation records are authoritative; this index does not claim completion or merge.
