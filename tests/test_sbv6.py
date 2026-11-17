import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('sbv6', Path(__file__).parents[1] / 'sbv6.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class CompanionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.patches = [patch.object(m, 'ROOT', self.root / 'v6'), patch.object(m, 'SB', self.root / 'upstream'), patch.object(m, 'firewall')]
        for p in self.patches: p.start()
        m.ROOT.mkdir(); (m.SB / 'conf').mkdir(parents=True)
        self.ib = {'type': 'shadowsocks', 'tag': '香港 A shadowsocks', 'listen': '::', 'listen_port': 8885,
                   'method': '2022-blake3-aes-128-gcm', 'password': 'MDEyMzQ1Njc4OWFiY2RlZg=='}
        self.path = m.SB / 'conf/15_shadowsocks_inbounds.json'
        m.atomic(self.path, '// comment\n' + json.dumps({'inbounds': [self.ib]}))

    def tearDown(self):
        for p in reversed(self.patches): p.stop()
        self.tmp.cleanup()

    def node(self):
        ib = copy.deepcopy(self.ib); ib.update(listen='::1', listen_port=35000)
        return {'key': 'f', 'family': 6, 'host': '::1', 'public_key': '', 'inbound': ib}

    def test_comment_parser_and_native_tag(self):
        self.assertEqual(m.upstream()['f'][0]['tag'], '香港 A shadowsocks')

    def test_dual_stack_port_skip_and_credentials(self):
        from argparse import Namespace
        args = Namespace(ipv6='::1', ipv4='192.0.2.1', protocols='f', port=8885, name='test')
        state = m.load()
        with patch.object(m, 'available', return_value=True): m.add(state, args, True)
        self.assertEqual([n['inbound']['listen_port'] for n in state['nodes']], [8886,8886])
        self.assertEqual([n['inbound']['listen'] for n in state['nodes']], ['0.0.0.0','::1'])
        self.assertEqual(state['nodes'][0]['inbound']['password'], self.ib['password'])

    def test_check_failure_does_not_publish(self):
        state = m.load(); state['nodes'] = [self.node()]
        with patch.object(m, 'run', side_effect=ValueError('bad configuration')):
            with self.assertRaises(ValueError): m.commit(state)
        self.assertFalse((m.ROOT / 'state.json').exists())
        self.assertFalse((m.ROOT / 'config.json').exists())

    def test_restart_failure_rolls_back(self):
        m.atomic(m.ROOT / 'config.json', 'old')
        state = m.load(); state['nodes'] = [self.node()]
        with patch.object(m, 'run', return_value=''), patch.object(m, 'service', side_effect=[ValueError('failed'), None]):
            with self.assertRaises(ValueError): m.commit(state)
        self.assertEqual((m.ROOT / 'config.json').read_text(), 'old')
        self.assertFalse((m.ROOT / 'state.json').exists())

    def test_idempotent_commit_and_subscription(self):
        state = m.load(); state['nodes'] = [self.node()]
        with patch.object(m, 'run', return_value=''), patch.object(m, 'service') as service:
            m.commit(state); m.commit(state)
            service.assert_called_once_with('restart')
        import base64
        links = base64.b64decode((m.ROOT / 'subscription.txt').read_text()).decode()
        self.assertIn('@[::1]:35000', links)
        self.assertIn('%E9%A6%99', links)

    def test_pin_preserves_loopback_and_uninstall_restores(self):
        original = self.path.read_text(); state = m.load()
        loopback = m.SB / 'conf/17_vmess-ws_inbounds.json'
        m.atomic(loopback, {'inbounds': [{'listen': '127.0.0.1', 'type': 'vmess'}]})
        before = loopback.read_text()
        with patch.object(m, 'run', return_value=''):
            m.pin_upstream(state)
            self.assertIn('0.0.0.0', self.path.read_text())
            self.assertEqual(loopback.read_text(), before)
            m.pin_upstream(state, restore=True)
        self.assertEqual(self.path.read_text(), original)

    def test_readdress_only_ipv6(self):
        state = m.load(); n = self.node(); n4 = copy.deepcopy(n); n4.update(family=4, host='192.0.2.1'); n4['inbound']['listen']='0.0.0.0'
        state['nodes'] = [n, n4]
        with patch.object(m, 'detect6', return_value='2001:4860::123'), patch.object(m, 'commit'):
            m.sync(state)
        self.assertEqual(n['host'], '2001:4860::123'); self.assertEqual(n4['host'], '192.0.2.1')

    def test_bootstrap_skip_never_runs_upstream_installer(self):
        core = m.ROOT / 'bin/sing-box'; core.parent.mkdir(); core.write_text('fixture')
        with patch.object(m, 'upstream_installed', return_value=False), patch.object(m, 'manage_upstream') as installer, patch.object(m, 'run', return_value='version'), patch.object(m, 'BIN', str(core)):
            m.ensure_ready('skip')
            installer.assert_not_called()

    def test_bootstrap_install_runs_official_installer(self):
        core = m.ROOT / 'bin/sing-box'; core.parent.mkdir(); core.write_text('fixture')
        with patch.object(m, 'upstream_installed', return_value=False), patch.object(m, 'manage_upstream') as installer, patch.object(m, 'run', return_value='version'), patch.object(m, 'BIN', str(core)):
            m.ensure_ready('install')
            installer.assert_called_once_with()

    def test_bootstrap_cancel_has_no_download(self):
        with patch.object(m, 'upstream_installed', return_value=False), patch('builtins.input', return_value='0'), patch.object(m, 'download') as download:
            with self.assertRaises(ValueError): m.ensure_ready()
            download.assert_not_called()

    def test_shadowtls_detours_are_unique_per_family(self):
        state = m.load()
        ib, pub = m.fresh('e', 'demo')
        for family in (4,6):
            item = copy.deepcopy(ib); item.update(tag=f'demo IPv{family} ShadowTLS', listen='0.0.0.0' if family == 4 else '::1', listen_port=35000)
            state['nodes'].append({'key': 'e', 'family': family, 'host': '::1', 'public_key': pub, 'inbound': item})
        inbounds = m.config(state)['inbounds']
        self.assertEqual(len(set(i['tag'] for i in inbounds)), 4)
        self.assertTrue(all('_inner' not in i for i in inbounds))
        self.assertNotEqual(inbounds[1]['detour'], inbounds[3]['detour'])

if __name__ == '__main__': unittest.main()
