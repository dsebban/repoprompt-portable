#!/usr/bin/env python3
"""Deterministic image normalization and metrics for the Classic parity campaign."""

from __future__ import annotations

import hashlib
import io
import json
import math
from pathlib import Path
from typing import Any, Mapping, Sequence

import numpy as np
from PIL import Image, ImageCms


SCHEMA_VERSION = 1
CANVAS = (1956, 1252)
RAW_WINDOW_SIZE = (3008, 1920)
NORMALIZATION_ID = "srgb-aspect-fill-lanczos-v1"
MASK_POLICY = "disjoint-right-bands-v1"
METRIC_ID = "rgb-nmae-gaussian-ssim-v1"
SEMANTIC_MASK_SCHEMA_VERSION = 2
SEMANTIC_MASK_POLICY_V2 = "classic-source-raster-semantic-partition-v2"
SEMANTIC_METRIC_ID_V2 = "rgb-nmae-gaussian-ssim-thresholded-change-v2"
SEMANTIC_CHANGED_PIXEL_THRESHOLD_V2 = 8.0 / 255.0
SEMANTIC_MASK_ORDER_V2 = (
    "titlebar_window_chrome",
    "sidebar_base",
    "sidebar_controls",
    "detail_base",
    "instructions_controls_content",
    "builder_controls_content",
)
# Rectangles are half-open normalized-canvas coordinates. Later assignments win.
# The broad regions are source-hierarchy boundaries; the insets are raster-attested
# from classic-parity-target-v1.png. See the v2 target-state contract.
SEMANTIC_MASK_ASSIGNMENTS_V2: tuple[
    tuple[str, tuple[tuple[int, int, int, int], ...]], ...
] = (
    ("detail_base", ((0, 0, CANVAS[0], CANVAS[1]),)),
    ("titlebar_window_chrome", ((0, 0, CANVAS[0], 128),)),
    ("sidebar_base", ((0, 128, 473, CANVAS[1]),)),
    (
        "sidebar_controls",
        (
            (17, 151, 445, 241),
            (14, 254, 456, CANVAS[1]),
        ),
    ),
    (
        "instructions_controls_content",
        (
            (473, 128, 1446, 246),
            (492, 246, 1446, 630),
        ),
    ),
    (
        "builder_controls_content",
        (
            (492, 648, 1938, 1091),
            (492, 1110, 1938, 1232),
        ),
    ),
)
REGIONS: dict[str, tuple[int, int, int, int]] = {
    "full": (0, 0, 1956, 1252),
    "sidebar": (0, 0, 473, 1252),
    "top": (473, 0, 1956, 170),
    "instructions": (473, 170, 1956, 650),
    "builder_bottom": (473, 650, 1956, 1252),
}
AGGREGATE_WEIGHTS = {
    "full": 0.500,
    "sidebar": 0.125,
    "top": 0.125,
    "instructions": 0.125,
    "builder_bottom": 0.125,
}


class PixelParityError(ValueError):
    """Stable validation error raised by the parity metric library."""


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _srgb_image(path: Path) -> Image.Image:
    if not path.is_file():
        raise PixelParityError(f"missing image: {path}")
    try:
        source = Image.open(path)
        source.load()
    except Exception as error:
        raise PixelParityError(f"cannot decode image: {path}") from error

    icc_profile = source.info.get("icc_profile")
    if icc_profile:
        try:
            source_profile = ImageCms.ImageCmsProfile(io.BytesIO(icc_profile))
            target_profile = ImageCms.createProfile("sRGB")
            source = ImageCms.profileToProfile(
                source,
                source_profile,
                target_profile,
                outputMode="RGBA",
            )
        except Exception as error:
            raise PixelParityError(f"cannot convert ICC profile: {path}") from error
    else:
        source = source.convert("RGBA")

    background = Image.new("RGBA", source.size, (255, 255, 255, 255))
    return Image.alpha_composite(background, source).convert("RGB")


def _aspect_fill_crop_box(
    source_size: tuple[int, int],
    destination_size: tuple[int, int] = CANVAS,
) -> tuple[float, float, float, float]:
    width, height = source_size
    destination_width, destination_height = destination_size
    if width <= 0 or height <= 0 or destination_width <= 0 or destination_height <= 0:
        raise PixelParityError("image dimensions must be positive")

    destination_aspect = destination_width / destination_height
    if width / height > destination_aspect:
        crop_width = height * destination_aspect
        margin = (width - crop_width) / 2.0
        return (margin, 0.0, width - margin, float(height))
    crop_height = width / destination_aspect
    margin = (height - crop_height) / 2.0
    return (0.0, margin, float(width), height - margin)


def normalize_image(
    source_path: Path,
    output_path: Path | None = None,
    *,
    required_size: tuple[int, int] | None = None,
) -> np.ndarray:
    image = _srgb_image(source_path)
    if required_size is not None and image.size != required_size:
        raise PixelParityError(
            f"expected {required_size[0]}x{required_size[1]} image, "
            f"found {image.width}x{image.height}: {source_path}"
        )
    crop_box = _aspect_fill_crop_box(image.size)
    normalized = image.resize(CANVAS, Image.Resampling.LANCZOS, box=crop_box)
    if normalized.size != CANVAS:
        raise PixelParityError("normalization produced an unexpected canvas")
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        normalized.save(output_path, format="PNG", optimize=False)
    return np.asarray(normalized, dtype=np.float64) / 255.0


def _validate_rgb(array: np.ndarray) -> None:
    expected = (CANVAS[1], CANVAS[0], 3)
    if array.shape != expected:
        raise PixelParityError(f"expected RGB canvas {expected}, found {array.shape}")
    if not np.isfinite(array).all():
        raise PixelParityError("metric input contains NaN or infinity")
    if float(array.min()) < 0.0 or float(array.max()) > 1.0:
        raise PixelParityError("metric input must be normalized to [0, 1]")


def _gaussian_kernel() -> np.ndarray:
    coordinates = np.arange(-5, 6, dtype=np.float64)
    kernel = np.exp(-(coordinates**2) / (2.0 * 1.5**2))
    return kernel / kernel.sum()


def _convolve_reflect(array: np.ndarray) -> np.ndarray:
    kernel = _gaussian_kernel()
    horizontal = np.pad(array, ((0, 0), (5, 5), (0, 0)), mode="reflect")
    horizontal_result = np.zeros_like(array, dtype=np.float64)
    for offset, weight in enumerate(kernel):
        horizontal_result += weight * horizontal[:, offset : offset + array.shape[1], :]

    vertical = np.pad(horizontal_result, ((5, 5), (0, 0), (0, 0)), mode="reflect")
    result = np.zeros_like(array, dtype=np.float64)
    for offset, weight in enumerate(kernel):
        result += weight * vertical[offset : offset + array.shape[0], :, :]
    return result


def _ssim_map(target: np.ndarray, candidate: np.ndarray) -> np.ndarray:
    mean_target = _convolve_reflect(target)
    mean_candidate = _convolve_reflect(candidate)
    mean_target_squared = mean_target * mean_target
    mean_candidate_squared = mean_candidate * mean_candidate
    mean_product = mean_target * mean_candidate

    variance_target = np.maximum(_convolve_reflect(target * target) - mean_target_squared, 0.0)
    variance_candidate = np.maximum(
        _convolve_reflect(candidate * candidate) - mean_candidate_squared,
        0.0,
    )
    covariance = _convolve_reflect(target * candidate) - mean_product

    c1 = 0.01**2
    c2 = 0.03**2
    numerator = (2.0 * mean_product + c1) * (2.0 * covariance + c2)
    denominator = (
        (mean_target_squared + mean_candidate_squared + c1)
        * (variance_target + variance_candidate + c2)
    )
    return numerator / denominator


def _validate_regions(regions: Mapping[str, Sequence[int]]) -> None:
    for name, box in regions.items():
        if len(box) != 4:
            raise PixelParityError(f"region {name} must contain four coordinates")
        x0, y0, x1, y1 = map(int, box)
        if x0 < 0 or y0 < 0 or x1 > CANVAS[0] or y1 > CANVAS[1]:
            raise PixelParityError(f"region {name} is outside the metric canvas")
        if x0 >= x1 or y0 >= y1:
            raise PixelParityError(f"region {name} is empty")


def _boundary_probe(target: np.ndarray, candidate: np.ndarray) -> dict[str, dict[str, int]]:
    def luma(image: np.ndarray) -> np.ndarray:
        return image[..., 0] * 0.299 + image[..., 1] * 0.587 + image[..., 2] * 0.114

    target_luma = luma(target)
    candidate_luma = luma(candidate)

    def edge_x(image: np.ndarray, expected: int) -> int:
        values = np.mean(np.abs(np.diff(image, axis=1)), axis=0)
        lower = max(0, expected - 60)
        upper = min(values.shape[0], expected + 60)
        return lower + int(np.argmax(values[lower:upper]))

    def edge_y(image: np.ndarray, expected: int) -> int:
        values = np.mean(np.abs(np.diff(image[:, 473:], axis=0)), axis=1)
        lower = max(0, expected - 60)
        upper = min(values.shape[0], expected + 60)
        return lower + int(np.argmax(values[lower:upper]))

    result: dict[str, dict[str, int]] = {}
    for name, axis, expected in (
        ("sidebar_x", "x", 473),
        ("top_y", "y", 170),
        ("instructions_y", "y", 650),
    ):
        detect = edge_x if axis == "x" else edge_y
        target_detected = detect(target_luma, expected)
        candidate_detected = detect(candidate_luma, expected)
        result[name] = {
            "expected": expected,
            "target_detected": target_detected,
            "candidate_detected": candidate_detected,
            "candidate_delta": candidate_detected - target_detected,
        }
    return result


def compute_metrics(target: np.ndarray, candidate: np.ndarray) -> tuple[dict[str, Any], np.ndarray]:
    _validate_rgb(target)
    _validate_rgb(candidate)
    _validate_regions(REGIONS)
    ssim = _ssim_map(target, candidate)
    regions: dict[str, dict[str, Any]] = {}
    for name, (x0, y0, x1, y1) in REGIONS.items():
        target_region = target[y0:y1, x0:x1, :]
        candidate_region = candidate[y0:y1, x0:x1, :]
        nmae = float(np.mean(np.abs(candidate_region - target_region)))
        ssim_value = float(np.mean(ssim[y0:y1, x0:x1, :]))
        if not math.isfinite(nmae) or not math.isfinite(ssim_value):
            raise PixelParityError(f"non-finite metric for region {name}")
        score = 100.0 * (0.5 * (1.0 - nmae) + 0.5 * min(max(ssim_value, 0.0), 1.0))
        regions[name] = {
            "box": [x0, y0, x1, y1],
            "pixels": (x1 - x0) * (y1 - y0),
            "nmae": nmae,
            "ssim": ssim_value,
            "score": score,
        }

    aggregate = sum(
        AGGREGATE_WEIGHTS[name] * regions[name]["score"]
        for name in AGGREGATE_WEIGHTS
    )
    pixel_perfect = bool(
        np.array_equal(target, candidate)
        and all(regions[name]["nmae"] == 0.0 for name in regions)
        and all(regions[name]["ssim"] == 1.0 for name in regions)
    )
    metrics = {
        "schema_version": SCHEMA_VERSION,
        "canvas": list(CANVAS),
        "normalization_id": NORMALIZATION_ID,
        "mask_policy": MASK_POLICY,
        "metric_id": METRIC_ID,
        "ssim": {
            "channels": "rgb-mean",
            "kernel": "gaussian-11x11",
            "sigma": 1.5,
            "padding": "reflect",
            "covariance": "population",
            "c1": 0.01**2,
            "c2": 0.03**2,
        },
        "aggregate_weights": AGGREGATE_WEIGHTS,
        "regions": regions,
        "aggregate_score": aggregate,
        "worst_region": min(
            (name for name in regions if name != "full"),
            key=lambda name: regions[name]["score"],
        ),
        "pixel_perfect": pixel_perfect,
        "boundaries": _boundary_probe(target, candidate),
    }
    return metrics, np.mean(ssim, axis=2)


def semantic_masks_v2() -> dict[str, np.ndarray]:
    """Return six disjoint masks that partition the normalized canvas."""
    name_to_index = {name: index for index, name in enumerate(SEMANTIC_MASK_ORDER_V2)}
    labels = np.full(
        (CANVAS[1], CANVAS[0]),
        name_to_index["detail_base"],
        dtype=np.uint8,
    )
    for name, rectangles in SEMANTIC_MASK_ASSIGNMENTS_V2:
        if name not in name_to_index:
            raise PixelParityError(f"unknown semantic mask assignment: {name}")
        for rectangle in rectangles:
            _validate_regions({name: rectangle})
            x0, y0, x1, y1 = rectangle
            labels[y0:y1, x0:x1] = name_to_index[name]

    masks = {
        name: labels == index
        for index, name in enumerate(SEMANTIC_MASK_ORDER_V2)
    }
    coverage = np.zeros(labels.shape, dtype=np.uint8)
    for name, mask in masks.items():
        if not bool(mask.any()):
            raise PixelParityError(f"semantic mask is empty: {name}")
        coverage += mask.astype(np.uint8)
    if not bool(np.all(coverage == 1)):
        raise PixelParityError("semantic masks do not partition the canvas")
    return masks


def compute_semantic_mask_metrics_v2(
    target: np.ndarray,
    candidate: np.ndarray,
) -> dict[str, Any]:
    """Measure renderer/state error within the v2 semantic partition."""
    _validate_rgb(target)
    _validate_rgb(candidate)
    masks = semantic_masks_v2()
    ssim = _ssim_map(target, candidate)
    absolute = np.abs(candidate - target)
    changed = np.max(absolute, axis=2) > SEMANTIC_CHANGED_PIXEL_THRESHOLD_V2

    metrics: dict[str, Any] = {}
    for name in SEMANTIC_MASK_ORDER_V2:
        mask = masks[name]
        pixels = int(mask.sum())
        target_values = target[mask]
        candidate_values = candidate[mask]
        nmae = float(np.mean(np.abs(candidate_values - target_values)))
        ssim_value = float(np.mean(ssim[mask]))
        if not math.isfinite(nmae) or not math.isfinite(ssim_value):
            raise PixelParityError(f"non-finite semantic metric for mask {name}")
        changed_pixels = int(np.count_nonzero(changed[mask]))
        score = 100.0 * (
            0.5 * (1.0 - nmae)
            + 0.5 * min(max(ssim_value, 0.0), 1.0)
        )
        metrics[name] = {
            "pixels": pixels,
            "fraction_of_canvas": pixels / (CANVAS[0] * CANVAS[1]),
            "mask_sha256": hashlib.sha256(mask.astype(np.uint8).tobytes()).hexdigest(),
            "nmae": nmae,
            "ssim": ssim_value,
            "score": score,
            "changed_pixels": changed_pixels,
            "changed_fraction": changed_pixels / pixels,
        }

    return {
        "schema_version": SEMANTIC_MASK_SCHEMA_VERSION,
        "canvas": list(CANVAS),
        "mask_policy": SEMANTIC_MASK_POLICY_V2,
        "metric_id": SEMANTIC_METRIC_ID_V2,
        "changed_pixel_rule": {
            "operator": "max_abs_rgb_strictly_greater_than",
            "threshold_normalized": SEMANTIC_CHANGED_PIXEL_THRESHOLD_V2,
            "threshold_8bit": 8,
        },
        "mask_order": list(SEMANTIC_MASK_ORDER_V2),
        "assignments": {
            name: [list(rectangle) for rectangle in rectangles]
            for name, rectangles in SEMANTIC_MASK_ASSIGNMENTS_V2
        },
        "partition_pixels": sum(values["pixels"] for values in metrics.values()),
        "masks": metrics,
        "pixel_perfect": bool(np.array_equal(target, candidate)),
    }


def _float_json(value: Any) -> Any:
    if isinstance(value, float):
        if not math.isfinite(value):
            raise PixelParityError("JSON output contains NaN or infinity")
        return round(value, 12)
    if isinstance(value, dict):
        return {key: _float_json(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_float_json(item) for item in value]
    return value


def stable_json(data: Mapping[str, Any], *, pretty: bool = True) -> str:
    normalized = _float_json(dict(data))
    if pretty:
        return json.dumps(normalized, indent=2, sort_keys=True, allow_nan=False) + "\n"
    return json.dumps(
        normalized,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    )


def save_diagnostics(
    output_directory: Path,
    target: np.ndarray,
    candidate: np.ndarray,
    ssim_map: np.ndarray,
) -> None:
    output_directory.mkdir(parents=True, exist_ok=True)
    absolute = np.mean(np.abs(target - candidate), axis=2)
    amplified = np.clip(absolute * 4.0, 0.0, 1.0)
    ssim_visual = np.clip(ssim_map, 0.0, 1.0)
    Image.fromarray(np.rint(absolute * 255.0).astype(np.uint8), mode="L").save(
        output_directory / "absolute-diff.png"
    )
    Image.fromarray(np.rint(amplified * 255.0).astype(np.uint8), mode="L").save(
        output_directory / "amplified-diff.png"
    )
    Image.fromarray(np.rint(ssim_visual * 255.0).astype(np.uint8), mode="L").save(
        output_directory / "ssim-map.png"
    )

    target_image = Image.fromarray(np.rint(target * 255.0).astype(np.uint8), mode="RGB")
    candidate_image = Image.fromarray(np.rint(candidate * 255.0).astype(np.uint8), mode="RGB")
    diff_image = Image.fromarray(np.rint(amplified * 255.0).astype(np.uint8), mode="L").convert("RGB")
    column_width = CANVAS[0] // 3
    sheet = Image.new("RGB", CANVAS, (255, 255, 255))
    for index, image in enumerate((target_image, candidate_image, diff_image)):
        resized = image.resize((column_width, CANVAS[1]), Image.Resampling.LANCZOS)
        sheet.paste(resized, (index * column_width, 0))
    sheet.save(output_directory / "review-sheet.png")


def save_semantic_mask_diagnostics_v2(output_directory: Path) -> None:
    """Persist the exact v2 mask raster used by semantic metrics."""
    output_directory.mkdir(parents=True, exist_ok=True)
    masks = semantic_masks_v2()
    index = np.zeros((CANVAS[1], CANVAS[0]), dtype=np.uint8)
    for position, name in enumerate(SEMANTIC_MASK_ORDER_V2, start=1):
        mask = masks[name]
        index[mask] = position
        Image.fromarray((mask.astype(np.uint8) * 255), mode="L").save(
            output_directory / f"semantic-mask-v2-{name}.png"
        )
    palette = [
        0,
        0,
        0,
        230,
        159,
        0,
        86,
        180,
        233,
        0,
        158,
        115,
        240,
        228,
        66,
        0,
        114,
        178,
        213,
        94,
        0,
    ]
    palette.extend([0] * (768 - len(palette)))
    image = Image.fromarray(index, mode="P")
    image.putpalette(palette)
    image.save(output_directory / "semantic-mask-index-v2.png")


def plateau(deltas: Sequence[Mapping[str, float]]) -> bool:
    if len(deltas) < 2:
        return False
    latest = deltas[-2:]
    return all(
        item.get("aggregate", float("inf")) < 0.10
        and all(
            item.get(name, float("inf")) < 0.20
            for name in ("sidebar", "top", "instructions", "builder_bottom")
        )
        for item in latest
    )
