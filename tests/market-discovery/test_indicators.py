"""Fixed numeric and data-quality fixtures for the internal candle calculations."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("indicators", Path(__file__).resolve().parents[2] / "src/tools/market/candle_indicators.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def frame(closes):
    return {"closed": [[1_800_000 + i * 900_000, price, price, price, price, 1] for i, price in enumerate(closes)],
            "current": [999_000_000, 999, 999, 999, 999, 1]}


class IndicatorTests(unittest.TestCase):
    def test_sma_and_ema_have_known_values_and_explicit_units(self):
        sma = module.calculate(frame(range(1, 10)), "15m", {"name": "sma", "period": 3}, "USDT")
        self.assertEqual((sma["status"], sma["value"], sma["unit"]), ("available", 8, "USDT"))
        ema = module.calculate(frame(range(1, 9)), "15m", {"name": "ema", "period": 2}, "USD")
        self.assertAlmostEqual(ema["value"], 7.5)
        self.assertEqual(ema["requiredClosedCandles"], 8)

    def test_wilder_rsi_seed_and_smoothing(self):
        result = module.calculate(frame([100,102,101,103,101,102,101,103,101]), "15m", {"name":"rsi","period":2}, "USD")
        self.assertAlmostEqual(result["value"], 33.76623376623377)
        self.assertEqual(result["unit"], "index_0_100")
        for prices, expected in [(range(1,10),100),(range(10,1,-1),0),([100]*9,50)]:
            self.assertEqual(module.calculate(frame(prices), "15m", {"name":"rsi","period":2}, "USD")["value"], expected)

    def test_current_candle_is_never_part_of_the_calculation(self):
        data = frame(range(1,10))
        before = module.calculate(data, "15m", {"name":"sma","period":3}, "USD")
        data["current"] = [999_000_000, 0, 0, 0, 1e9, 0]
        self.assertEqual(before, module.calculate(data, "15m", {"name":"sma","period":3}, "USD"))

    def test_history_and_quality_gaps_never_produce_values(self):
        for data in [frame(range(1,9)), frame([100]*9)]:
            if len(data["closed"]) == 9: data["closed"][3][0] += 1
            result = module.calculate(data, "15m", {"name":"rsi","period":2}, "USD")
            self.assertEqual(result["status"], "unavailable")
            self.assertIsNone(result["value"])
            self.assertTrue(result["gaps"])
        data = frame(range(1,10)); data["qualityGaps"] = ["Duplicate candle timestamps"]
        self.assertEqual(module.calculate(data,"15m",{"name":"sma","period":3},"USD")["gaps"],data["qualityGaps"])

    def test_bounded_series_preserves_times_and_requested_readings(self):
        result = module.calculate(frame(range(1,11)), "15m", {"name":"sma","period":3,"series":3}, "USD")
        self.assertEqual([v["value"] for v in result["series"]], [7,8,9])
        self.assertEqual(result["series"][-1]["time"], result["lastClosedAt"])
        self.assertEqual(result["requiredClosedCandles"], 5)

    def test_invalid_parameters_and_unsupported_intervals(self):
        for value in [{"name":"macd","period":14},{"name":"rsi","period":True},{"name":"sma","period":201},{"name":"ema","period":3,"series":65}]:
            with self.assertRaises(ValueError): module.validate_spec(value)
        self.assertEqual(module.calculate(frame(range(10)),"1d",{"name":"sma","period":3},"USD")["gaps"],["Unsupported interval"])


if __name__ == "__main__": unittest.main()
