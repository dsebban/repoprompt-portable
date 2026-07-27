#!/usr/bin/env python3

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, ImageCms

from classic_pixel_parity_metrics import (
    AGGREGATE_WEIGHTS,
    CANVAS,
    REGIONS,
    PixelParityError,
    _aspect_fill_crop_box,
    compute_metrics,
    compute_semantic_mask_metrics_v2,
    normalize_image,
    plateau,
    semantic_masks_v2,
    stable_json,
)


def canvas(value: float = 0.5) -> np.ndarray:
    return np.full((CANVAS[1], CANVAS[0], 3), value, dtype=np.float64)


class ClassicPixelParityMetricTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.mid = canvas()
        cls.identical_metrics, _ = compute_metrics(cls.mid, cls.mid)

    def test_identical_images_score_perfectly(self) -> None:
        metrics = self.identical_metrics
        self.assertTrue(metrics["pixel_perfect"])
        self.assertEqual(metrics["aggregate_score"], 100.0)
        for values in metrics["regions"].values():
            self.assertEqual(values["nmae"], 0.0)
            self.assertEqual(values["ssim"], 1.0)
            self.assertEqual(values["score"], 100.0)

    def test_black_against_white_has_unit_nmae(self) -> None:
        metrics, _ = compute_metrics(canvas(0.0), canvas(1.0))
        self.assertEqual(metrics["regions"]["full"]["nmae"], 1.0)
        self.assertLess(metrics["regions"]["full"]["ssim"], 0.001)

    def test_one_channel_one_pixel_has_exact_nmae(self) -> None:
        candidate = self.mid.copy()
        candidate[700, 900, 0] = 1.0
        metrics, _ = compute_metrics(self.mid, candidate)
        expected = 0.5 / (CANVAS[0] * CANVAS[1] * 3)
        self.assertAlmostEqual(metrics["regions"]["full"]["nmae"], expected, places=16)

    def test_disjoint_region_perturbation_changes_only_its_region_and_full(self) -> None:
        candidate = self.mid.copy()
        candidate[800:820, 800:820, :] = 1.0
        metrics, _ = compute_metrics(self.mid, candidate)
        self.assertGreater(metrics["regions"]["builder_bottom"]["nmae"], 0.0)
        self.assertGreater(metrics["regions"]["full"]["nmae"], 0.0)
        for name in ("sidebar", "top", "instructions"):
            self.assertEqual(metrics["regions"][name]["nmae"], 0.0)

    def test_regions_are_valid_and_weights_sum_to_one(self) -> None:
        self.assertEqual(sum(AGGREGATE_WEIGHTS.values()), 1.0)
        sidebar = REGIONS["sidebar"]
        self.assertEqual(sidebar, (0, 0, 473, 1252))
        right_area = sum(
            (REGIONS[name][2] - REGIONS[name][0]) * (REGIONS[name][3] - REGIONS[name][1])
            for name in ("top", "instructions", "builder_bottom")
        )
        sidebar_area = (sidebar[2] - sidebar[0]) * (sidebar[3] - sidebar[1])
        self.assertEqual(right_area + sidebar_area, CANVAS[0] * CANVAS[1])

    def test_alpha_is_composited_over_white(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "transparent.png"
            Image.new("RGBA", (40, 40), (0, 0, 0, 0)).save(path)
            normalized = normalize_image(path)
            self.assertTrue(np.array_equal(normalized, np.ones_like(normalized)))

    def test_icc_and_no_icc_normalize_equivalently(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            plain = directory / "plain.png"
            tagged = directory / "tagged.png"
            image = Image.new("RGB", (40, 40), (25, 50, 75))
            image.save(plain)
            profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
            image.save(tagged, icc_profile=profile)
            np.testing.assert_array_equal(normalize_image(plain), normalize_image(tagged))

    def test_fractional_center_crop_is_symmetric_and_deterministic(self) -> None:
        box = _aspect_fill_crop_box((3008, 1920))
        self.assertAlmostEqual(box[0], 4.1916932907, places=8)
        self.assertAlmostEqual(3008 - box[2], box[0], places=12)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "gradient.png"
            row = np.linspace(0, 255, 3008, dtype=np.uint8)
            image = np.repeat(row[np.newaxis, :, np.newaxis], 1920, axis=0)
            image = np.repeat(image, 3, axis=2)
            Image.fromarray(image, mode="RGB").save(path)
            first = normalize_image(path)
            second = normalize_image(path)
            np.testing.assert_array_equal(first, second)

    def test_stable_json_and_plateau(self) -> None:
        first = stable_json(self.identical_metrics, pretty=False)
        second = stable_json(self.identical_metrics, pretty=False)
        self.assertEqual(first, second)
        small = {
            "aggregate": 0.09,
            "sidebar": 0.19,
            "top": 0.19,
            "instructions": 0.19,
            "builder_bottom": 0.19,
        }
        self.assertTrue(plateau([small, small]))
        self.assertFalse(plateau([small]))

    def test_rejects_bad_dimensions_and_non_finite_input(self) -> None:
        with self.assertRaises(PixelParityError):
            compute_metrics(np.zeros((1, 1, 3)), np.zeros((1, 1, 3)))
        invalid = self.mid.copy()
        invalid[0, 0, 0] = np.nan
        with self.assertRaises(PixelParityError):
            compute_metrics(self.mid, invalid)

    def test_semantic_masks_v2_are_disjoint_and_partition_canvas(self) -> None:
        masks = semantic_masks_v2()
        coverage = np.zeros((CANVAS[1], CANVAS[0]), dtype=np.uint8)
        for mask in masks.values():
            coverage += mask.astype(np.uint8)
        self.assertTrue(np.all(coverage == 1))
        self.assertEqual(
            sum(int(mask.sum()) for mask in masks.values()),
            CANVAS[0] * CANVAS[1],
        )

    def test_semantic_metrics_v2_identical_images_are_exact(self) -> None:
        metrics = compute_semantic_mask_metrics_v2(self.mid, self.mid)
        self.assertTrue(metrics["pixel_perfect"])
        self.assertEqual(metrics["partition_pixels"], CANVAS[0] * CANVAS[1])
        for values in metrics["masks"].values():
            self.assertEqual(values["nmae"], 0.0)
            self.assertEqual(values["ssim"], 1.0)
            self.assertEqual(values["changed_pixels"], 0)
            self.assertEqual(values["changed_fraction"], 0.0)

    def test_semantic_metrics_v2_attribute_change_to_one_mask(self) -> None:
        candidate = self.mid.copy()
        candidate[700:720, 700:720, :] = 1.0
        metrics = compute_semantic_mask_metrics_v2(self.mid, candidate)
        self.assertEqual(
            metrics["masks"]["builder_controls_content"]["changed_pixels"],
            400,
        )
        for name, values in metrics["masks"].items():
            if name != "builder_controls_content":
                self.assertEqual(values["changed_pixels"], 0, name)


if __name__ == "__main__":
    unittest.main()
