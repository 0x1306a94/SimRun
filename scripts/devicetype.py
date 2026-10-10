#!/usr/bin/env python3
# devicetype.py <RuntimeRoot> [--list] — the simulated device for simrun.sh: prints the variables of the device type an
# app on that runtime runs as (SIMULATOR_CAPABILITIES, SIMULATOR_MODEL_IDENTIFIER, SIMULATOR_MAINSCREEN_*, ...) as
# KEY=VALUE lines; with --list, the device types the runtime supports instead (the default marked with *).
# Same choice as SimRun (src/host/simrund/environment.m): SIMRUN_DEVICE (identifier or name) if the runtime supports it,
# else the newest supported iPhone with a 1206x2622 screen (a Pro, preferably), else the newest supported iPhone, else
# the first supported device type. The supported ones are those simctl lists for the runtime (`simctl list runtimes
# --json`, read from stdin if it is piped in); without simctl, the installed ones whose runtime version range includes it.
import json, os, plistlib, subprocess, sys

DEVICE_TYPES = "/Library/Developer/CoreSimulator/Profiles/DeviceTypes"


def load(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except Exception:
        return None


def version_key(v):
    return [int(p) if p.isdigit() else 0 for p in str(v).split(".")]


def device_type(path):
    res = os.path.join(path, "Contents/Resources")
    caps = (load(os.path.join(res, "capabilities.plist")) or {}).get("capabilities")
    profile = load(os.path.join(res, "profile.plist"))
    info = load(os.path.join(path, "Contents/Info.plist")) or {}
    if not isinstance(caps, dict) or not isinstance(profile, dict):
        return None
    screen = caps.get("ScreenDimensionsCapability") or {}
    family = {"phone": "iPhone", "pad": "iPad"}.get(caps.get("idiom"))
    w, h, scale = screen.get("main-screen-width"), screen.get("main-screen-height"), screen.get("main-screen-scale")
    if not family or not w or not h or not scale:
        return None
    env = {k: v for k, v in (profile.get("environment") or {}).items() if isinstance(k, str) and isinstance(v, str)}
    env["SIMULATOR_CAPABILITIES"] = os.path.join(res, "capabilities.plist")
    if profile.get("modelIdentifier"):
        env["SIMULATOR_MODEL_IDENTIFIER"] = profile["modelIdentifier"]
    if profile.get("productClass"):
        env["SIMULATOR_PRODUCT_CLASS"] = profile["productClass"]
    env["SIMULATOR_MAINSCREEN_WIDTH"] = "%d" % w
    env["SIMULATOR_MAINSCREEN_HEIGHT"] = "%d" % h
    env["SIMULATOR_MAINSCREEN_SCALE"] = "%f" % scale
    env["SIMULATOR_MAINSCREEN_PITCH"] = "%f" % (screen.get("main-screen-pitch") or 460)
    return {
        "identifier": info.get("CFBundleIdentifier") or os.path.basename(path),
        "name": info.get("CFBundleName") or os.path.splitext(os.path.basename(path))[0],
        "family": family, "width": w, "height": h, "scale": scale,
        "min": profile.get("minRuntimeVersion") or "0", "env": env,
    }


def supported(root, version, build):
    data = sys.stdin.read() if not sys.stdin.isatty() else ""
    if not data.strip():
        env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "SIMULATOR_"))}
        try:
            data = subprocess.run(["/usr/bin/xcrun", "simctl", "list", "runtimes", "--json"], env=env,
                                  capture_output=True, text=True, timeout=5).stdout
        except Exception:
            data = ""
    try:
        runtimes = json.loads(data)["runtimes"]
    except Exception:
        runtimes = None
    if runtimes is not None:
        for r in runtimes:
            if r.get("runtimeRoot") == root or (build and r.get("buildversion") == build):
                return [d["bundlePath"] for d in r.get("supportedDeviceTypes", []) if d.get("bundlePath")], False
    paths = []
    for d in sorted(os.listdir(DEVICE_TYPES)) if os.path.isdir(DEVICE_TYPES) else []:
        if not d.endswith(".simdevicetype"):
            continue
        p = load(os.path.join(DEVICE_TYPES, d, "Contents/Resources/profile.plist")) or {}
        if version_key(p.get("minRuntimeVersion") or "0") > version_key(version):
            continue
        if p.get("maxRuntimeVersion") and version_key(p["maxRuntimeVersion"]) < version_key(version):
            continue
        paths.append(os.path.join(DEVICE_TYPES, d))
    return paths, True


def main():
    args = [a for a in sys.argv[1:] if a != "--list"]
    if len(args) != 1:
        sys.exit("usage: devicetype.py <RuntimeRoot> [--list]")
    root = args[0]
    sv = load(os.path.join(root, "System/Library/CoreServices/SystemVersion.plist")) or {}
    paths, scanned = supported(root, sv.get("ProductVersion", "0"), sv.get("ProductBuildVersion"))
    types = [t for t in map(device_type, paths) if t]
    if scanned:   # simctl lists the newest first
        types.sort(key=lambda t: t["name"])
        types.sort(key=lambda t: version_key(t["min"]), reverse=True)
    types = [t for t in types if t["family"] == "iPhone"] + [t for t in types if t["family"] != "iPhone"]

    want = os.environ.get("SIMRUN_DEVICE")
    default = next((t for t in types if want and want in (t["identifier"], t["name"])), None)
    if not default:
        best = None
        for t in types:
            if t["family"] != "iPhone" or (t["width"], t["height"]) != (1206, 2622):
                continue
            if not best or version_key(t["min"]) > version_key(best["min"]) or \
               (version_key(t["min"]) == version_key(best["min"]) and t["name"].endswith(" Pro") and not best["name"].endswith(" Pro")):
                best = t
        default = best or next((t for t in types if t["family"] == "iPhone"), None) or (types[0] if types else None)

    if "--list" in sys.argv:
        for t in types:
            print("%s %-28s %-55s %gx%g @%gx" % ("*" if t is default else " ", t["name"], t["identifier"],
                                                t["width"] / t["scale"], t["height"] / t["scale"], t["scale"]))
        return
    if default:
        for k, v in default["env"].items():
            print("%s=%s" % (k, v))


main()
