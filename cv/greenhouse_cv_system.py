"""
=============================================================================
 GREENHOUSE COMPUTER VISION SYSTEM  —  Firebase-Integrated Edition
 Models : Harvest (24h) | Disease (2h) | Pests IR+RGB (on-demand)
 API    : Roboflow Serverless
 Firebase: Realtime Database — reads manual_pesticide gate per zone,
           writes CV alerts + logs matching the app & hardware format.
=============================================================================

Firebase paths used
───────────────────
READ  /zones/<zone_index>/mode/manual_pesticide   → bool
      /zones/<zone_index>/mode/auto_pesticide      → bool (for context only)

WRITE /zones/<zone_index>/cv_alerts/harvest       → { detected, count, timestamp, message }
      /zones/<zone_index>/cv_alerts/disease       → { detected, count, timestamp, message }
      /zones/<zone_index>/cv_alerts/pest          → { detected, scenario, counts, timestamp, message }

WRITE /zones/<zone_index>/logs                    → append  { timestamp, action, user }
      (same list format as the Flutter app _logAction() and NodeMCU sendLog())

FIXES applied
─────────────
1. process_pest_crops: threshold now applied to RAW temperature values, not
   the 0-255 normalised image.  Using 30 on a normalised image meant almost
   every pixel passed, producing one giant blob (= full image sent to Roboflow).

2. process_pest_crops / ir_has_heat_signature: default arguments
   (threshold, scale, offset) are now resolved inside the function body so
   that patching the module-level constants at runtime actually takes effect.
   Python default-argument values are captured once at definition time, so
   offset=IR_OFFSET in the signature would always be (50,30) regardless of
   later assignments to greenhouse_cv_system.IR_OFFSET.

3. infer_pest_crop: new public helper added so the test harness (and any
   future caller) can run Roboflow inference on a single pre-cropped image
   without going through the full run_pest_model pipeline (which is designed
   for full frames, not crops).
"""

import cv2
import numpy as np
import time
import threading
import concurrent.futures
import tempfile
import os
from datetime import datetime, timedelta

# ── Firebase Admin SDK ────────────────────────────────────────────────────────
import firebase_admin
from firebase_admin import credentials, db as firebase_db

# ── Roboflow ──────────────────────────────────────────────────────────────────
from inference_sdk import InferenceHTTPClient


# =============================================================================
#  CONFIG — edit these to match your deployment
# =============================================================================

# ── Roboflow ──────────────────────────────────────────────────────────────────
ROBOFLOW_API_KEY = "Pg24s62L0MXQ9NOPPXdb"
ROBOFLOW_API_URL = "https://serverless.roboflow.com"

MODEL_HARVEST = "ripe-tomatoes-rup4z/1"
MODEL_DISEASE = "leafdata-bright-rlbju/2"
MODEL_PEST    = "pests-eiiw7/1"

# ── Firebase ──────────────────────────────────────────────────────────────────
FIREBASE_CREDENTIALS_PATH = "serviceAccountKey.json"
FIREBASE_DATABASE_URL     = "https://iot-uni-17ac1-default-rtdb.firebaseio.com"
ZONE_INDEX                = 0
CV_SYSTEM_USER            = "CV_System_Automated"

# ── Pest economic threshold ───────────────────────────────────────────────────
HARMFUL_THRESHOLD = 5

# ── IR settings ───────────────────────────────────────────────────────────────
IR_TEMP_THRESHOLD = 30        # °C — pixels above this → "hot"
IR_GRID_SHAPE     = (24, 32)  # MLX90640 default
IR_TO_RGB_SCALE   = 40
IR_OFFSET         = (50, 30)

# ── Parallel pest inference threads ──────────────────────────────────────────
MAX_PEST_WORKERS = 4

# ── Polling interval for manual_pesticide flag (seconds) ─────────────────────
MANUAL_MODE_POLL_INTERVAL = 5


# =============================================================================
#  FIREBASE INITIALISATION
# =============================================================================

def _init_firebase() -> firebase_db.Reference:
    """
    Initialise the Firebase Admin SDK once.
    Returns the database root Reference.
    Idempotent — safe to call multiple times (no-op after first call).
    """
    if not firebase_admin._apps:
        cred = credentials.Certificate(FIREBASE_CREDENTIALS_PATH)
        firebase_admin.initialize_app(cred, {"databaseURL": FIREBASE_DATABASE_URL})
    return firebase_db.reference("/")


_db_root: firebase_db.Reference | None = None


def _get_db() -> firebase_db.Reference:
    global _db_root
    if _db_root is None:
        _db_root = _init_firebase()
    return _db_root


def _zone_ref(sub_path: str = "") -> firebase_db.Reference:
    """Return a database Reference for  /zones/<ZONE_INDEX>[/sub_path]."""
    base = f"zones/{ZONE_INDEX}"
    return _get_db().child(f"{base}/{sub_path}" if sub_path else base)


# =============================================================================
#  FIREBASE  —  MANUAL PESTICIDE GATE
# =============================================================================

def is_manual_pesticide_active() -> bool:
    """
    Return True when  /zones/<ZONE_INDEX>/mode/manual_pesticide  is true.
    Errors are treated as False so a connectivity hiccup does not permanently
    freeze the system.
    """
    try:
        val = _zone_ref("mode/manual_pesticide").get()
        return bool(val)
    except Exception as exc:
        print(f"  [FIREBASE] Could not read manual_pesticide: {exc} — assuming False")
        return False


def wait_for_automated_mode():
    """Block until manual_pesticide becomes False."""
    while True:
        if not is_manual_pesticide_active():
            return
        print(
            f"  [CV PAUSED] Manual pesticide mode is ACTIVE for zone {ZONE_INDEX}. "
            f"CV models suspended. Retrying in {MANUAL_MODE_POLL_INTERVAL}s …"
        )
        time.sleep(MANUAL_MODE_POLL_INTERVAL)


# =============================================================================
#  FIREBASE  —  LOGGING  (matches Flutter _logAction() & NodeMCU sendLog())
# =============================================================================

def _firebase_log(action: str):
    """Append a log entry to  /zones/<ZONE_INDEX>/logs."""
    try:
        log_ref = _zone_ref("logs")

        def _append(current):
            if isinstance(current, list):
                logs = list(current)
            elif isinstance(current, dict):
                logs = list(current.values())
            else:
                logs = []
            logs.append({
                "timestamp": datetime.now().isoformat(),
                "action":    action,
                "user":      CV_SYSTEM_USER,
            })
            return logs

        log_ref.transaction(_append)
        print(f"  [LOG → Firebase] {action}")

    except Exception as exc:
        print(f"  [FIREBASE] Log write failed: {exc}")


# =============================================================================
#  FIREBASE  —  CV ALERT UPLOAD
# =============================================================================

def _upload_cv_alert(model: str, payload: dict):
    """Write the CV model result to  /zones/<ZONE_INDEX>/cv_alerts/<model>."""
    try:
        _zone_ref(f"cv_alerts/{model}").set(payload)
        print(f"  [ALERT → Firebase] cv_alerts/{model}: {payload}")
    except Exception as exc:
        print(f"  [FIREBASE] Alert upload failed for {model}: {exc}")


# =============================================================================
#  ROBOFLOW CLIENT
# =============================================================================

CLIENT = InferenceHTTPClient(api_url=ROBOFLOW_API_URL, api_key=ROBOFLOW_API_KEY)


# =============================================================================
#  ANNOTATION HELPERS
# =============================================================================

COLORS = {
    "Ripe":       (0,   200,  50),
    "Disease":    (0,    50, 255),
    "Beneficial": (255, 200,   0),
    "High-risk":  (0,     0, 255),
    "Harmful":    (0,   128, 255),
    "unknown":    (180, 180, 180),
}


def draw_box(image: np.ndarray, x: int, y: int, w: int, h: int,
             label: str, confidence: float, color=None) -> np.ndarray:
    if color is None:
        color = COLORS.get(label, COLORS["unknown"])
    cv2.rectangle(image, (x, y), (x + w, y + h), color, 2)
    text = f"{label}  {confidence:.0%}"
    (tw, th), baseline = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, 0.55, 1)
    pad = 4
    cv2.rectangle(image,
                  (x, y - th - pad * 2 - baseline),
                  (x + tw + pad * 2, y),
                  color, cv2.FILLED)
    cv2.putText(image, text,
                (x + pad, y - pad - baseline),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 1, cv2.LINE_AA)
    return image


def stamp(image: np.ndarray, message: str,
          position: str = "bottom", color=(255, 255, 255)) -> np.ndarray:
    h, w = image.shape[:2]
    y = h - 20 if position == "bottom" else 30
    cv2.putText(image, message, (10, y),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 0), 3, cv2.LINE_AA)
    cv2.putText(image, message, (10, y),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, color,     1, cv2.LINE_AA)
    return image


def save_debug(image: np.ndarray, prefix: str):
    ts   = datetime.now().strftime("%Y%m%d_%H%M%S")
    path = f"debug_{prefix}_{ts}.jpg"
    cv2.imwrite(path, image)
    print(f"  [DEBUG] Saved → {path}")


# =============================================================================
#  IR + RGB CROP PIPELINE
# =============================================================================

def process_pest_crops(rgb_img, ir_grid,
                        threshold=None,
                        scale=None,
                        offset=None,
                        min_blob_area=2):
    """
    Identify hot blobs in the IR grid and return the corresponding RGB crops.

    Parameters resolved at call time (not at import time) so that patching
    module-level constants in tests or at runtime works correctly.

    FIX 1: threshold is now applied to the RAW ir_grid temperatures (°C),
            not to the 0-255 normalised image.  Applying 30 to a normalised
            image meant ~88% of pixels passed → one giant blob → full image
            sent to Roboflow instead of tight crops.

    FIX 2: default argument values (threshold, scale, offset) are resolved
            inside the body so runtime patches to IR_OFFSET etc. are respected.
    """
    # ── Resolve defaults at call time (not definition time) ───────────────────
    if threshold is None:
        threshold = IR_TEMP_THRESHOLD   # reads current module value
    if scale is None:
        scale = IR_TO_RGB_SCALE
    if offset is None:
        offset = IR_OFFSET              # reads current module value

    if ir_grid is None or ir_grid.size == 0:
        return [], [], None

    # ── FIX 1: threshold on raw °C values, then dilate ────────────────────────
    # ir_grid contains actual temperatures (float32, °C).
    # We want pixels strictly above IR_TEMP_THRESHOLD (default 30 °C).
    hot_mask = (ir_grid > threshold).astype(np.uint8) * 255
    kernel       = np.ones((3, 3), np.uint8)
    grouped_mask = cv2.dilate(hot_mask, kernel, iterations=2)
    contours, _  = cv2.findContours(grouped_mask, cv2.RETR_EXTERNAL,
                                    cv2.CHAIN_APPROX_SIMPLE)

    crops, crop_metadata = [], []
    h_rgb, w_rgb = rgb_img.shape[:2]

    for cnt in contours:
        if cv2.contourArea(cnt) < min_blob_area:
            continue
        ix, iy, iw, ih = cv2.boundingRect(cnt)
        rx  = int(ix * scale + offset[0])
        ry  = int(iy * scale + offset[1])
        rw  = int(iw * scale)
        rh  = int(ih * scale)
        pad = 20
        x1, y1 = max(0, rx - pad),      max(0, ry - pad)
        x2, y2 = min(w_rgb, rx+rw+pad), min(h_rgb, ry+rh+pad)
        if x2 <= x1 or y2 <= y1:
            continue
        snippet = rgb_img[y1:y2, x1:x2].copy()
        if snippet.size == 0:
            continue
        crops.append(snippet)
        crop_metadata.append({
            "ir_box":   (ix, iy, iw, ih),
            "rgb_box":  (x1, y1, x2-x1, y2-y1),
            "x_center": (x1+x2)/2/w_rgb,
            "y_center": (y1+y2)/2/h_rgb,
        })

    # Build the IR visualisation from the normalised version (display only)
    norm_ir = cv2.normalize(ir_grid, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
    debug_ir_vis = cv2.applyColorMap(
        cv2.resize(norm_ir, (w_rgb, h_rgb), interpolation=cv2.INTER_LINEAR),
        cv2.COLORMAP_INFERNO
    )
    return crops, crop_metadata, debug_ir_vis


def ir_has_heat_signature(ir_grid, threshold=None, min_hot_pixels=3) -> bool:
    """
    Return True when at least min_hot_pixels in ir_grid exceed threshold °C.
    FIX: default resolved at call time so runtime patches to IR_TEMP_THRESHOLD
    are respected.
    """
    if threshold is None:
        threshold = IR_TEMP_THRESHOLD
    if ir_grid is None:
        return False
    return int(np.sum(ir_grid > threshold)) >= min_hot_pixels


# =============================================================================
#  ROBOFLOW INFERENCE WRAPPERS
# =============================================================================

def _roboflow_infer(image_path_or_array, model_id: str) -> dict:
    """Send an image (path or ndarray) to Roboflow and return raw result."""
    if isinstance(image_path_or_array, np.ndarray):
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
            tmp_path = tmp.name
        try:
            cv2.imwrite(tmp_path, image_path_or_array)
            return CLIENT.infer(tmp_path, model_id=model_id)
        finally:
            os.remove(tmp_path)
    return CLIENT.infer(image_path_or_array, model_id=model_id)


def parse_predictions(result: dict) -> list[dict]:
    preds = result.get("predictions", [])
    return [{
        "class":      p.get("class", "unknown"),
        "confidence": float(p.get("confidence", 0)),
        "x":          int(p.get("x", 0)),
        "y":          int(p.get("y", 0)),
        "width":      int(p.get("width", 0)),
        "height":     int(p.get("height", 0)),
    } for p in preds]


def infer_pest_crop(crop: np.ndarray) -> np.ndarray:
    """
    NEW PUBLIC HELPER — run the pest model on a single pre-cropped image and
    return a copy of the crop annotated with bounding boxes.

    Use this instead of run_pest_model() when you already have a tight RGB
    crop and just want Roboflow inference + box drawing on that crop.
    run_pest_model() is designed for full frames and will try to re-crop
    internally, which breaks when given a small crop image.
    """
    result    = _roboflow_infer(crop, MODEL_PEST)
    preds     = parse_predictions(result)
    annotated = crop.copy()
    for p in preds:
        draw_box(annotated,
                 p["x"] - p["width"]  // 2,
                 p["y"] - p["height"] // 2,
                 p["width"], p["height"],
                 p["class"], p["confidence"])
    return annotated, preds


# =============================================================================
#  MODEL 1 — HARVEST  (every 24 h)
# =============================================================================

def run_harvest_model(rgb_frame: np.ndarray) -> np.ndarray:
    """
    Detect ripe fruits, upload result to Firebase, log the event.
    """
    print("\n[HARVEST] Running inference …")
    annotated = rgb_frame.copy()

    try:
        result     = _roboflow_infer(rgb_frame, MODEL_HARVEST)
        preds      = parse_predictions(result)
        ripe_count = 0

        for p in preds:
            if p["class"] != "Ripe":
                continue
            ripe_count += 1
            cx, cy, bw, bh = p["x"], p["y"], p["width"], p["height"]
            draw_box(annotated, cx - bw//2, cy - bh//2, bw, bh, "Ripe", p["confidence"])

        ts = datetime.now().isoformat()

        if ripe_count:
            msg   = f"HARVEST READY — {ripe_count} ripe fruit(s) detected"
            color = (0, 200, 50)
            print(f"  [ALERT] {msg}")
            _upload_cv_alert("harvest", {
                "detected":  True,
                "count":     ripe_count,
                "timestamp": ts,
                "message":   msg,
            })
            _firebase_log(f"CV Harvest Alert: {msg}")
        else:
            msg   = "Harvest check: No ripe fruits detected"
            color = (200, 200, 200)
            print(f"  [INFO]  {msg}")
            _upload_cv_alert("harvest", {
                "detected":  False,
                "count":     0,
                "timestamp": ts,
                "message":   msg,
            })

        stamp(annotated, msg, color=color)

    except Exception as exc:
        print(f"  [ERROR] Harvest model failed: {exc}")
        stamp(annotated, "Harvest model ERROR", color=(0, 0, 255))

    save_debug(annotated, "harvest")
    return annotated


# =============================================================================
#  MODEL 2 — DISEASE  (every 2 h)
# =============================================================================

def run_disease_model(rgb_frame: np.ndarray) -> np.ndarray:
    """
    Detect plant diseases, upload result to Firebase, log the event.
    """
    print("\n[DISEASE] Running inference …")
    annotated     = rgb_frame.copy()

    try:
        result        = _roboflow_infer(rgb_frame, MODEL_DISEASE)
        preds         = parse_predictions(result)
        disease_count = 0

        for p in preds:
            if p["class"] != "Disease":
                continue
            disease_count += 1
            cx, cy, bw, bh = p["x"], p["y"], p["width"], p["height"]
            draw_box(annotated, cx - bw//2, cy - bh//2, bw, bh, "Disease", p["confidence"])

        ts = datetime.now().isoformat()

        if disease_count:
            msg   = f"DISEASE ALERT — {disease_count} infected area(s) found"
            color = (0, 50, 255)
            print(f"  [ALERT] {msg}")
            _upload_cv_alert("disease", {
                "detected":  True,
                "count":     disease_count,
                "timestamp": ts,
                "message":   msg,
            })
            _firebase_log(f"CV Disease Alert: {msg}")
        else:
            msg   = "Disease check: Plants appear healthy"
            color = (200, 200, 200)
            print(f"  [INFO]  {msg}")
            _upload_cv_alert("disease", {
                "detected":  False,
                "count":     0,
                "timestamp": ts,
                "message":   msg,
            })

        stamp(annotated, msg, color=color)

    except Exception as exc:
        print(f"  [ERROR] Disease model failed: {exc}")
        stamp(annotated, "Disease model ERROR", color=(0, 0, 255))

    save_debug(annotated, "disease")
    return annotated


# =============================================================================
#  MODEL 3 — PESTS  (triggered by IR heat signature)
# =============================================================================

def _classify_pest_scenario(counts: dict) -> tuple:
    n_hr  = counts.get("High-risk",  0)
    n_hm  = counts.get("Harmful",    0)
    n_ben = counts.get("Beneficial", 0)
    total = n_hr + n_hm + n_ben

    if total == 0:
        return ("none",
                "Pest check: No pests detected",
                (200, 200, 200))
    if n_hr >= 1:
        return ("spray_high_risk",
                f"HIGH-RISK PEST — SPRAY IMMEDIATELY! "
                f"({n_hr} high-risk | {n_hm} harmful | {n_ben} beneficial)",
                (0, 0, 255))
    if n_hm >= HARMFUL_THRESHOLD:
        return ("spray_harmful",
                f"HARMFUL THRESHOLD REACHED — SPRAY. "
                f"({n_hm}/{HARMFUL_THRESHOLD} harmful | {n_ben} beneficial)",
                (0, 128, 255))
    if n_ben > 0 and n_hm == 0 and n_hr == 0:
        return ("no_spray_beneficial",
                f"Beneficial pests only ({n_ben}) — do NOT spray",
                (0, 200, 50))
    return ("monitor",
            f"Monitoring — {n_hm} harmful pest(s) below threshold "
            f"({HARMFUL_THRESHOLD}). No spray needed.",
            (0, 200, 200))


def run_pest_model(rgb_frame: np.ndarray, ir_grid: np.ndarray) -> np.ndarray:
    """
    Full IR-gated pest pipeline for a FULL FRAME.
    Do NOT pass pre-cropped images here — use infer_pest_crop() for that.
    Pauses while manual_pesticide is active.
    Uploads result + log to Firebase.
    """
    print("\n[PEST] Checking manual mode gate …")
    wait_for_automated_mode()

    print("[PEST] Checking IR for heat signatures …")
    annotated = rgb_frame.copy()

    # ── IR gate ───────────────────────────────────────────────────────────────
    if not ir_has_heat_signature(ir_grid):
        msg = "Pest IR gate: No heat signatures — skipping"
        print(f"  [INFO]  {msg}")
        stamp(annotated, msg, color=(200, 200, 200))
        save_debug(annotated, "pest_no_ir")
        return annotated

    print("  [IR] Heat detected — cropping RGB …")
    crops, crop_metadata, ir_vis = process_pest_crops(rgb_frame, ir_grid)

    if not crops:
        msg = "Pest IR gate: Hot IR pixels found but no valid RGB crops"
        print(f"  [WARN]  {msg}")
        stamp(annotated, msg, color=(0, 200, 200))
        save_debug(annotated, "pest_no_crops")
        return annotated

    print(f"  [IR] {len(crops)} crop(s) extracted — running inference …")

    counts: dict   = {}
    all_detections = []

    def _infer_crop(args):
        idx, snippet, meta = args
        result = _roboflow_infer(snippet, MODEL_PEST)
        return idx, meta, parse_predictions(result)

    tasks = [(i, s, m) for i, (s, m) in enumerate(zip(crops, crop_metadata))]

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_PEST_WORKERS) as pool:
        future_map = {pool.submit(_infer_crop, t): t[0] for t in tasks}
        for future in concurrent.futures.as_completed(future_map):
            crop_idx = future_map[future]
            try:
                idx, meta, preds = future.result()
                for p in preds:
                    cls = p["class"]
                    counts[cls] = counts.get(cls, 0) + 1
                    all_detections.append((meta, p))
                print(f"    [PEST] Crop {idx}: "
                      f"{[p['class'] for p in preds] or 'no detections'}")
            except Exception as exc:
                print(f"  [ERROR] Pest crop {crop_idx} failed: {exc}")

    # ── Draw boxes on full annotated frame ────────────────────────────────────
    for meta, p in all_detections:
        rx, ry, rw, rh = meta["rgb_box"]
        bw, bh = p["width"], p["height"]
        abs_x1 = rx + p["x"] - bw // 2
        abs_y1 = ry + p["y"] - bh // 2
        draw_box(annotated, abs_x1, abs_y1, bw, bh, p["class"], p["confidence"])

    for meta in crop_metadata:
        rx, ry, rw, rh = meta["rgb_box"]
        cv2.rectangle(annotated, (rx, ry), (rx+rw, ry+rh), (0, 220, 220), 1, cv2.LINE_AA)

    # ── Sprayer decision ──────────────────────────────────────────────────────
    scenario, decision_msg, color = _classify_pest_scenario(counts)
    ts = datetime.now().isoformat()

    print(f"\n  ════ SPRAYER DECISION ════")
    print(f"  Counts  : {counts}")
    print(f"  Scenario: {scenario}")
    print(f"  Message : {decision_msg}")
    print(f"  ═════════════════════════\n")

    stamp(annotated, decision_msg, color=color)
    save_debug(annotated, f"pest_{scenario}")
    if ir_vis is not None:
        save_debug(ir_vis, "pest_ir_heatmap")

    # ── Upload alert to Firebase ──────────────────────────────────────────────
    _upload_cv_alert("pest", {
        "detected":  counts.get("High-risk", 0) + counts.get("Harmful", 0) > 0,
        "scenario":  scenario,
        "counts":    counts,
        "timestamp": ts,
        "message":   decision_msg,
    })

    # ── Log to Firebase if action-worthy ─────────────────────────────────────
    if scenario in ("spray_high_risk", "spray_harmful"):
        _firebase_log(f"CV Pest Alert: {decision_msg}")
        try:
            _zone_ref("crop_profile/pesticide").set(True)
            _firebase_log("CV Pest: Set pesticide flag → hardware will spray")
            print("  [FIREBASE] Set crop_profile/pesticide = true → hardware will spray")
        except Exception as exc:
            print(f"  [FIREBASE] Could not set pesticide flag: {exc}")
    elif scenario == "no_spray_beneficial":
        _firebase_log(f"CV Pest: Beneficial pests only — no spray. {counts}")
    elif scenario == "monitor":
        _firebase_log(f"CV Pest: Monitoring — {counts}")

    return annotated


# =============================================================================
#  SCHEDULER
# =============================================================================

class GreenhouseScheduler:
    """
    Runs each model on its own timer inside background threads.
    The pest model is gated by manual_pesticide == False.
    Call  scheduler.update(rgb_frame, ir_grid)  from your camera loop.
    """

    def __init__(self):
        self._last_harvest = datetime.min
        self._last_disease = datetime.min
        self._lock         = threading.Lock()
        _get_db()
        print(f"[SCHEDULER] Firebase connected. Monitoring zone {ZONE_INDEX}.")

    def update(self, rgb_frame: np.ndarray,
               ir_grid: np.ndarray | None = None) -> dict:
        """
        Call once per camera frame (or as often as you like).
        Returns a dict of annotated images for any model that ran this tick.
        """
        now     = datetime.now()
        results = {}

        run_harvest_now = False
        run_disease_now = False

        with self._lock:
            if now - self._last_harvest >= timedelta(hours=24):
                self._last_harvest = now
                run_harvest_now = True
            if now - self._last_disease >= timedelta(hours=2):
                self._last_disease = now
                run_disease_now = True

        if run_harvest_now:
            results["harvest"] = run_harvest_model(rgb_frame)
        if run_disease_now:
            results["disease"] = run_disease_model(rgb_frame)

        if ir_grid is not None:
            results["pest"] = run_pest_model(rgb_frame, ir_grid)

        return results


# =============================================================================
#  DEMO / TEST HARNESS
# =============================================================================

def _make_dummy_ir(shape=(24, 32), hot_spots=None) -> np.ndarray:
    grid = np.random.randint(20, 28, size=shape, dtype=np.float32)
    if hot_spots:
        for (r, c) in hot_spots:
            grid[r, c] = 38
    return grid


def demo_from_image(image_path: str,
                    run_harvest: bool = True,
                    run_disease: bool = True,
                    run_pest:    bool = True,
                    simulate_ir: bool = True):
    frame = cv2.imread(image_path)
    if frame is None:
        raise FileNotFoundError(f"Could not load image: {image_path}")
    print(f"Loaded test image {image_path}  {frame.shape}")

    if run_harvest:
        run_harvest_model(frame)
    if run_disease:
        run_disease_model(frame)
    if run_pest:
        ir = _make_dummy_ir(hot_spots=[(12, 16), (10, 18), (14, 15)]) if simulate_ir else None
        run_pest_model(frame, ir)


def demo_live_camera(camera_index: int = 0, simulate_ir: bool = True):
    cap = cv2.VideoCapture(camera_index)
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open camera index {camera_index}")

    scheduler  = GreenhouseScheduler()
    last_frame = None

    print("\n=== LIVE MODE ===")
    print("  H = force harvest check")
    print("  D = force disease check")
    print("  P = force pest check")
    print("  Q = quit\n")

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        last_frame = frame.copy()
        display    = frame.copy()

        cv2.putText(display, datetime.now().strftime("%H:%M:%S"),
                    (10, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                    (200, 200, 200), 1, cv2.LINE_AA)

        if is_manual_pesticide_active():
            cv2.putText(display, "MANUAL PESTICIDE MODE — CV PAUSED",
                        (10, 52), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                        (0, 0, 255), 2, cv2.LINE_AA)

        cv2.imshow("Greenhouse CV", display)

        key = cv2.waitKey(30) & 0xFF
        if key == ord("q"):
            break
        elif key == ord("h") and last_frame is not None:
            cv2.imshow("Harvest Result", run_harvest_model(last_frame.copy()))
        elif key == ord("d") and last_frame is not None:
            cv2.imshow("Disease Result", run_disease_model(last_frame.copy()))
        elif key == ord("p") and last_frame is not None:
            ir = _make_dummy_ir(hot_spots=[(12, 16), (10, 18)]) if simulate_ir else None
            cv2.imshow("Pest Result", run_pest_model(last_frame.copy(), ir))

        ir = _make_dummy_ir() if simulate_ir else None
        scheduler.update(frame, ir_grid=ir)

    cap.release()
    cv2.destroyAllWindows()


# =============================================================================
#  ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1:
        demo_from_image(sys.argv[1])
    else:
        demo_live_camera(camera_index=0, simulate_ir=True)
