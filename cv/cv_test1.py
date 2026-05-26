"""
cv_test1.py  —  Greenhouse CV test harness

FIXES applied vs original
──────────────────────────
1. visualize_pest_steps: replaced run_pest_model(crop, crop_ir) with the new
   infer_pest_crop(crop) helper.

   The old code called run_pest_model() on a small pre-cropped image + a tiny
   crop_ir slice.  run_pest_model() is designed for FULL FRAMES — it internally
   calls process_pest_crops() which applies the IR offset (50, 30) to the crop's
   IR grid coordinates.  On a small crop image those offset coordinates land
   outside the image bounds → no sub-crops found → function returns early →
   step3 files are never written.

   infer_pest_crop() skips the re-cropping entirely: it just sends the crop
   straight to Roboflow and draws boxes on it.

2. Removed the now-unnecessary IR_OFFSET patching block in visualize_pest_steps.
   The frozen-default-argument bug it tried to work around is fixed in
   greenhouse_cv_system.py, and the test no longer calls run_pest_model on crops
   anyway.
"""

import cv2
import numpy as np
import os

from greenhouse_cv_system import (
    process_pest_crops,
    infer_pest_crop,       # NEW — replaces run_pest_model() for crop-level inference
    run_harvest_model,
    run_disease_model,
    run_pest_model,
    draw_box,
    IR_GRID_SHAPE,
    IR_TO_RGB_SCALE,
)

# Keep IR offset at zero for testing (no physical camera misalignment to correct)
TEST_IR_OFFSET = (0, 0)

# Change these paths to your own test images
HARVEST_IMAGE_PATH = "harvest.png"
DISEASE_IMAGE_PATH = "disease.png"
PEST_IMAGE_PATH    = "pest.png"


# =============================================================================
#  IR GRID HELPERS
# =============================================================================

def create_test_ir_grid(rgb_shape, pest_locations):
    """
    Creates a simulated IR grid based on pest locations in the RGB image.
    Pixels inside each pest bounding box are set to 35 °C (above the 30 °C
    threshold) so process_pest_crops will find them as hot blobs.

    pest_locations: list of (x, y, w, h) in RGB pixel coordinates.
    """
    ir_grid = np.random.randint(20, 25, size=IR_GRID_SHAPE).astype(np.float32)

    for (x, y, w, h) in pest_locations:
        # Convert RGB pixel coordinates → IR grid cell coordinates
        ix = int(x / IR_TO_RGB_SCALE)
        iy = int(y / IR_TO_RGB_SCALE)
        iw = int(w / IR_TO_RGB_SCALE)
        ih = int(h / IR_TO_RGB_SCALE)

        ix_end = min(ix + iw + 1, IR_GRID_SHAPE[1])
        iy_end = min(iy + ih + 1, IR_GRID_SHAPE[0])

        ir_grid[iy:iy_end, ix:ix_end] = 35.0

    return ir_grid


# =============================================================================
#  STEP-BY-STEP PEST VISUALISATION
# =============================================================================

def visualize_pest_steps(rgb_frame, ir_grid):
    """
    Walks through the pest detection pipeline and saves one image per step:

    step1_ir_heatmap.png          — false-colour IR overlay (whole frame)
    step2_crop_<i>.png            — tight RGB snippet for each hot IR blob
    step3_pest_boxed_crop_<i>.png — same snippet with Roboflow boxes drawn

    FIX: step 4/5 now use infer_pest_crop() instead of run_pest_model().
    run_pest_model() is a full-frame function; calling it with a small crop
    caused it to re-run process_pest_crops() internally with the default IR
    offset (50, 30), pushing coordinates outside the tiny crop → no detections
    → step3 files were never written.
    infer_pest_crop() sends the crop directly to Roboflow and draws the boxes.
    """
    print("\n--- VISUALIZING PEST DETECTION STEPS ---")

    # ── Step 1: Save false-colour IR heatmap ──────────────────────────────────
    norm_ir    = cv2.normalize(ir_grid, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
    ir_heatmap = cv2.applyColorMap(
        cv2.resize(norm_ir,
                   (rgb_frame.shape[1], rgb_frame.shape[0]),
                   interpolation=cv2.INTER_LINEAR),
        cv2.COLORMAP_INFERNO
    )
    cv2.imwrite("step1_ir_heatmap.png", ir_heatmap)
    print("Saved: step1_ir_heatmap.png")

    # ── Step 2: Crop RGB snippets guided by hot IR blobs ──────────────────────
    # Pass TEST_IR_OFFSET so the coords are not shifted by the production
    # camera-alignment offset (50, 30).
    crops, crop_metadata, _ = process_pest_crops(
        rgb_frame, ir_grid, offset=TEST_IR_OFFSET
    )

    if not crops:
        print("Warning: no pest crops were found. "
              "Check that pest_locations produce pixels above IR_TEMP_THRESHOLD.")
        return

    # ── Step 3: Save raw (un-annotated) snippets ──────────────────────────────
    for i, (crop, meta) in enumerate(zip(crops, crop_metadata)):
        cv2.imwrite(f"step2_crop_{i}.png", crop)
        print(f"Saved: step2_crop_{i}.png  (RGB region: {meta['rgb_box']})")

    # ── Steps 4 & 5: Send each crop to Roboflow, save annotated result ────────
    #
    # FIX: use infer_pest_crop() — it calls Roboflow directly on the crop and
    # draws boxes, without any re-cropping or IR offset logic.
    #
    for i, (crop, meta) in enumerate(zip(crops, crop_metadata)):
        try:
            boxed_crop, preds = infer_pest_crop(crop)
            cv2.imwrite(f"step3_pest_boxed_crop_{i}.png", boxed_crop)
            detected = [p["class"] for p in preds] or ["no detections"]
            print(f"Saved: step3_pest_boxed_crop_{i}.png  → {detected}")
        except Exception as exc:
            print(f"Warning: Roboflow inference failed for crop {i}: {exc}")


# =============================================================================
#  UTILITIES
# =============================================================================

def load_image_or_exit(image_path, label):
    frame = cv2.imread(image_path)
    if frame is None:
        print(f"Error: Could not load {label} image at: {image_path}")
    return frame


# =============================================================================
#  MAIN TEST RUNNER
# =============================================================================

def run_full_test(harvest_image_path, disease_image_path, pest_image_path):
    harvest_frame = load_image_or_exit(harvest_image_path, "harvest")
    if harvest_frame is None:
        return

    disease_frame = load_image_or_exit(disease_image_path, "disease")
    if disease_frame is None:
        return

    pest_frame = load_image_or_exit(pest_image_path, "pest")
    if pest_frame is None:
        return

    # Two insect groups visible in pest.png:
    #   Left  — three dark flies  (x≈280, y≈300, spanning ~500×360 px)
    #   Right — two honey bees    (x≈1020, y≈290, spanning ~320×320 px)
    pest_locations = [
        (280,  300, 500, 360),   # left fly cluster
        (1020, 290, 320, 320),   # right bee cluster
    ]

    ir_grid = create_test_ir_grid(pest_frame.shape, pest_locations)

    # ── Harvest ───────────────────────────────────────────────────────────────
    print("\n=== RUNNING HARVEST MODEL TEST ===")
    harvest_res = run_harvest_model(harvest_frame)
    if harvest_res is not None:
        cv2.imwrite("test_result_harvest.png", harvest_res)
        print("Saved: test_result_harvest.png")
    else:
        print("Warning: harvest model returned None")

    # ── Disease ───────────────────────────────────────────────────────────────
    print("\n=== RUNNING DISEASE MODEL TEST ===")
    disease_res = run_disease_model(disease_frame)
    if disease_res is not None:
        cv2.imwrite("test_result_disease.png", disease_res)
        print("Saved: test_result_disease.png")
    else:
        print("Warning: disease model returned None")

    # ── Pest (step-by-step) ───────────────────────────────────────────────────
    print("\n=== RUNNING PEST MODEL STEP-BY-STEP TEST ===")
    visualize_pest_steps(pest_frame, ir_grid)


# =============================================================================
#  ENTRY POINT
# =============================================================================

if __name__ == "__main__":
    if not os.path.exists("serviceAccountKey.json"):
        with open("serviceAccountKey.json", "w") as f:
            f.write("{}")

    run_full_test(
        HARVEST_IMAGE_PATH,
        DISEASE_IMAGE_PATH,
        PEST_IMAGE_PATH,
    )
