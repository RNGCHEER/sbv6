"""Exercise only the distributed .sh, without a sibling Python source file."""
import contextlib
import functools
import http.server
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'sbv6.sh'

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.script = self.base / 'sbv6.sh'
        shutil.copy2(SOURCE, self.script)
        self.scratch = self.base / 'temp'; self.scratch.mkdir()
        self.env = dict(os.environ, TMPDIR=str(self.scratch), SBV6_DIR=str(self.base / 'state'), SB_DIR=str(self.base / 'no-upstream'))

    def tearDown(self): self.temp.cleanup()

    def execute(self, *args, **kwargs):
        return subprocess.run(args, cwd=self.base, env=self.env, capture_output=True, text=True, timeout=30, **kwargs)

    def test_single_download_has_no_sibling_dependency(self):
        result = self.execute('bash', str(self.script), '--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('usage: sbv6', result.stdout)
        self.assertFalse((self.base / 'sbv6.py').exists())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_arguments_and_cleanup_on_failure(self):
        result = self.execute('bash', str(self.script), '-l', '--not-a-real-option')
        self.assertEqual(result.returncode, 2)
        self.assertIn('--not-a-real-option', result.stderr)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_single_file_can_export_without_upstream(self):
        result = self.execute('bash', str(self.script), '-l')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.base / 'state/client.json').exists())
        self.assertFalse((self.base / 'no-upstream').exists())

    @unittest.skipUnless(os.geteuid() == 0, 'uninstall confirmation requires root')
    def test_payload_preserves_interactive_stdin(self):
        result = self.execute('bash', str(self.script), '-u', input='n\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('确认卸载', result.stdout)
        self.assertTrue((self.base / 'state').exists())

    def test_curl_process_substitution_entry(self):
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args): pass
        handler = functools.partial(Handler, directory=str(self.base))
        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
            try:
                url = f'http://127.0.0.1:{server.server_port}/sbv6.sh'
                result = self.execute('bash', '-c', 'bash <(curl -fsSL "$1") --help', '_', url)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('--upstream', result.stdout)
                self.assertEqual(list(self.scratch.iterdir()), [])
            finally: server.shutdown(); worker.join()

if __name__ == '__main__': unittest.main()
