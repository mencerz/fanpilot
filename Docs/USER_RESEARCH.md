# User Feedback Requirements

Research sources: Reddit and public issue trackers for Macs Fan Control and Stats, August 2026.

## P0 — safety and predictability

1. **Control only as a lower bound.** FanPilot may request faster cooling, but it must never prevent macOS from increasing fan speed further.
2. **Return to System on uncertainty.** Sleep, lid close, logout, UI/helper crash, lost connection, update, or invalid sensor data must return control to macOS.
3. **Dedicated sleep/wake state machine.** Save the profile, enter System before sleep, then revalidate the helper and sensors before restoring the profile after wake.
4. **Block unsafe ranges.** Never set RPM below the factory minimum. Unsupported models remain monitoring-only.
5. **Watchdog.** The privileged helper returns to System if it stops receiving a heartbeat.

## P0 — high-quality automatic control

1. **Hysteresis:** separate activation and deactivation temperatures to prevent fan oscillation.
2. **Cooldown:** hold elevated fan speed for 30–180 seconds after temperature falls.
3. **Rate limiting:** ramp up quickly and ramp down gradually.
4. **Multiple sensors:** support CPU, GPU, battery, SSD, and the maximum of a sensor group.
5. **Outcome verification:** compare target and actual RPM for every fan and report rejected commands.

## P1 — compatibility

1. Maintain a matrix by model identifier, chip, fan count, and macOS version.
2. Provide an explicit monitoring-only experience for fanless MacBook Air models.
3. Use separate SMC adapters for Intel, M1/M2, and M3+ hardware.
4. Do not present implausible or unknown readings as valid temperatures; show sensor source, freshness, and availability.
5. Revalidate compatibility for every major and beta macOS release.

## P1 — interface

1. Menu bar display options: CPU, GPU, hottest sensor, RPM, or a compact combination.
2. Profiles: System, Quiet, Balanced, Cooling, Gaming/Render, and custom profiles.
3. Separate battery behavior, defaulting to System.
4. Synchronized or independent control for dual-fan Macs.
5. Always provide `Return control to macOS`.
6. Refreshes must not reset tooltips, keyboard focus, or VoiceOver.

## P1 — trust and diagnostics

1. Use a signed and notarized helper installed once, with a clear explanation of required privileges.
2. No telemetry by default; preferences and history stay local.
3. Export privacy-filtered diagnostics only on explicit user action.
4. Distinguish fanless hardware, unverified models, unavailable helper, and firmware-rejected commands.
5. Updates must never silently change the current mode or profile.

## Critical acceptance scenarios

- close the lid in every mode and verify that fans do not prevent sleep or drain the battery;
- wake a cold and a hot Mac and verify safe profile restoration;
- terminate the UI/helper or heartbeat and verify return to System;
- cross temperature thresholds in both directions and verify stable fan behavior;
- detect dual-fan desynchronization and present a clear warning;
- simulate missing, stale, and implausible sensors;
- test a fanless MacBook Air;
- test clean install, update, and helper removal without repeated password prompts.
