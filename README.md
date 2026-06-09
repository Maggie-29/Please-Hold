# Please Hold

**Yuhanxiao (Maggie) Ma** — DXARTS Mechatronic Art, Spring 2026

A media performance and sound installation built from a custom 6×6 patchboard, a MyoWare 2.0 EMG sensor, two Arduino Unos, and SuperCollider + TouchDesigner.

The performer patches cables on a switchboard while wearing a muscle sensor on the forearm. The cables determine the sonic state. The arm determines how it degrades.

The piece draws from the history of telephone switchboard labor — operators who routed calls through physical plug-and-socket connections, managing information flow through sustained and repetitive physical effort. That logic maps onto modular synthesis: both are patch-based systems where routing is manual, visible, and bodily. The patchboard holds these two references in the same physical form.

The system does not respond to gesture as expression. It responds to labor as signal. Muscle tension, fatigue, and signal instability are control data. The body is not performing at the instrument. It is part of the circuit.

The work sits within Anthropocene and posthumanist frameworks not through metaphor but through material logic: the distributed, non-human-centered systems that organize everyday life are made audible. Who sustains large-scale infrastructure, what forms of labor remain hidden, and what it means to experience communication as an embodied process rather than a transparent one.

---

## Performance Documentation

[Watch on Vimeo](https://vimeo.com/1199640910)
<img width="2395" height="1320" alt="IMG_0285" src="https://github.com/user-attachments/assets/036ec2e1-d594-4b3e-9521-ef8695d945ed" />


---

## System Architecture

```
MyoWare 2.0 EMG (forearm)
        ↓ analog signal
EMG Arduino
        ↓ serial
TouchDesigner (emg_osc_serial.toe)
        ↓ OSC /return → port 57120
SuperCollider (telephone_exchange_june1.scd)
        ↑ OSC /patch/state
Patchboard Arduino
        ↑ CONN:N TOPO:M @ 115200 baud
6×6 Patchboard (passive matrix, female TS jacks)
```

---

## Jack Wiring

The jacks are wired as passive switches — no audio signal, circuit closure only.

```
Input row  (IN 1–6)  → tip terminal → Arduino drive pins 2, 3, 4, 5, 6, 7
                        sleeve terminal → Arduino GND

Output row (OUT 1–6) → tip terminal → Arduino sense pins 8, 9, 10, 11, 12, 13
                        sleeve terminal → Arduino GND

```
<img width="8064" height="6048" alt="IMG_9719" src="https://github.com/user-attachments/assets/205e44ee-344c-4397-bafa-c013bc529d2f" />

When a cable connects IN i to OUT j, it bridges `drivePins[i]` to `sensePins[j]`. The Arduino pulls each drive pin LOW (800µs settle) and reads sense pins with `INPUT_PULLUP`. A LOW reading indicates an active connection.

On any change, the Arduino outputs:
```
PATCH IN1 OUT3
CONN:2 TOPO:47
```

`CONN` is the number of active connections. `TOPO` is a deterministic hash — the same cable configuration always produces the same value and therefore the same sound. Patching and unpatching cables is not expressive variation; it is state change in a switching system.

---

## Preset Tiers

| Tier | Connections | Sonic Character |
|------|-------------|-----------------|
| 0 | 0 | Standby silence |
| 1 | 1 | Single tone |
| 2 | 2 | Dual-frequency crosstalk |
| 3 | 3 | Three-voice FM drone / pulse |
| 4 | 4 | Industrial pulse states |
| 5 | 5–6 | Congested exchange noise |

26 presets total, distributed across tiers. Within each tier, different TOPO values select different variants — same connection count, different routing, different sound.

---

## EMG Body Layer

The MyoWare 2.0 sensor reads forearm muscle activation continuously. TouchDesigner normalizes the raw signal (0–1023 → 0.0–1.0) and streams it via OSC to SuperCollider, where it drives a second signal layer running beneath the exchange sound at all times.

**Signal processing:**
- `smoothedEMG` — low-pass smoothed activation level
- `fluctuation` — signal instability, computed from frame-to-frame delta
- `fatigue` — session accumulator; increases with activation and time, never resets between patches

**Body synths:**
- `muscleContraction` — continuous, tracks smoothed EMG; pulse rate and tremor frequency scale with tension
- `muscleFatigue` — rumble layer; amplitude and irregularity increase with fatigue accumulator
- `fluctuationOscillator` — unstable oscillator tracking signal instability
- `crackleBurst` — fires on moderate EMG variance spikes
- `muscleThump` — low-frequency thump fires on large spikes
- `muscleTwitch` — single twitch fires on diagnostic state transitions
- `tremor` — burst fires when belief or fluctuation exceeds threshold

**Diagnostic states** (transition triggers twitches and tremor bursts):
```
COMPOSURE → BRACING → SUPPRESSED TREMOR → FALSE RECOVERY → VOLUNTARY COLLAPSE → RESIDUAL EFFORT
```

Fatigue accumulates for the full duration of a performance and does not reset between patch changes. `~resetBodyState.()` resets all accumulators between performers.

---

## Fabrication

The patchboard panel is a wooden board base with a sublimation-printed polyester fabric surface — grid layout, input/output labels, and graphic design printed directly onto the fabric and mounted on the board. The 12 female TS jacks are mounted through the panel, with all wiring running on the reverse side.

---

## Files

| File | Description |
|------|-------------|
| `6x6_matrix_arduino_code/` | Arduino matrix scan — outputs CONN + TOPO hash over serial |
| `myoware_code/` | Separate Arduino reading MyoWare 2.0 analog output |
| `telephone_exchange_june1.scd` | SuperCollider instrument — 26 presets, EMG body layer, serial bridge |
| `emg_osc_serial.toe` | TouchDesigner — EMG normalization, OSC to SuperCollider |
| `switchboard_sublimation_print.jpg` | Patchboard fabric surface print file |

---

## Run

1. Upload matrix scan sketch to patchboard Arduino
2. Upload MyoWare sketch to EMG Arduino
3. Open `emg_osc_serial.toe` in TouchDesigner — confirm OSC output to `127.0.0.1:57120`
4. Open `telephone_exchange_june1.scd`, `Cmd+A` → `Shift+Enter`
5. Wait for `ready.` in post window — then evaluate Section 7 separately to open serial bridge
6. `OSCFunc.trace(false)` if post window floods
7. `~resetBodyState.()` between performers

