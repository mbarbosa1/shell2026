import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "extract_har.py"
SPEC = importlib.util.spec_from_file_location("extract_har", SCRIPT)
EXTRACTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXTRACTOR)


class StoreCaptureTests(unittest.TestCase):
    def capture(self, directory, store="1074"):
        path = Path(directory) / "capture.har"
        path.write_text(json.dumps({"log": {"entries": [{
            "request": {"url": f"https://redsky.target.com/product?store_id={store}"},
            "response": {"content": {"text": json.dumps({"tcin": "123", "item": {
                "product_description": {"title": "Milk"}}})}}
        }]}}))
        return path

    def test_aisle_combines_letter_and_number_and_deduplicates(self):
        positions = [{"block": "A", "aisle": 23, "floor": "01"}] * 2
        product = EXTRACTOR.normalize("123", {}, positions)
        self.assertEqual(product["locations"], [{"aisle": "A23", "floor": "01"}])

    def test_extract_needs_no_store_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.capture(directory)
            products = EXTRACTOR.extract([source])
            self.assertEqual(products[0]["tcin"], "123")

    def test_cli_exports_catalog_without_store_and_retains_unlocated_products(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.capture(directory)
            output = Path(directory) / "products.json"
            subprocess.run([sys.executable, str(SCRIPT), str(source),
                            "--include-unlocated", "-o", str(output)], check=True, capture_output=True)
            data = json.loads(output.read_text())
            self.assertNotIn("storeID", data)
            self.assertEqual(data["productCount"], 1)
            self.assertEqual(data["products"][0]["tcin"], "123")


if __name__ == "__main__":
    unittest.main()
