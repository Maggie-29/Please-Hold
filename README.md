# Phenomenology-of-Fatigue

Phenomenology of Fatigue is a speculative mechatronic installation and performance system that investigates fatigue as both a physiological process and a perceptual condition. The project uses biosignals, EMG, Wekinator, contact microphones, and SuperCollider to translate muscle tension, tremor, and unstable sensor readings into sound. The system makes audible what the body often conceals: effort, bracing, micro-movement, residual strain, and the gradual failure to remain composed.

`TOPO` is a deterministic hash — the same cable configuration always produces the same value.

### SuperCollider
26 sound presets across 5 tiers:

| Tier | Connections | Character |
|------|-------------|-----------|
| 0 | 0 | Standby silence |
| 1 | 1 | Single tone |
| 2 | 2 | Dual-frequency crosstalk |
| 3 | 3 | Three-voice FM drone / pulse |
| 4 | 4 | Industrial pulse states |
| 5 | 5–6 | Congested exchange noise |

EMG body layer runs continuously beneath the exchange sound: `muscleContraction`, `muscleFatigue`, `fluctuationOscillator`, `crackleBurst`, `muscleThump`, `muscleTwitch`, `tremor`.

Diagnostic states: `COMPOSURE` → `BRACING` → `SUPPRESSED TREMOR` → `FALSE RECOVERY` → `VOLUNTARY COLLAPSE` → `RESIDUAL EFFORT`

### TouchDesigner
Reads MyoWare 2.0 analog output, normalizes 0–1023 → 0.0–1.0, streams via OSC to `/return` at port 57120.

---

## How to Run

1. Upload Arduino sketch from `6x6_matrix_arduino_code/`
2. Open `emg_osc_serial.toe` in TouchDesigner — confirm OSC output to `127.0.0.1:57120`
3. Open `telephone_exchange_june1.scd` in SuperCollider
4. `Cmd+A` → `Shift+Enter` to evaluate main block
5. Wait for `ready.` in post window
6. Evaluate Section 7 separately to open serial bridge
7. `~resetBodyState.()` between performers

---

## Performance

Presented at the DXARTS gallery, McMahon Hall, University of Washington
June 9, 2026

---

## License

See `LICENSE`
