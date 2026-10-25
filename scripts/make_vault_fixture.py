"""Writes Tests/SanketaVaultTests/Fixtures/vault.db: a small vishalakshi vault for the vault search tests.

Run it with a Python that has vishalakshi and abhyasa, for example:
    ../abhyasa/.venv/bin/python -I scripts/make_vault_fixture.py
"""
import shutil, sqlite3, sys, tempfile
from pathlib import Path
from vishalakshi import Vault
from abhyasa.store import Learning

out = Path(__file__).resolve().parent.parent/'Tests/SanketaVaultTests/Fixtures/vault.db'
tmp = Path(tempfile.mkdtemp())/'vault.db'
v = Vault(str(tmp), offline=True)
v.add('Sandhi joins two sounds where words meet. The rules of vowel sandhi change a final vowel.',
      title='Notes on sandhi', source='https://example.com/sandhi', kind='page')
v.add('A tmux session holds windows and panes. Detach with prefix d and attach again later.',
      title='tmux sessions', source='/Users/nobody/notes/tmux.md', kind='md')
v.add('Remember to water the zucchini plants on Sunday.', title='Garden reminder', source='note:garden', kind='note')
lr = Learning(v)
lr.put('Vowel sandhi', 'When a word ends in a vowel and the next word starts with a vowel, the two vowels join.',
       subject='sanskrit', aliases=['svara sandhi'])
lr.put('Zucchini watering', 'Water zucchini deeply once a week.', subject='garden')
v.shelf('tmpjunk', offline=True).add('zucchini in a junk shelf', title='junk zucchini', source='note:junk', kind='note')

# one file with no WAL or usearch sidecar, so the test bundle holds a single read-only file
c = sqlite3.connect(tmp)
c.execute('pragma wal_checkpoint(truncate)'); c.execute('pragma journal_mode=delete'); c.execute('vacuum'); c.close()
shutil.copy(tmp, out)
print(out, out.stat().st_size, file=sys.stderr)
