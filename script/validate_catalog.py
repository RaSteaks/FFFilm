#!/usr/bin/env python3
"""Structural validation for FFFilm/Catalog.json.

Checks the invariants the Swift catalog decoder and CalculatorEngine rely on:
unique ids, rate-table keys that resolve to real camera/codec/resolution triples,
finite positive rates, and sensor geometry that stays inside the published sensor.
Run from the repository root: python3 script/validate_catalog.py
"""
import json
import math
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "FFFilm" / "Catalog.json"

FRAME_RATES: set[float] = set()


def fail(errors: list[str], message: str) -> None:
    errors.append(message)


def main() -> int:
    data = json.loads(CATALOG.read_text())
    errors: list[str] = []
    FRAME_RATES.update(data["frameRates"])

    camera_ids = [c["id"] for c in data["cameras"]]
    if len(camera_ids) != len(set(camera_ids)):
        fail(errors, "duplicate camera ids")
    codec_ids = {c["id"] for c in data["codecs"]}
    if len(codec_ids) != len(data["codecs"]):
        fail(errors, "duplicate codec ids")

    cameras = {c["id"]: c for c in data["cameras"]}
    codecs = {c["id"]: c for c in data["codecs"]}

    # Resolution ids must be unique across the whole catalog: a stale selection
    # carries a resolutionId across cameras, and lookup falls back per mode.
    resolution_owner: dict[str, str] = {}
    published_codec_ids = {cid for cid, c in codecs.items() if c["rateModel"] == "published-table"}

    for camera in data["cameras"]:
        cid = camera["id"]
        if camera["sensorWidthMm"] <= 0 or camera["sensorHeightMm"] <= 0:
            if camera.get("sourceType") != "prores":
                fail(errors, f"{cid}: non-positive sensor dimensions")
        if camera.get("nativeWidth", 0) <= 0 or camera.get("nativeHeight", 0) <= 0:
            if camera.get("sourceType") != "prores":
                fail(errors, f"{cid}: non-positive native pixels")
        if not camera.get("modes"):
            fail(errors, f"{cid}: no modes")
        for mode in camera.get("modes", []):
            if not mode["resolutions"]:
                fail(errors, f"{cid}/{mode['id']}: no resolutions")
            for res in mode["resolutions"]:
                rid = res["id"]
                if rid in resolution_owner and resolution_owner[rid] != cid:
                    fail(errors, f"resolution id '{rid}' used by {resolution_owner[rid]} and {cid}")
                resolution_owner[rid] = cid
                if res["width"] <= 0 or res["height"] <= 0:
                    fail(errors, f"{cid}/{mode['id']}/{rid}: non-positive pixels")
                if res.get("activeWidthMm") is not None and res["activeWidthMm"] > camera["sensorWidthMm"] + 1e-9:
                    fail(errors, f"{cid}/{rid}: active width exceeds sensor")
                if res.get("activeHeightMm") is not None and res["activeHeightMm"] > camera["sensorHeightMm"] + 1e-9:
                    fail(errors, f"{cid}/{rid}: active height exceeds sensor")
                cap = res.get("maxSensorFps")
                if cap is not None and cap > (camera.get("maxSensorFps") or math.inf) + 1e-9:
                    fail(errors, f"{cid}/{rid}: resolution fps cap above camera cap")

    used_keys: set[str] = set()
    for key, row in data["rateTable"].items():
        parts = key.split("|")
        if len(parts) != 3:
            fail(errors, f"rate table key '{key}' is not camera|codec|resolution")
            continue
        cam, codec, res = parts
        if cam not in cameras:
            fail(errors, f"rate table key '{key}' references unknown camera")
        if codec not in codecs:
            fail(errors, f"rate table key '{key}' references unknown codec")
        if res not in resolution_owner or resolution_owner[res] != cam:
            fail(errors, f"rate table key '{key}' references unknown resolution for camera")
        if not row:
            fail(errors, f"rate table row '{key}' is empty")
        for fps, mbps in row.items():
            try:
                fps_value = float(fps)
            except ValueError:
                fail(errors, f"rate table row '{key}' has non-numeric fps '{fps}'")
                continue
            if not math.isfinite(fps_value) or fps_value <= 0:
                fail(errors, f"rate table row '{key}' has invalid fps '{fps}'")
            if not math.isfinite(mbps) or mbps <= 0:
                fail(errors, f"rate table row '{key}@{fps}' has invalid MB/s {mbps}")
            # Integral keys must print without a trailing .0 to match rateKey().
            if fps_value == int(fps_value) and fps != str(int(fps_value)):
                fail(errors, f"rate table row '{key}' fps '{fps}' must be '{int(fps_value)}'")
        used_keys.add(key)

    # Mirror CalculatorEngine.codecMatchesCamera: every camera/resolution pair
    # must keep at least one available codec (dead ends would strand the UI).
    def codec_matches(camera: dict, codec: dict, res: dict) -> bool:
        if allowed_ids := camera.get("supportedCodecIds"):
            if codec["id"] not in allowed_ids:
                return False
        if allowed_ids := res.get("supportedCodecIds"):
            if codec["id"] not in allowed_ids:
                return False
        if codec_camera_ids := codec.get("supportedCameraIds"):
            if camera["id"] not in codec_camera_ids:
                return False
        key = f"{camera['id']}|{codec['id']}|{res['id']}"
        if codec["rateModel"] == "published-table" and key not in data["rateTable"]:
            return False
        if camera["manufacturer"] == "DJI":
            return "DJI" in (codec.get("supportedManufacturers") or [])
        return camera["manufacturer"] in (codec.get("supportedManufacturers") or [camera["manufacturer"]])

    for camera in data["cameras"]:
        if camera.get("sourceType") == "prores":
            continue
        for mode in camera.get("modes", []):
            for res in mode["resolutions"]:
                available = [c for c in data["codecs"] if codec_matches(camera, c, res)]
                if not available:
                    fail(errors, f"{camera['id']}/{res['id']}: no available codec")
                table_codecs = [c for c in available if c["rateModel"] == "published-table"]
                if table_codecs and all(
                    not any(float(fps) in FRAME_RATES for fps in data["rateTable"][f"{camera['id']}|{c['id']}|{res['id']}"])
                    for c in table_codecs
                ) and not any(c["rateModel"] != "published-table" for c in available):
                    fail(errors, f"{camera['id']}/{res['id']}: rate rows reference fps outside catalog frameRates")

    if errors:
        for e in errors:
            print(f"error: {e}")
        return 1
    print(f"ok: {len(data['cameras'])} cameras, {len(data['codecs'])} codecs, {len(data['rateTable'])} rate rows")
    return 0


if __name__ == "__main__":
    sys.exit(main())
