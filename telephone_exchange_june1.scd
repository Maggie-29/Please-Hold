// ============================================================
// TELEPHONE EXCHANGE INSTRUMENT v3.2
// Inputs:
//   Arduino serial @ /dev/tty.usbserial-130 @ 115200 baud
//     → prints "CONN:N TOPO:M" → drives preset state machine
//   TouchDesigner OSC → /return @ 57120
//     → EMG raw 0-1023 → modulates saturation/noise/dropout
//     → muscle contraction, fatigue, tremor, fluctuation, bursts
// ============================================================
// HOW TO RUN:
//   1. Cmd+A to select all, Shift+Enter to evaluate
//   2. Wait for "ready." in post window
//   3. Evaluate Section 7 separately to open serial bridge
//   4. OSCFunc.trace(false) if post window is flooding
//   5. ~resetBodyState.() between participants
// ============================================================

(
s.options.numOutputBusChannels = 2;
s.options.numInputBusChannels  = 2;
s.options.memSize = 65536;

s.waitForBoot({

    // ============================================================
    // SECTION 1: SYNTHDEFS
    // ============================================================

    SynthDef(\relayClick, {
        arg out=0, density=1.0, ringFreq=900, ringDecay=0.08,
            jitter=0.02, amp=0.5, gate=1;
        var trig, click, env;
        trig  = Dust.ar(density + LFNoise1.kr(0.5).range(0, density * 0.3));
        click = Ringz.ar(trig, ringFreq + LFNoise0.ar(density).range(-40,40), ringDecay);
        click = click + (Ringz.ar(trig, ringFreq * 1.37, ringDecay * 0.6) * 0.4);
        click = click * 0.7;
        env   = EnvGen.kr(Env.asr(0.01, 1, 0.3), gate, doneAction: 2);
        Out.ar(out, (click * amp * env).dup);
    }).add;

    SynthDef(\teleTone, {
        arg out=0,
            freq1=350, freq2=440, freq3=0,
            fmIndex=0, fmRatio=1,
            gateRate=0,
            amp=0.3, gate=1;
        var sig, mod, env, tele;
        mod  = SinOsc.ar(freq2 * fmRatio) * freq1 * fmIndex;
        sig  = SinOsc.ar(freq1 + mod) * 0.5;
        sig  = sig + (SinOsc.ar(freq2) * 0.4);
        sig  = sig + (SinOsc.ar(freq3) * 0.3 * (freq3 > 0).asInteger);
        tele = BPF.ar(sig, 1000, 2.5) * 2.0;
        tele = HPF.ar(tele, 300);
        tele = LPF.ar(tele, 3400);
        tele = tele * Select.ar(
            (gateRate > 0).asInteger,
            [ DC.ar(1), LFPulse.ar(gateRate.max(0.01), 0, 0.5) ]
        );
        env  = EnvGen.kr(Env.asr(0.08, 1, 0.5), gate, doneAction: 2);
        Out.ar(out, (tele * amp * env).dup);
    }).add;

    SynthDef(\crosstalk, {
        arg out=0,
            bpfFreq1=800, bpfFreq2=1800, bpfQ=8,
            noiseAmp=0.15, gated=0, gateRate=1.5,
            amp=0.2, gate=1;
        var noise, band1, band2, sig, env;
        noise = PinkNoise.ar(1);
        band1 = Resonz.ar(noise, bpfFreq1, 1/bpfQ) * 2.0;
        band2 = Resonz.ar(noise, bpfFreq2, 1/bpfQ) * 1.5;
        sig   = (band1 + band2) * noiseAmp;
        sig   = sig * Select.ar(
            (gated > 0).asInteger,
            [ DC.ar(1), LFPulse.ar(gateRate.max(0.01), 0, 0.4) + 0.2 ]
        );
        env   = EnvGen.kr(Env.asr(0.15, 1, 0.8), gate, doneAction: 2);
        Out.ar(out, (sig * amp * env).dup);
    }).add;

    SynthDef(\saturation, {
        arg inBus=0, out=0,
            clipThresh=1.0,
            dropProb=0.0,
            dropDur=0.07,
            amp=1.0;
        var sig, clipped, dropTrig, dropout;
        sig      = In.ar(inBus, 2);
        clipped  = (sig / clipThresh.max(0.01)).tanh * clipThresh;
        dropTrig = Dust.kr(dropProb);
        dropout  = 1 - EnvGen.kr(
            Env([0,1,1,0], [0, dropDur * 0.1, dropDur * 0.9]),
            dropTrig
        );
        Out.ar(out, clipped * dropout * amp);
    }).add;

    SynthDef(\operatorError, {
        arg out=0, amp=0.5;
        var env, bounce;
        env    = EnvGen.kr(Env([1,0,0,1],[0.005,0.09,0.02]), 1, doneAction: 2);
        bounce = Ringz.ar(
            Impulse.ar(0) + DelayN.ar(Impulse.ar(0), 0.12, 0.10),
            600, 0.15
        ) * 0.5;
        Out.ar(out, (bounce * amp * env).dup);
    }).add;

    SynthDef(\standbyHiss, {
        arg out=0, amp=0.04, gate=1;
        var sig, env;
        sig = BrownNoise.ar(1);
        sig = HPF.ar(sig, 400);
        sig = LPF.ar(sig, 4000);
        env = EnvGen.kr(Env.asr(1.0, 1, 2.0), gate, doneAction: 2);
        Out.ar(out, (sig * amp * env).dup);
    }).add;

    // ---- BODY SYNTHDEFS ----

    // Single muscle twitch — fires on diagnostic state change
    SynthDef(\muscleTwitch, {
        arg out=0, amp=0.75, baseFreq=85,
            stimToOnset=0.0069, onsetToPeak=0.0131, ampVariance=0.3;
        var sig, env, tone, noise, snap, actualAmp, toneFreq;
        actualAmp = amp * LFNoise1.kr(0.5).range(1 - ampVariance, 1 + ampVariance);
        env = Env([0,0,0.4,1,0.3,0],
            [stimToOnset, 0.0036, onsetToPeak - 0.0036, 0.008, 0.025],
            [0, 4, -2, -3, -4]
        ).kr(doneAction: 2);
        toneFreq = baseFreq + LFNoise1.kr(8).range(-10, 10);
        tone  = SinOsc.ar(toneFreq) * 0.5;
        tone  = tone + (SinOsc.ar(toneFreq * 1.5) * 0.2);
        tone  = tone + (SinOsc.ar(toneFreq * 0.5) * 0.15);
        noise = BPF.ar(WhiteNoise.ar, toneFreq * 2.5, 0.4) * 0.25;
        noise = noise + (BPF.ar(PinkNoise.ar, toneFreq * 1.2, 0.6) * 0.15);
        snap  = Decay.ar(Impulse.ar(0), 0.003) *
            BPF.ar(WhiteNoise.ar, 180, 0.3) * 0.3;
        sig = (tone + noise + snap) * env;
        sig = LPF.ar(sig, 350);
        sig = HPF.ar(sig, 30);
        sig = Limiter.ar(sig * actualAmp, 0.8);
        Out.ar(out, sig ! 2);
    }).add;

    // Continuous muscle contraction — always running, modulated by EMG
    SynthDef(\muscleContraction, {
        arg out=0, amp=0.0, tension=0.5, tremor=6, baseFreq=75, gate=1;
        var sig, env, pulseRate, twitchTrigger, twitch;
        var noise, rumble, tremorMod;
        env          = EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);
        pulseRate    = tension.linlin(0, 1, 20, 50);
        twitchTrigger = Impulse.ar(pulseRate + LFNoise1.kr(2).range(-5, 5));
        twitch       = Decay2.ar(twitchTrigger, 0.003, 0.015) *
            SinOsc.ar(baseFreq + LFNoise1.kr(3).range(-15, 15));
        rumble       = BPF.ar(PinkNoise.ar, baseFreq * 0.8, 0.8) * 0.3;
        rumble       = rumble + (SinOsc.ar(baseFreq * 0.6 + LFNoise1.kr(0.5).range(-5, 5)) * 0.2);
        tremorMod    = SinOsc.kr(tremor + LFNoise1.kr(0.3).range(-1, 1)) * 0.3 + 0.7;
        noise        = BPF.ar(WhiteNoise.ar, baseFreq * 1.5, 0.5) * 0.15;
        sig = (twitch + rumble + noise) * tremorMod * env;
        sig = LPF.ar(sig, 280);
        sig = HPF.ar(sig, 35);
        sig = Limiter.ar(sig * amp, 0.8);
        Out.ar(out, sig ! 2);
    }).add;

    // Fatigue rumble — accumulates over session
    SynthDef(\muscleFatigue, {
        arg out=0, amp=0.0, fatigueLevel=0.0, gate=1;
        var sig, env, pulseRate, irregular, twitch, noise;
        var baseFreq, freqDrift;
        env       = EnvGen.kr(Env.asr(0.1, 1, 0.2), gate, doneAction: 2);
        irregular = LFNoise1.kr(fatigueLevel.linlin(0, 1, 0.5, 8));
        pulseRate = fatigueLevel.linlin(0, 1, 45, 15);
        baseFreq  = fatigueLevel.linlin(0, 1, 95, 55);
        freqDrift = LFNoise1.kr(1).range(-10, 10) * fatigueLevel;
        twitch    = Decay2.ar(
            Dust.ar(pulseRate + (irregular * 10)), 0.005, 0.02
        ) * SinOsc.ar(baseFreq + freqDrift);
        noise = BPF.ar(PinkNoise.ar, baseFreq, 0.6) *
            fatigueLevel.linlin(0, 1, 0.1, 0.4);
        sig = (twitch + noise) * env;
        sig = LPF.ar(sig, 250);
        sig = HPF.ar(sig, 30);
        sig = Limiter.ar(sig * amp, 0.8);
        Out.ar(out, sig ! 2);
    }).add;

    // Tremor burst — fires on high belief or fluctuation
    SynthDef(\tremor, {
        arg out=0, amp=0.3, tremorFreq=8, intensity=0.5, dur=1.0;
        var sig, env, mod, noise;
        env   = EnvGen.kr(Env.perc(0.05, dur), doneAction: 2);
        mod   = SinOsc.kr(tremorFreq + LFNoise1.kr(0.5).range(-1, 1));
        mod   = mod + (SinOsc.kr(tremorFreq * 0.5) * 0.3);
        noise = BPF.ar(PinkNoise.ar, 90, 1.5);
        sig   = noise * mod.range(0.3, 1) * intensity;
        sig   = LPF.ar(sig, 200);
        sig   = Limiter.ar(sig * amp * env, 0.8);
        Out.ar(out, sig ! 2);
    }).add;

    // Fluctuation oscillator — tracks EMG instability
    SynthDef(\fluctuationOscillator, {
        arg out=0, gate=1, emg=0.0, fluct=0.0, fatigue=0.0, amp=0.0;
        var env, baseFreq, unstableFreq;
        var oscA, oscB, oscC, noise, clicks;
        var filterFreq, rq, tremolo, pan, sig;
        env      = EnvGen.kr(Env.asr(0.2, 1, 0.5), gate, doneAction: 2);
        baseFreq = emg.linexp(0.001, 1, 50, 420);
        unstableFreq = baseFreq + LFNoise1.kr(fluct.linlin(0, 1, 0.2, 14)).range(
            fluct.linlin(0, 1, 0, -90),
            fluct.linlin(0, 1, 0, 90)
        );
        oscA   = SinOsc.ar(unstableFreq) * 0.35;
        oscB   = Pulse.ar(unstableFreq * 1.5, fluct.linlin(0, 1, 0.48, 0.16)) * 0.18;
        oscC   = Saw.ar(unstableFreq * 0.5) * 0.08;
        noise  = BPF.ar(PinkNoise.ar,
            fluct.linexp(0.001, 1, 350, 5200),
            fluct.linlin(0, 1, 0.8, 0.12)
        ) * fluct.linlin(0, 1, 0.02, 0.28);
        clicks = Decay2.ar(
            Dust.ar(fluct.linlin(0, 1, 0.1, 28)), 0.001, 0.025
        ) * BPF.ar(WhiteNoise.ar, 2500, 0.3) * fluct * 0.25;
        tremolo    = SinOsc.kr(fluct.linlin(0, 1, 0.15, 16)).range(0.45, 1.0);
        sig        = (oscA + oscB + oscC + noise + clicks) * tremolo;
        filterFreq = (
            emg.linexp(0.001, 1, 280, 3600)
            + fluct.linlin(0, 1, 0, 1800)
            - fatigue.linlin(0, 1, 0, 500)
        ).clip(90, 6000);
        rq  = fluct.linlin(0, 1, 0.7, 0.15);
        sig = RLPF.ar(sig, filterFreq, rq);
        sig = HPF.ar(sig, 35);
        sig = LeakDC.ar(sig);
        sig = Limiter.ar(sig * amp * env, 0.8);
        pan = SinOsc.kr(fluct.linlin(0, 1, 0.05, 2.0)).range(-0.35, 0.35);
        Out.ar(out, Pan2.ar(sig, pan));
    }).add;

    // Crackle burst — fires on moderate EMG spikes
    SynthDef(\crackleBurst, {
        arg out=0, density=50, amp=0.4, freqCenter=2000, freqWidth=0.3;
        var sig, env;
        env = EnvGen.kr(Env.perc(0.001, 0.15), doneAction: 2);
        sig = Dust.ar(density) * 0.8;
        sig = BPF.ar(sig, freqCenter, freqWidth);
        sig = Limiter.ar(sig * env * amp, 0.8);
        Out.ar(out, sig ! 2);
    }).add;

    // Deep thump — fires on large EMG spikes
    SynthDef(\muscleThump, {
        arg out=0, freq=80, amp=0.6;
        var sig, env, click;
        env   = EnvGen.kr(Env.perc(0.003, 0.12), doneAction: 2);
        sig   = SinOsc.ar(freq * [1, 2, 3]) * [1, 0.3, 0.1];
        click = HPF.ar(WhiteNoise.ar(0.4), 2000) * Env.perc(0.001, 0.01).kr;
        sig   = (sig.sum + click) * env * amp;
        sig   = Limiter.ar(sig, 0.8);
        Out.ar(out, sig ! 2);
    }).add;

    s.sync;

    // ============================================================
    // SECTION 2: BUSES AND GROUPS
    // ============================================================

    ~synthBus   = Bus.audio(s, 2);

    ~rootGroup  = Group.new(s, \addToHead);
    ~groupClock = Group.new(~rootGroup, \addToHead);
    ~groupTone  = Group.new(~rootGroup, \addToTail);
    ~groupNoise = Group.new(~rootGroup, \addToTail);
    ~groupBody  = Group.new(~rootGroup, \addToTail);
    ~groupFX    = Group.new(~rootGroup, \addToTail);

    s.sync;

    // ============================================================
    // SECTION 3: PRESET TABLE
    // ============================================================

    ~presets = [

        // TIER 0: Standby (index 0)
        ( \tier:0, \label:\standby,
          \clockDensity:0,    \ringFreq:900,  \ringDecay:0.08,
          \freq1:0,   \freq2:0,   \freq3:0,   \fmIndex:0,    \gateRate:0,
          \bpfFreq1:800,  \bpfFreq2:1800, \noiseAmp:0.03, \noiseGated:0,
          \clipThresh:1.0, \dropProb:0 ),

        // TIER 1: Single connection (index 1-5)
        ( \tier:1, \label:\single_350,
          \clockDensity:0.12, \ringFreq:850,  \ringDecay:0.12,
          \freq1:350, \freq2:0,   \freq3:0,   \fmIndex:0,    \gateRate:0,
          \bpfFreq1:700,  \bpfFreq2:1600, \noiseAmp:0.05, \noiseGated:0,
          \clipThresh:0.98, \dropProb:0 ),

        ( \tier:1, \label:\single_440,
          \clockDensity:0.10, \ringFreq:920,  \ringDecay:0.10,
          \freq1:440, \freq2:0,   \freq3:0,   \fmIndex:0,    \gateRate:0,
          \bpfFreq1:800,  \bpfFreq2:1700, \noiseAmp:0.04, \noiseGated:0,
          \clipThresh:0.98, \dropProb:0 ),

        ( \tier:1, \label:\single_480,
          \clockDensity:0.08, \ringFreq:800,  \ringDecay:0.14,
          \freq1:480, \freq2:0,   \freq3:0,   \fmIndex:0,    \gateRate:0,
          \bpfFreq1:750,  \bpfFreq2:1500, \noiseAmp:0.05, \noiseGated:0,
          \clipThresh:0.98, \dropProb:0 ),

        ( \tier:1, \label:\single_600,
          \clockDensity:0.15, \ringFreq:1000, \ringDecay:0.09,
          \freq1:600, \freq2:0,   \freq3:0,   \fmIndex:0,    \gateRate:0,
          \bpfFreq1:900,  \bpfFreq2:1900, \noiseAmp:0.04, \noiseGated:0,
          \clipThresh:0.98, \dropProb:0 ),

        ( \tier:1, \label:\single_350_440,
          \clockDensity:0.18, \ringFreq:880,  \ringDecay:0.11,
          \freq1:350, \freq2:440, \freq3:0,   \fmIndex:0,    \gateRate:0,
          \bpfFreq1:700,  \bpfFreq2:1400, \noiseAmp:0.06, \noiseGated:0,
          \clipThresh:0.97, \dropProb:0 ),

        // TIER 2: Two connections (index 6-12)
        ( \tier:2, \label:\dual_dial,
          \clockDensity:0.25, \ringFreq:870,  \ringDecay:0.10,
          \freq1:350, \freq2:440, \freq3:0,   \fmIndex:0.10, \gateRate:0,
          \bpfFreq1:680,  \bpfFreq2:1500, \noiseAmp:0.07, \noiseGated:0,
          \clipThresh:0.95, \dropProb:0 ),

        ( \tier:2, \label:\dual_busy,
          \clockDensity:0.35, \ringFreq:950,  \ringDecay:0.09,
          \freq1:480, \freq2:620, \freq3:0,   \fmIndex:0.15, \gateRate:0,
          \bpfFreq1:750,  \bpfFreq2:1600, \noiseAmp:0.08, \noiseGated:0,
          \clipThresh:0.93, \dropProb:0 ),

        ( \tier:2, \label:\dual_440_480,
          \clockDensity:0.20, \ringFreq:900,  \ringDecay:0.11,
          \freq1:440, \freq2:480, \freq3:0,   \fmIndex:0.10, \gateRate:0,
          \bpfFreq1:700,  \bpfFreq2:1550, \noiseAmp:0.07, \noiseGated:0,
          \clipThresh:0.94, \dropProb:0 ),

        ( \tier:2, \label:\dual_350_480,
          \clockDensity:0.22, \ringFreq:840,  \ringDecay:0.12,
          \freq1:350, \freq2:480, \freq3:0,   \fmIndex:0.12, \gateRate:0,
          \bpfFreq1:650,  \bpfFreq2:1450, \noiseAmp:0.07, \noiseGated:0,
          \clipThresh:0.94, \dropProb:0 ),

        ( \tier:2, \label:\dual_350_620,
          \clockDensity:0.28, \ringFreq:980,  \ringDecay:0.10,
          \freq1:350, \freq2:620, \freq3:0,   \fmIndex:0.08, \gateRate:0,
          \bpfFreq1:720,  \bpfFreq2:1700, \noiseAmp:0.08, \noiseGated:0,
          \clipThresh:0.93, \dropProb:0 ),

        ( \tier:2, \label:\dual_440_620,
          \clockDensity:0.30, \ringFreq:930,  \ringDecay:0.09,
          \freq1:440, \freq2:620, \freq3:0,   \fmIndex:0.18, \gateRate:0,
          \bpfFreq1:780,  \bpfFreq2:1650, \noiseAmp:0.08, \noiseGated:0,
          \clipThresh:0.92, \dropProb:0 ),

        ( \tier:2, \label:\dual_480_440,
          \clockDensity:0.32, \ringFreq:960,  \ringDecay:0.09,
          \freq1:480, \freq2:440, \freq3:0,   \fmIndex:0.20, \gateRate:0,
          \bpfFreq1:760,  \bpfFreq2:1620, \noiseAmp:0.09, \noiseGated:0,
          \clipThresh:0.91, \dropProb:0 ),

        // TIER 3: Three connections (index 13-18)
        ( \tier:3, \label:\thresh_drone_a,
          \clockDensity:0.40, \ringFreq:900,  \ringDecay:0.09,
          \freq1:350, \freq2:440, \freq3:480, \fmIndex:0.50, \gateRate:0,
          \bpfFreq1:800,  \bpfFreq2:1800, \noiseAmp:0.11, \noiseGated:0,
          \clipThresh:0.85, \dropProb:0.02 ),

        ( \tier:3, \label:\thresh_drone_b,
          \clockDensity:0.35, \ringFreq:860,  \ringDecay:0.10,
          \freq1:480, \freq2:620, \freq3:350, \fmIndex:0.60, \gateRate:0,
          \bpfFreq1:850,  \bpfFreq2:2000, \noiseAmp:0.12, \noiseGated:0,
          \clipThresh:0.83, \dropProb:0.02 ),

        ( \tier:3, \label:\thresh_drone_c,
          \clockDensity:0.45, \ringFreq:940,  \ringDecay:0.08,
          \freq1:440, \freq2:350, \freq3:620, \fmIndex:0.80, \gateRate:0,
          \bpfFreq1:900,  \bpfFreq2:1900, \noiseAmp:0.11, \noiseGated:0,
          \clipThresh:0.82, \dropProb:0.02 ),

        ( \tier:3, \label:\thresh_pulse_a,
          \clockDensity:1.50, \ringFreq:1000, \ringDecay:0.08,
          \freq1:350, \freq2:440, \freq3:480, \fmIndex:0.40, \gateRate:0.5,
          \bpfFreq1:900,  \bpfFreq2:2000, \noiseAmp:0.12, \noiseGated:1,
          \clipThresh:0.80, \dropProb:0.03 ),

        ( \tier:3, \label:\thresh_pulse_b,
          \clockDensity:2.00, \ringFreq:1050, \ringDecay:0.07,
          \freq1:480, \freq2:620, \freq3:440, \fmIndex:0.50, \gateRate:0.8,
          \bpfFreq1:950,  \bpfFreq2:2100, \noiseAmp:0.13, \noiseGated:1,
          \clipThresh:0.78, \dropProb:0.04 ),

        ( \tier:3, \label:\thresh_pulse_c,
          \clockDensity:1.80, \ringFreq:980,  \ringDecay:0.08,
          \freq1:440, \freq2:350, \freq3:620, \fmIndex:0.60, \gateRate:1.2,
          \bpfFreq1:1000, \bpfFreq2:2200, \noiseAmp:0.14, \noiseGated:1,
          \clipThresh:0.76, \dropProb:0.04 ),

        // TIER 4: Four connections (index 19-22)
        ( \tier:4, \label:\industrial_straight,
          \clockDensity:3.00, \ringFreq:1100, \ringDecay:0.07,
          \freq1:350, \freq2:480, \freq3:620, \fmIndex:0.30, \gateRate:2.0,
          \bpfFreq1:1100, \bpfFreq2:2400, \noiseAmp:0.14, \noiseGated:1,
          \clipThresh:0.70, \dropProb:0.05 ),

        ( \tier:4, \label:\industrial_dotted,
          \clockDensity:4.00, \ringFreq:1150, \ringDecay:0.065,
          \freq1:440, \freq2:620, \freq3:350, \fmIndex:0.35, \gateRate:1.5,
          \bpfFreq1:1200, \bpfFreq2:2500, \noiseAmp:0.16, \noiseGated:1,
          \clipThresh:0.68, \dropProb:0.06 ),

        ( \tier:4, \label:\industrial_irregular,
          \clockDensity:3.50, \ringFreq:1050, \ringDecay:0.08,
          \freq1:480, \freq2:350, \freq3:440, \fmIndex:0.40, \gateRate:3.0,
          \bpfFreq1:1050, \bpfFreq2:2300, \noiseAmp:0.14, \noiseGated:1,
          \clipThresh:0.65, \dropProb:0.07 ),

        ( \tier:4, \label:\industrial_doublepulse,
          \clockDensity:5.00, \ringFreq:1200, \ringDecay:0.06,
          \freq1:620, \freq2:480, \freq3:350, \fmIndex:0.45, \gateRate:2.5,
          \bpfFreq1:1300, \bpfFreq2:2600, \noiseAmp:0.17, \noiseGated:1,
          \clipThresh:0.60, \dropProb:0.08 ),

        // TIER 5: Five-six connections (index 23-25)
        ( \tier:5, \label:\congested_5,
          \clockDensity:8.00, \ringFreq:1300, \ringDecay:0.05,
          \freq1:350, \freq2:480, \freq3:620, \fmIndex:1.00, \gateRate:4.0,
          \bpfFreq1:1400, \bpfFreq2:2800, \noiseAmp:0.22, \noiseGated:1,
          \clipThresh:0.50, \dropProb:0.12 ),

        ( \tier:5, \label:\congested_6_sym,
          \clockDensity:11.0, \ringFreq:1400, \ringDecay:0.045,
          \freq1:440, \freq2:620, \freq3:480, \fmIndex:1.50, \gateRate:5.0,
          \bpfFreq1:1500, \bpfFreq2:3000, \noiseAmp:0.27, \noiseGated:1,
          \clipThresh:0.40, \dropProb:0.18 ),

        ( \tier:5, \label:\congested_6_asym,
          \clockDensity:9.00, \ringFreq:1350, \ringDecay:0.05,
          \freq1:620, \freq2:350, \freq3:440, \fmIndex:2.00, \gateRate:6.0,
          \bpfFreq1:1600, \bpfFreq2:3200, \noiseAmp:0.30, \noiseGated:1,
          \clipThresh:0.35, \dropProb:0.20 ),
    ];

    // ============================================================
    // SECTION 4: STATE MACHINE
    // ============================================================

    ~currentStateIndex = -1;
    ~currentSynths     = IdentityDictionary.new;

    // EMG / body state
    ~emgStress   = 0.0;
    ~lastEMGRaw  = 0.0;
    ~smoothedEMG = 0.0;
    ~fluctuation = 0.0;
    ~fatigue     = 0.0;
    ~belief      = 0.0;
    ~lastState   = "COMPOSURE";

    // Performance flags
    ~useBursts          = true;
    ~useDiagnosticStates = true;
    ~useOscillatorMode  = false;

    ~stateIndexFor = { |connCount, topoIndex|
        case
            { connCount == 0 } { 0 }
            { connCount == 1 } { 1  + (topoIndex % 5) }
            { connCount == 2 } { 6  + (topoIndex % 7) }
            { connCount == 3 } { 13 + (topoIndex % 6) }
            { connCount == 4 } { 19 + (topoIndex % 4) }
            { connCount >= 5 } { 23 + (topoIndex % 3) };
    };

    ~applyPreset = { |presetIdx|
        var p          = ~presets[presetIdx];
        var stress     = ~emgStress;
        var crossTime  = 0;
        var jitter     = stress.linlin(0, 1, 0.01, 0.08);
        var noiseBoost = stress.linlin(0, 1, 1.0,  1.4);
        var clipMod    = stress.linlin(0, 1, 0,    0.15);
        var dropExtra  = stress.linlin(0, 1, 0,    p[\dropProb] * 2);

        [\clock, \tone, \noise, \hiss].do { |key|
            if(~currentSynths[key].notNil) {
                ~currentSynths[key].set(\gate, 0);
                ~currentSynths[key] = nil;
            };
        };

        if(~currentSynths[\sat].notNil) {
            ~currentSynths[\sat].set(\amp, 0.0);
        };

        {
            crossTime.wait;

            if(p[\tier] == 0) {
                // No cables — full silence
                if(~currentSynths[\sat].notNil) {
                    ~currentSynths[\sat].set(
                        \amp, 0.0, \clipThresh, 1.0, \dropProb, 0.0
                    );
                };
                // Silence body layers too
                if(~currentSynths[\muscle].notNil) {
                    ~currentSynths[\muscle].set(\amp, 0.0);
                };
                if(~currentSynths[\fatigueSynth].notNil) {
                    ~currentSynths[\fatigueSynth].set(\amp, 0.0);
                };
                if(~currentSynths[\fluctOsc].notNil) {
                    ~currentSynths[\fluctOsc].set(\amp, 0.0);
                };
            } {
                // Cables connected — restore exchange sound
                if(~currentSynths[\sat].notNil) {
                    ~currentSynths[\sat].set(\amp, 0.6);
                };

                if(p[\clockDensity] > 0) {
                    ~currentSynths[\clock] = Synth(\relayClick, [
                        \out,       ~synthBus,
                        \density,   p[\clockDensity],
                        \ringFreq,  p[\ringFreq],
                        \ringDecay, p[\ringDecay],
                        \jitter,    jitter,
                        \amp,       0.25,
                        \gate,      1
                    ], ~groupClock);
                };

                ~currentSynths[\tone] = Synth(\teleTone, [
                    \out,      ~synthBus,
                    \freq1,    p[\freq1],
                    \freq2,    p[\freq2],
                    \freq3,    p[\freq3],
                    \fmIndex,  p[\fmIndex],
                    \fmRatio,  1.0,
                    \gateRate, p[\gateRate],
                    \amp,      0.18,
                    \gate,     1
                ], ~groupTone);

                ~currentSynths[\noise] = Synth(\crosstalk, [
                    \out,      ~synthBus,
                    \bpfFreq1, p[\bpfFreq1],
                    \bpfFreq2, p[\bpfFreq2],
                    \bpfQ,     8,
                    \noiseAmp, p[\noiseAmp] * noiseBoost,
                    \gated,    p[\noiseGated],
                    \gateRate, (p[\clockDensity] * 0.7 + 0.1),
                    \amp,      0.50,
                    \gate,     1
                ], ~groupNoise);

                if(~currentSynths[\sat].notNil) {
                    ~currentSynths[\sat].set(
                        \clipThresh, (p[\clipThresh] - clipMod).max(0.2),
                        \dropProb,   p[\dropProb] + dropExtra
                    );
                };
            };

        }.fork;

        ~currentStateIndex = presetIdx;
        ("-> preset " ++ presetIdx ++ " | " ++ p[\label] ++ " | tier " ++ p[\tier]).postln;
    };

    // ============================================================
    // SECTION 5: OSC RECEIVERS
    // ============================================================

    OSCdef(\patchState, { |msg|
        var conn = msg[1].asInteger;
        var topo = msg[2].asInteger;
        var idx  = ~stateIndexFor.(conn, topo);
        ~applyPreset.(idx);
    }, '/patch/state');

    OSCdef(\emgFromTD, { |msg|
        var raw       = msg[1].asFloat;
        var val       = if(raw > 1.0, { raw / 1023.0 }, { raw }).clip(0.0, 1.0);
        var delta     = (raw - ~lastEMGRaw).abs;
        var deltaNorm = if(raw > 1.0, { delta / 1023.0 }, { delta }).clip(0, 1);
        var state;

        ~lastEMGRaw  = raw;
        ~emgStress   = val;

        // Smooth EMG
        ~smoothedEMG = (~smoothedEMG * 0.88) + (val * 0.12);

        // Fluctuation — signal instability
        ~fluctuation = (~fluctuation * 0.82) + (deltaNorm * 0.18);
        ~fluctuation = (~fluctuation * 4.5).clip(0, 1);

        // Fatigue — accumulates over session
        ~fatigue = (
            ~fatigue
            + 0.0015
            + (~smoothedEMG * 0.003)
            + (~fluctuation * 0.005)
        ).clip(0, 1);

        // Belief — lagged interpretation
        ~belief = ((~belief * 0.92) + (~smoothedEMG * 0.08)).clip(0, 1);

        ("OSC /return: " ++ raw.round(1)
            ++ " | emg: " ++ ~smoothedEMG.round(0.01)
            ++ " | fluct: " ++ ~fluctuation.round(0.01)
            ++ " | fatigue: " ++ ~fatigue.round(0.01)
            ++ " | belief: " ++ ~belief.round(0.01)
        ).postln;

        // Only modulate exchange layers when cables connected
        if(~currentStateIndex > 0) {

            if(~currentSynths[\sat].notNil) {
                var p = ~presets[~currentStateIndex];
                ~currentSynths[\sat].set(
                    \clipThresh, (p[\clipThresh] - val.linlin(0,1,0,0.15)).max(0.2),
                    \dropProb,   p[\dropProb] + val.linlin(0,1,0, p[\dropProb] * 2)
                );
            };

            if(~currentSynths[\noise].notNil) {
                var p = ~presets[~currentStateIndex];
                ~currentSynths[\noise].set(
                    \noiseAmp, p[\noiseAmp] * val.linlin(0,1,1.0,1.4)
                );
            };

        };

        // Continuous muscle contraction — always responds to EMG
        if(~currentSynths[\muscle].notNil) {
            ~currentSynths[\muscle].set(
                \tension, (~belief * 0.8 + 0.1).clip(0, 1),
                \tremor,  ~fluctuation.linlin(0, 1, 4, 16),
                \amp,     ~belief.linlin(0, 1, 0.05, 0.25)
            );
        };

        // Fatigue rumble
        if(~currentSynths[\fatigueSynth].notNil) {
            ~currentSynths[\fatigueSynth].set(
                \fatigueLevel, ~fatigue,
                \amp,          ~fatigue.linlin(0, 1, 0.0, 0.18)
            );
        };

        // Fluctuation oscillator
        if(~currentSynths[\fluctOsc].notNil) {
            var oscAmp = if(~useOscillatorMode) {
                ~fluctuation.linlin(0, 1, 0.02, 0.18)
            } { 0.0 };
            ~currentSynths[\fluctOsc].set(
                \emg,     ~smoothedEMG,
                \fluct,   ~fluctuation,
                \fatigue, ~fatigue,
                \amp,     oscAmp
            );
        };

        // Variance-triggered bursts
        if(~useBursts) {
            if(deltaNorm > 0.025) {
                Synth(\crackleBurst, [
                    \out,        0,
                    \density,    deltaNorm.linexp(0.025, 0.6, 40, 400).clip(40, 400),
                    \freqCenter, ~smoothedEMG.linexp(0.001, 1, 300, 5000),
                    \freqWidth,  ~fluctuation.linlin(0, 1, 0.45, 0.12),
                    \amp,        ~fluctuation.linlin(0, 1, 0.03, 0.20)
                ]);
            };

            if(deltaNorm > 0.08) {
                Synth(\muscleThump, [
                    \out,  0,
                    \freq, ~smoothedEMG.linexp(0.001, 1, 55, 130),
                    \amp,  ~fluctuation.linlin(0, 1, 0.06, 0.28)
                ]);
                "EMG spike -> thump".postln;
            };
        };

        // Diagnostic state machine — drives twitches and tremor bursts
        if(~useDiagnosticStates) {
            state = case
                { ~fatigue < 0.18 }     { "COMPOSURE" }
                { ~fluctuation > 0.75 } { "UNSTABLE SIGNAL" }
                { ~belief < 0.35 }      { "BRACING" }
                { ~belief < 0.55 }      { "SUPPRESSED TREMOR" }
                { ~belief < 0.75 }      { "FALSE RECOVERY" }
                { ~fatigue > 0.75 }     { "VOLUNTARY COLLAPSE" }
                {                         "RESIDUAL EFFORT" };

            if(state != ~lastState) {
                ("DIAGNOSTIC STATE: " ++ state).postln;
                ~lastState = state;

                Synth(\muscleTwitch, [
                    \out,      0,
                    \amp,      ~belief.linlin(0, 1, 0.12, 0.45),
                    \baseFreq, ~fatigue.linlin(0, 1, 95, 55)
                ]);

                if((~belief > 0.55) or: { ~fluctuation > 0.65 }) {
                    Synth(\tremor, [
                        \out,        0,
                        \amp,        max(
                            ~belief.linlin(0, 1, 0.06, 0.25),
                            ~fluctuation.linlin(0, 1, 0.06, 0.28)
                        ),
                        \tremorFreq, ~fluctuation.linlin(0, 1, 5, 14),
                        \intensity,  max(~belief, ~fluctuation),
                        \dur,        1.2
                    ]);
                };
            };
        };

    }, '/return');

    // ============================================================
    // SECTION 6: STARTUP
    // ============================================================

    s.sync;

    ~emgStress   = 0.0;
    ~lastEMGRaw  = 0.0;
    ~smoothedEMG = 0.0;
    ~fluctuation = 0.0;
    ~fatigue     = 0.0;
    ~belief      = 0.0;
    ~lastState   = "COMPOSURE";

    // Saturation — starts muted
    ~currentSynths[\sat] = Synth(\saturation, [
        \inBus,      ~synthBus,
        \out,        0,
        \clipThresh, 1.0,
        \dropProb,   0.0,
        \amp,        0.0
    ], ~groupFX);

    // Continuous muscle contraction — always running, starts silent
    ~currentSynths[\muscle] = Synth(\muscleContraction, [
        \out,     0,
        \tension, 0.2,
        \tremor,  6,
        \amp,     0.0,
        \gate,    1
    ], ~groupBody);

    // Fatigue rumble — always running, starts silent
    ~currentSynths[\fatigueSynth] = Synth(\muscleFatigue, [
        \out,          0,
        \fatigueLevel, 0.0,
        \amp,          0.0,
        \gate,         1
    ], ~groupBody);

    // Fluctuation oscillator — always running, starts silent
    ~currentSynths[\fluctOsc] = Synth(\fluctuationOscillator, [
        \out,     0,
        \emg,     0.0,
        \fluct,   0.0,
        \fatigue, 0.0,
        \amp,     0.0,
        \gate,    1
    ], ~groupBody);

    ~applyPreset.(0);

    // ============================================================
    // MANUAL CONTROLS
    // ============================================================

    // Reset body state between participants
    ~resetBodyState = {
        ~emgStress   = 0.0;
        ~lastEMGRaw  = 0.0;
        ~smoothedEMG = 0.0;
        ~fluctuation = 0.0;
        ~fatigue     = 0.0;
        ~belief      = 0.0;
        ~lastState   = "COMPOSURE";
        if(~currentSynths[\muscle].notNil) {
            ~currentSynths[\muscle].set(\amp, 0.0);
        };
        if(~currentSynths[\fatigueSynth].notNil) {
            ~currentSynths[\fatigueSynth].set(\fatigueLevel, 0.0, \amp, 0.0);
        };
        if(~currentSynths[\fluctOsc].notNil) {
            ~currentSynths[\fluctOsc].set(\emg, 0.0, \fluct, 0.0, \fatigue, 0.0, \amp, 0.0);
        };
        "Body state reset.".postln;
    };

    // Toggle oscillator mode on/off
    ~oscillatorOn = {
        ~useOscillatorMode = true;
        "Fluctuation oscillator ON".postln;
    };

    ~oscillatorOff = {
        ~useOscillatorMode = false;
        if(~currentSynths[\fluctOsc].notNil) {
            ~currentSynths[\fluctOsc].set(\amp, 0.0);
        };
        "Fluctuation oscillator OFF".postln;
    };

    // Toggle bursts on/off
    ~burstsOn  = { ~useBursts = true;  "Bursts ON".postln; };
    ~burstsOff = { ~useBursts = false; "Bursts OFF".postln; };

    // Toggle diagnostic states on/off
    ~diagnosticOn  = { ~useDiagnosticStates = true;  "Diagnostic states ON".postln; };
    ~diagnosticOff = { ~useDiagnosticStates = false; "Diagnostic states OFF".postln; };

    "".postln;
    "============================================".postln;
    "  Telephone Exchange Instrument v3.2 ready.".postln;
    ("  synthBus index: " ++ ~synthBus.index).postln;
    "  Arduino  -> serial /dev/tty.usbserial-130 @ 115200".postln;
    "  EMG/TD   -> OSC /return @ 57120".postln;
    "  Patches  -> OSC /patch/state @ 57120".postln;
    "============================================".postln;
    "  Run Section 7 block to open serial bridge.".postln;
    "  ~resetBodyState.() between participants.".postln;
    "  ~oscillatorOn.() to enable fluctuation hum.".postln;
    "  ~burstsOff.() to silence spike events.".postln;
    "  ~diagnosticOff.() to silence state labels.".postln;
    "  OSCFunc.trace(false) to silence post flood.".postln;
    "============================================".postln;

}); // end waitForBoot
)


// ============================================================
// SECTION 7: SERIAL BRIDGE
// Evaluate this block SEPARATELY after "ready." appears.
// ============================================================

(
if(~serial.notNil)        { ~serial.close;       ~serial = nil };
if(~serialRoutine.notNil) { ~serialRoutine.stop; ~serialRoutine = nil };

~serial = SerialPort("/dev/tty.usbserial-130", 115200, crtscts: false);

~serialRoutine = Routine({
    var line = "";
    var byte;
    "Serial bridge open: /dev/tty.usbserial-130 @ 115200".postln;
    loop {
        byte = ~serial.read;
        case
            { byte == 10 } {
                if(line.size > 0) {
                    var parts   = line.split($ );
                    var connStr = parts.detect({ |p| p.beginsWith("CONN:") });
                    var topoStr = parts.detect({ |p| p.beginsWith("TOPO:") });
                    if(connStr.notNil and: { topoStr.notNil }) {
                        var conn = connStr.drop(5).asInteger;
                        var topo = topoStr.drop(5).asInteger;
                        NetAddr("127.0.0.1", 57120).sendMsg('/patch/state', conn, topo);
                        ("Serial -> CONN=" ++ conn ++ " TOPO=" ++ topo).postln;
                    };
                    if(parts[0] == "PATCH" or: { parts[0] == "UNPATCH" }) {
                        ("Patch event: " ++ line).postln;
                    };
                };
                line = "";
            }
            { byte == 13 } { }
            { true }        { line = line ++ byte.asAscii };
    };
}).play;
)

// Stop serial bridge:
// ~serialRoutine.stop; ~serial.close;

// Silence OSC trace flood:
// OSCFunc.trace(false);


// ============================================================
// SECTION 8: TEST CONTROLS
// ============================================================

{ SinOsc.ar(440, 0, 0.2).dup }.play;

~applyPreset.(0);
~applyPreset.(1);
~applyPreset.(6);
~applyPreset.(13);
~applyPreset.(16);
~applyPreset.(19);
~applyPreset.(23);
~applyPreset.(25);

NetAddr("127.0.0.1", 57120).sendMsg('/patch/state', 0, 0);
NetAddr("127.0.0.1", 57120).sendMsg('/patch/state', 2, 20);
NetAddr("127.0.0.1", 57120).sendMsg('/patch/state', 4, 40);
NetAddr("127.0.0.1", 57120).sendMsg('/patch/state', 6, 60);

NetAddr("127.0.0.1", 57120).sendMsg('/return', 0.0);
NetAddr("127.0.0.1", 57120).sendMsg('/return', 512.0);
NetAddr("127.0.0.1", 57120).sendMsg('/return', 1023.0);
NetAddr("127.0.0.1", 57120).sendMsg('/return', 0.0);

// Stress sweep
(
Routine({
    101.do { |i|
        NetAddr("127.0.0.1", 57120).sendMsg('/return', i * 10.23);
        0.1.wait;
    };
}).play;
)

// Performance controls
~resetBodyState.();
~oscillatorOn.();
~oscillatorOff.();
~burstsOn.();
~burstsOff.();
~diagnosticOn.();
~diagnosticOff.();

~synthBus.index.postln;
~currentStateIndex.postln;
~presets[~currentStateIndex][\label].postln;
~emgStress.postln;
~fatigue.postln;
~fluctuation.postln;
~currentSynths.postln;

// Hard stop
// s.freeAll;

// Full cleanup
// OSCdef.freeAll; s.freeAll;