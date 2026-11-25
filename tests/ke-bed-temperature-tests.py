#!/usr/bin/env python3
"""1.0.5: the KE heated bed reads like stock again.

machine.cfg's [adc_temperature nebulaos_ke_bed] must reproduce stock
Creality's KE bed conversion (EPCOS 100K B57560G104F + temp_offset_flag)
through upstream Klipper's own linear-resistance interpolation, and must not
weaken the bed's hard temperature limit.

  - the section equals the generator's output (no hand edits, no drift)
  - Klipper's conversion of every ADC reading over raw -5..135 C differs from
    Creality's algorithm by at most 0.1 C (target; measured ~0.03 C)
  - the issue's reference points (25..120 C raw) match to 0.01 C
  - the MCU-side limit derived from max_temp lies at or below 120 C raw EPCOS
    (the limit before 1.0.5); the corrected max_temp is at least 100 C
  - [heater_bed] uses the sensor; the hotend sensor is unchanged

KLIPPER_DIR=<klippy dir> additionally runs the same checks with upstream
Klipper's own adc_temperature/thermistor modules (otherwise their maths is
mirrored here and in the generator).
Usage: python3 tests/ke-bed-temperature-tests.py
"""
import bisect, configparser, importlib.util, os, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CFG = os.path.join(ROOT, "scripts/build/overlay/etc/nebulaos/klipper/machine.cfg")
GEN = os.path.join(ROOT, "tools/klipper-config/ke-bed-temperature-table.py")
spec = importlib.util.spec_from_file_location("ke_bed_gen", GEN)
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS: " if ok else "FAIL: ") + name + (" (%s)" % detail if detail else ""))
    if not ok:
        fails += 1

text = open(CFG).read()
cp = configparser.RawConfigParser(strict=False, inline_comment_prefixes=("#",))
cp.read_string(text)
SEC = gen.SECTION

# --- the section is exactly the generator's output ------------------------
start = text.find("[%s]" % SEC)
end = text.find("\n[", start + 1)
check("section present", start >= 0)
check("section equals generator output (regenerate, never hand-edit)",
      text[start:end + 1].rstrip("\n") + "\n" == gen.section_text())
check("section comes before [heater_bed]", 0 <= start < text.find("[heater_bed]"))

samples = []
i = 1
while cp.has_option(SEC, "temperature%d" % i):
    samples.append((float(cp.get(SEC, "temperature%d" % i)),
                    float(cp.get(SEC, "resistance%d" % i))))
    i += 1
check("table has 50+ points", len(samples) >= 50, "%d" % len(samples))

# --- upstream Klipper's LinearInterpolate / LinearResistance (mirrored) ----
class LinearInterpolate:
    def __init__(self, samples):
        self.keys, self.slopes = [], []
        last_key = last_value = None
        for key, value in sorted(samples):
            if last_key is None:
                last_key, last_value = key, value
                continue
            if key <= last_key:
                raise ValueError("duplicate value")
            gain = (value - last_value) / (key - last_key)
            offset = last_value - last_key * gain
            if self.slopes and self.slopes[-1] == (gain, offset):
                continue
            last_value, last_key = value, key
            self.keys.append(key)
            self.slopes.append((gain, offset))
        self.keys.append(9999999999999.)
        self.slopes.append(self.slopes[-1])
    def interpolate(self, key):
        gain, offset = self.slopes[bisect.bisect(self.keys, key)]
        return key * gain + offset
    def reverse_interpolate(self, value):
        values = [key * gain + offset for key, (gain, offset) in zip(self.keys, self.slopes)]
        if values[0] < values[-2]:
            valid = [i for i in range(len(values)) if values[i] >= value]
        else:
            valid = [i for i in range(len(values)) if values[i] <= value]
        gain, offset = self.slopes[min(valid + [len(values) - 1])]
        return (value - offset) / gain

class LinearResistance:
    def __init__(self, samples, pullup=4700.):
        self.pullup = pullup
        self.li = LinearInterpolate([(r, t) for t, r in samples])
    def calc_temp(self, adc):
        adc = max(.00001, min(.99999, adc))
        return self.li.interpolate(self.pullup * adc / (1.0 - adc))
    def calc_adc(self, temp):
        r = self.li.reverse_interpolate(temp)
        return r / (self.pullup + r)

def epcos_adc(t, pullup=4700.):
    r = gen.r_epcos(t)
    return r / (pullup + r)

def epcos_temp(adc, pullup=4700.):
    adc = max(.00001, min(.99999, adc))
    return gen.t_epcos(pullup * adc / (1.0 - adc))

def run(label, conv, ep_adc, ep_temp):
    worst, at = 0., None
    t = -5.
    while t <= 135.:
        adc = ep_adc(t)
        d = abs(conv.calc_temp(adc) - gen.creality(ep_temp(adc)))
        if d > worst:
            worst, at = d, t
        t += 0.05
    check("%s: max deviation from Creality <= 0.1 C over raw -5..135 C" % label,
          worst <= 0.1, "%.4f C at raw %.2f" % (worst, at))
    ref = {25: 25., 40: 40., 50: 48.33, 60: 57.41, 70: 66.67, 80: 75.93,
           90: 84.94, 100: 93.76, 110: 102.59, 120: 111.41}
    bad = ["%d->%.3f" % (r, conv.calc_temp(ep_adc(r))) for r, c in ref.items()
           if abs(conv.calc_temp(ep_adc(r)) - c) > 0.01]
    check("%s: reference points 25..120 C raw" % label, not bad, ", ".join(bad))
    # The MCU range check uses calc_adc(max_temp): its raw EPCOS equivalent
    max_temp = float(cp.get("heater_bed", "max_temp"))
    raw_limit = ep_temp(conv.calc_adc(max_temp))
    check("%s: hard limit not weakened (max_temp %.1f = raw %.2f C <= 120)"
          % (label, max_temp, raw_limit), raw_limit <= 120.0 + 1e-6)
    check("%s: corrected max_temp still allows 100 C beds" % label, max_temp >= 100.)
    lo = ep_temp(conv.calc_adc(float(cp.get("heater_bed", "min_temp"))))
    check("%s: min_temp unchanged on the raw scale (0 C)" % label, abs(lo) < 0.1, "%.3f" % lo)

run("mirrored Klipper", LinearResistance(samples), epcos_adc, epcos_temp)

check("[heater_bed] sensor_type is %s" % SEC.split()[1],
      cp.get("heater_bed", "sensor_type").strip() == SEC.split()[1])
check("hotend sensor unchanged",
      cp.get("extruder", "sensor_type").strip() == "EPCOS 100K B57560G104F")
check("generator self-check: Creality corners continuous",
      all(abs(gen.creality(v - 1e-9) - gen.creality(v)) < 1e-6 for v in gen.BREAKPOINTS))

kd = os.environ.get("KLIPPER_DIR")
if kd:
    sys.path.insert(0, kd)
    from extras import adc_temperature, thermistor
    class Cfg:
        def __init__(self, d): self.d = d
        def getfloat(self, k, default=None, **kw): return self.d.get(k, default)
        def get_name(self): return SEC
        def error(self, m): return Exception(m)
    ep = thermistor.Thermistor(4700., 0.)
    ep.setup_coefficients(25., 100000., 150., 1641.9, 250., 226.15)
    run("upstream Klipper", adc_temperature.LinearResistance(Cfg({}), samples),
        ep.calc_adc, ep.calc_temp)
else:
    print("NOTE: KLIPPER_DIR not set - upstream Klipper cross-check skipped")

print("\nke-bed-temperature: %s" % ("PASS" if fails == 0 else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
