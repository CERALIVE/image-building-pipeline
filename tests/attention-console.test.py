#!/usr/bin/env python3
"""VT ownership regressions; fake devices never touch the host's consoles."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('attention', Path(__file__).resolve().parents[1] / 'mkosi/runtime/ceralive-attention.py')
a = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(a)
TOP = dict(id='example', severity='fatal', line='The card is not ready.',
           fix='Check the card.', detail='Storage check failed.', led='auto')


class ConsoleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tty = self.root / 'tty8'
        self.tty.write_text('')
        self.login = self.root / 'tty1'
        self.login.write_text('Device login: ')
        self.vt = '1'
        self.font = b'original-font-and-unicode-map'
        self.calls = []
        self.fail_save = False
        self.fail_switch = False
        self.fail_restore = False
        self.controller = self.owner()

    def owner(self):
        return a.Console(self.root / 'state', str(self.tty), self.run_command,
                         lambda: self.vt)

    def run_command(self, *args):
        self.calls.append(args)
        if args[0] == 'chvt':
            if self.fail_switch:
                return False
            self.vt = args[1]
        elif args[0] == 'setfont':
            self.assertEqual(args[2], str(self.tty))
            if '-O' in args:
                Path(args[-1]).write_bytes(self.font)
                return not self.fail_save
            elif args[-1].endswith('.psf.gz'):
                self.font = b'large-font'
            else:
                if self.fail_restore:
                    return False
                self.font = Path(args[-1]).read_bytes()
        else:
            self.fail(args)
        return True

    def test_startup_getty_and_unchanged_fatal(self):
        self.controller.update(TOP)
        self.assertEqual(self.vt, '8')
        self.login.write_text('Late startup login: ')
        self.tty.write_text('Transient console noise')
        self.controller.update(TOP)
        self.assertIn(TOP['line'], self.tty.read_text())
        self.assertIn('Alt+F1 to log in. Alt+F8 returns here.', self.tty.read_text())
        self.assertEqual(self.login.read_text(), 'Late startup login: ')
        self.assertEqual(self.calls.count(('chvt', '8')), 1)

    def test_info_clear_restores_font_and_login(self):
        self.controller.update(TOP)
        self.assertEqual(self.font, b'large-font')
        self.controller.update(TOP | dict(severity='info'))
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.login.read_text(), 'Device login: ')
        self.assertFalse(self.controller.state.exists())
        self.assertNotIn(TOP['line'], self.tty.read_text())
        previous_calls = self.calls.copy()
        self.controller.update(None)
        self.assertEqual(self.calls, previous_calls)

    def test_login_remains_reachable_and_not_stolen(self):
        self.controller.update(TOP)
        self.vt = '1'  # Operator uses the shortcut while fatal remains active.
        self.controller.update(TOP)
        self.assertEqual(self.vt, '1')
        self.assertIn(TOP['line'], self.tty.read_text())
        self.controller.update(None)
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.calls.count(('chvt', '8')), 1)
        self.assertNotIn(('chvt', '1'), self.calls)

    def test_restart_keeps_original_snapshot_and_does_not_steal_login(self):
        self.controller.update(TOP)
        self.vt = '2'
        owner = self.owner()
        owner.update(TOP)
        self.assertEqual(self.vt, '2')
        owner.release()
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertEqual(self.vt, '2')

    def test_return_to_previous_vt_on_critical_clear_and_stop(self):
        self.vt = '2'
        self.controller.update(TOP | dict(severity='critical'))
        self.controller.release()
        self.assertEqual(self.vt, '2')
        self.assertEqual(self.font, b'original-font-and-unicode-map')

    def test_failed_save_never_changes_font_and_failed_restore_retries(self):
        self.fail_save = True
        self.controller.update(TOP)
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertFalse(self.controller.font.exists())
        self.controller.release()
        self.fail_save = False
        self.controller.update(TOP)
        self.fail_restore = True
        self.controller.release()
        self.assertTrue(self.controller.state.exists())
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.login.read_text(), 'Device login: ')
        self.fail_restore = False
        self.controller.release()
        self.assertFalse(self.controller.state.exists())
        self.assertEqual(self.vt, '1')

    def test_failed_switch_keeps_message_and_shortcut_until_retry(self):
        self.controller.update(TOP)
        self.fail_switch = True
        self.controller.release()
        self.assertEqual(self.vt, '8')
        self.assertIn('Alt+F1 to log in.', self.tty.read_text())
        self.assertTrue(self.controller.state.exists())
        self.fail_switch = False
        self.controller.release()
        self.assertEqual(self.vt, '1')
        self.assertEqual(self.font, b'original-font-and-unicode-map')

    def test_warning_has_no_console_effect_and_long_detail_keeps_shortcut(self):
        self.controller.update(TOP | dict(severity='warn'))
        self.assertEqual(self.calls, [])
        with mock.patch.object(a.os, 'get_terminal_size', return_value=(80, 12)):
            self.controller.update(TOP | dict(detail='Detailed explanation. ' * 100))
        self.assertLess(len(self.tty.read_text().splitlines()), 12)
        self.assertIn('Alt+F1 to log in.', self.tty.read_text())
        self.assertIn(TOP['line'], self.tty.read_text())

    def test_watch_repaints_every_tick_and_releases_on_stop(self):
        frames, stops = [], []
        def sleep(_):
            frames.append(self.tty.read_text())
            if len(frames) == 1:
                self.tty.write_text('Transient startup output')
            else:
                stops[0]()
        with mock.patch.object(a, 'Console', return_value=self.controller), \
             mock.patch.object(a, 'probes'), mock.patch.object(a, 'conditions', return_value=[TOP]), \
             mock.patch.object(a, 'render', return_value=TOP), mock.patch.object(a, 'command'), \
             mock.patch.object(a, 'listener'), mock.patch.object(a.time, 'sleep', side_effect=sleep), \
             mock.patch.object(a.signal, 'signal', side_effect=lambda _, cb: stops.append(cb)):
            a.watch()
        self.assertEqual(len(frames), 2)
        self.assertTrue(all(TOP['line'] in frame for frame in frames))
        self.assertEqual(self.font, b'original-font-and-unicode-map')
        self.assertEqual(self.vt, '1')


if __name__ == '__main__':
    unittest.main()
