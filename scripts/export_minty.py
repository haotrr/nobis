#!/usr/bin/env python3
"""Export a user-selected, decrypted Minty database COPY. Never modifies the input."""
import argparse
import json
import sqlite3
from pathlib import Path

TABLES = ('expenses', 'income', 'asset_snapshots', 'projects', 'project_plan_items', 'subscriptions', 'config')

def export(source: Path, destination: Path, ledger: str):
    if source.resolve() == destination.resolve() or destination.exists():
        raise ValueError('输出路径已存在；请选择新的迁移包文件名。')
    db = sqlite3.connect(source.resolve().as_uri() + '?mode=ro', uri=True)
    db.row_factory = sqlite3.Row
    try:
        db.execute('BEGIN')
        if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('数据库完整性检查未通过。')
        existing = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if 'expenses' not in existing:
            raise ValueError('所选文件不是含 expenses 的 Minty 账本。')
        tables = {}
        for table in TABLES:
            if table not in existing:
                tables[table] = []
                continue
            columns = db.execute(f'PRAGMA table_info("{table}")').fetchall()
            # Money is exported as decimal text; the importer rejects excess precision.
            fields = ','.join(f'CAST("{r[1]}" AS TEXT) AS "{r[1]}"' if r[2].upper() in ('REAL','DOUBLE','FLOAT') else f'"{r[1]}"' for r in columns)
            tables[table] = [dict(r) for r in db.execute(f'SELECT {fields} FROM "{table}"')]
        with destination.open('x', encoding='utf-8') as out:
            json.dump({'format': 'minty-nobis', 'version': 1, 'source': ledger, 'tables': tables}, out, ensure_ascii=False, indent=2)
    finally:
        db.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('database', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--ledger', required=True, help='稳定账本标识，例如 family；重复导出必须一致')
    args = parser.parse_args()
    try:
        export(args.database, args.output, args.ledger)
    except (sqlite3.DatabaseError, ValueError, OSError) as error:
        parser.exit(1, f'导出失败：{error}\n如源库为 SQLCipher 加密文件，请使用 Minty 解密导出的数据库副本；本工具不读取 Keychain。\n')
