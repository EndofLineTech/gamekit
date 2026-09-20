# Controller integration — validation in progress

Issue: `gamekit-5my`. Hardware acceptance is pending for the user's DualSense and
Xbox controllers; this document does not claim completed Windows-game support.

The Controllers panel reads macOS GameController devices and previews basic
buttons, sticks and triggers while Gamekit is foreground. It does not request
background input or inject controller events. Mac detection alone does not prove
the Wine or game path works.

**Steam controller settings** starts/reuses managed Windows Steam, opens
`steam://settings/controller`, and uses the owned-window foreground handoff.
Configure Steam Input there, then select the appropriate gamepad or keyboard/mouse
layout for each game. A mouse-only title does not gain native gamepad support
merely because a controller is connected.

Wine 10's `winebus.sys` enables SDL and controller mapping by default and has a
macOS IOHID path. Its defaults prefer raw HID for DualSense/DualShock devices;
Steam Input may therefore matter for XInput-only games. No registry preference
or driver has been changed for this work.

`diagnostics/controller_probe.cpp` reads attached DirectInput devices and samples
four XInput slots for five seconds without rumble or input injection. The opt-in
`ControllerAcceptanceTests` runs it in an existing owned Steam session using
`GAMEKIT_CONTROLLER_PROBE=/absolute/path/to/probe.exe`. These observations do not
include Steam Input's per-game emulation or establish game acceptance.

Pending: verify hotplug and physical button/axis input on one DualSense and one
Xbox controller, compare Windows visibility, and verify a controller-capable game.
Rumble, motion sensors, touchpad and adaptive triggers need separate evidence.
