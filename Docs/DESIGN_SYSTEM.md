# FanPilot Design System

## Principle

FanPilot should feel like a native macOS control: calm, compact, and understandable at a glance. The main screen answers only three questions:

1. Is everything working normally?
2. What are the current temperature and fan speeds?
3. Who is controlling cooling right now?

Advanced settings must not compete with these answers.

## Information architecture

### Menu bar popover

- current status and highest fresh temperature;
- actual RPM for each fan;
- `System / Auto / Manual` mode selector;
- one contextual control for the selected mode;
- a warning only when user action is required;
- Settings and Quit actions.

### Settings

- Profiles: temperature curve, cooldown, and battery behavior.
- Display: menu bar value and measurement units.
- Safety: helper status, model support, and diagnostics export.

## Tokens

### Color

Use native dynamic macOS colors. Color must never be the only carrier of meaning.

- `accent`: system accentColor for selection and interaction;
- `healthy`: green for a verified normal state;
- `attention`: orange for degraded state or required action;
- `critical`: red for dangerous temperature or loss of control;
- `secondary`: secondary label color for units and supporting text;
- `surface`: native window and control backgrounds, with no decorative gradients.

Default temperature thresholds:

- below 70°C: neutral;
- 70–84°C: attention;
- 85°C and above: critical.

### Typography

- app title: `title3 / semibold`;
- key value: `title2 / semibold / monospacedDigit`;
- primary content: `body`;
- supporting content: `caption / secondary`;
- actions: native `body`.

Avoid all caps, decorative fonts, and more than three text hierarchy levels on one screen.

### Layout

- base unit: 4 pt;
- popover padding: 16 pt;
- spacing between semantic sections: 16 pt;
- spacing within a group: 8 pt;
- icon-to-label spacing: 8 pt;
- minimum interactive height: 28 pt;
- popover width: 344 pt.

### Shape

- native segmented controls, sliders, and buttons;
- reading panel: 10 pt radius and a subtle separator border;
- badges only communicate status, never decoration;
- no shadows inside the popover.

## Components

### Status Header

App name and state on the left (`Managed by macOS`, `Auto · Cooling`), temperature on the right. Temperature includes °C and a descriptive accessibility label.

### Fan Row

Fan name, actual RPM, supported range, and a compact progress indicator. Two fans remain separate and never merge readings.

### Mode Control

A single segmented control. Selecting Auto or Manual without an installed helper must not pretend to succeed; it should offer a clear installation flow.

### Context Control

- `System`: short confirmation that macOS controls cooling;
- `Auto`: profile name and calculated target;
- `Manual`: one slider and target RPM or percentage.

### Inline Notice

One sentence and at most one action. Sensor refreshes must not cause notices to jump in height.

## States

- `System / normal`: green dot, custom controls hidden;
- `Automatic`: accent indicator, profile, and calculated target;
- `Manual`: orange indicator and persistent `Manual control` label;
- `Hot`: red temperature without flashing UI;
- `Unsupported`: monitoring remains available, control is removed;
- `Fanless`: `This Mac has no fan`, with no empty RPM values;
- `Stale`: last value with its age, then an em dash;
- `Helper unavailable`: mode remains System and recovery is offered;
- `Sleeping`: System is forced before sleep and no active profile is promised.

## UX rules

1. Never show more than one slider on the main screen.
2. A safe escape hatch is always available: `Return control to macOS`.
3. Never display a selected control mode before the helper confirms it.
4. Confirm every command using actual RPM, not only a successful API call.
5. The two-second refresh must not reset focus, hover, or VoiceOver.
6. Charts and full sensor lists belong in the detailed window only.
7. Explain the effect of dangerous settings without repeated confirmation dialogs.
8. Every value includes a unit; RPM values use monospaced digits.

## Accessibility

- full keyboard navigation;
- descriptive VoiceOver labels such as `Left fan, 2,180 revolutions per minute`;
- status is expressed with text as well as color;
- support Increase Contrast, Reduce Transparency, Dynamic Type, and Reduce Motion;
- text contrast meets WCAG AA.
