import importlib.util
from pathlib import Path
import unittest
import numpy as np

spec = importlib.util.spec_from_file_location(
    "decision", Path(__file__).parents[1] / "train-decision-head.py"
)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


class DecisionBenchmarkTests(unittest.TestCase):
    def test_outer_gold_cannot_change_its_predictions_or_temperature(self):
        rows = [
            dict(
                case_id=str(case),
                note_id=str(i),
                label=int(i % 2 == 0),
                cheap=[i + 0.1 * case],
                vector=[i],
            )
            for case in range(4)
            for i in range(6)
        ]
        first, _ = b.evaluate(rows, "logistic-cheap", recall_target=0.98)
        changed = [
            dict(r, label=1 - r["label"]) if r["case_id"] == "0" else r for r in rows
        ]
        second, _ = b.evaluate(changed, "logistic-cheap", recall_target=0.98)
        a = [r["probability"] for r in first["predictions"] if r["case_id"] == "0"]
        c = [r["probability"] for r in second["predictions"] if r["case_id"] == "0"]
        np.testing.assert_array_equal(a, c)
        self.assertEqual(
            first["folds"][0]["temperature"], second["folds"][0]["temperature"]
        )
        self.assertEqual(
            first["folds"][0]["threshold"], second["folds"][0]["threshold"]
        )

    def test_calibration_metrics_count_ties_and_binary_classes(self):
        result = b.metrics(np.array([0, 1, 0, 1]), np.array([0.5, 0.5, 0.5, 0.5]))
        self.assertEqual(result["auroc"], 0.5)
        self.assertEqual(result["brier"], 0.25)
        self.assertEqual(result["ece"], 0)


if __name__ == "__main__":
    unittest.main()
