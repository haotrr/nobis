import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('export_minty', Path(__file__).with_name('export_minty.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class ExportTests(unittest.TestCase):
    def test_readonly_decimal_and_complete_tables(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'fixture.db'
            output = Path(directory) / 'migration.json'
            db = sqlite3.connect(source)
            db.executescript("CREATE TABLE expenses(id INTEGER, amount REAL, item TEXT); INSERT INTO expenses VALUES(1,12.34,'餐厅'); CREATE TABLE income(id INTEGER, post_tax REAL); INSERT INTO income VALUES(1,100.01);")
            db.commit()
            db.close()
            before = source.read_bytes()
            module.export(source, output, 'family-test')
            result = json.loads(output.read_text())
            self.assertEqual(result['tables']['expenses'][0]['amount'], '12.34')
            self.assertEqual(result['tables']['income'][0]['post_tax'], '100.01')
            self.assertEqual(source.read_bytes(), before)
            with self.assertRaises(ValueError):
                module.export(source, output, 'family-test')
            with self.assertRaises(ValueError):
                module.export(source, source, 'family-test')

if __name__ == '__main__':
    unittest.main()
