import contextlib
import io
import json
import unittest
from unittest.mock import patch
from urllib.error import URLError

import aster


def market(base, quote="USDT", **changes):
    return dict(symbol=base + quote, baseAsset=base, quoteAsset=quote,
                marginAsset=quote, contractType="PERPETUAL", status="TRADING", **changes)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.rows = [market("BTC"), market("BTC", "USD1"), market("CRCL"),
                     market("1000PEPE"), market("BTCC")]
        halted = market("BTC")
        halted["status"] = "SETTLING"
        delivery = market("BTC")
        delivery["contractType"] = "CURRENT_QUARTER"
        pending = market("PENDING")
        pending.update(status="PENDING_TRADING", contractType="")
        self.payload = {"symbols": self.rows + [halted, delivery, pending]}

    def test_exact_base_all_quotes_and_multiple_assets(self):
        rows = aster.select_markets(self.payload, ["BTC", "CRCL"])
        self.assertEqual({r["symbol"] for r in rows}, {"BTCUSDT", "BTCUSD1", "CRCLUSDT"})
        self.assertEqual(len(rows), 3)

    def test_quote_filter_and_no_multiplier_guessing(self):
        rows = aster.select_markets(self.payload, ["BTC"], "USDT")
        self.assertEqual([r["symbol"] for r in rows], ["BTCUSDT"])
        self.assertEqual(aster.select_markets(self.payload, ["PEPE"]), [])
        self.assertEqual(aster.select_markets(self.payload, ["BTC"], "USDC"), [])

    def test_bad_catalog_is_not_absence(self):
        for payload in ({"code": -1, "msg": "error"}, {}, {"symbols": []},
                        {"symbols": [{}]}, {"symbols": "BTCUSDT"}):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                aster.select_markets(payload, ["BTC"])

    def test_cli_fetches_once_normalizes_and_preserves_metadata(self):
        self.rows[2]["underlyingSubType"] = ["STOCK"]
        output = io.StringIO()
        with patch.object(aster, "urlopen", return_value=io.StringIO(json.dumps(self.payload))) as fetch:
            with contextlib.redirect_stdout(output):
                code = aster.main(["exchange-info", "--base-asset", "btc", "crcl", "BTC",
                                   "--quote-asset", "usdt"])
        self.assertEqual(code, 0)
        fetch.assert_called_once()
        self.assertEqual(fetch.call_args.args[0].full_url, aster.SOURCE)
        self.assertEqual(fetch.call_args.kwargs["timeout"], 20)
        result = json.loads(output.getvalue())
        self.assertEqual(result["baseAssets"], ["BTC", "CRCL"])
        self.assertEqual(len(result["markets"]), 2)
        self.assertEqual(result["markets"][1]["underlyingSubType"], ["STOCK"])

    def test_failure_has_nonzero_exit_and_no_success_output(self):
        for error in (URLError("timeout"), ValueError("bad JSON")):
            out, err = io.StringIO(), io.StringIO()
            with patch.object(aster, "urlopen", side_effect=error):
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    code = aster.main(["exchange-info", "--base-asset", "BTC"])
            self.assertEqual(code, 1)
            self.assertEqual(out.getvalue(), "")
            self.assertIn("error", json.loads(err.getvalue()))


if __name__ == "__main__":
    unittest.main()
