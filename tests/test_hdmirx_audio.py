"""Contract for HDMI-only preferences consumed by WirePlumber's chooser."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class ProfilePolicyTest(unittest.TestCase):
    def setUp(self):
        text = (ROOT / 'mkosi/runtime/pipewire/10-ceralive-headless.conf').read_text()
        self.body = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))
        self.rule = self.body.split('device.profile.priority.rules =', 1)[1]
        self.priorities = re.findall(r'"([^"\n]+)"', self.rule.split('priorities = [',1)[1].split(']',1)[0])

    def test_cold_probe_has_a_usable_profile(self):
        available = {'off', 'pro-audio'}
        self.assertEqual(next(p for p in self.priorities if p in available), 'pro-audio')

    def test_audio_at_boot_still_selects_capture_profile(self):
        available = {'off', 'pro-audio', 'input:stereo-fallback'}
        self.assertEqual(next(p for p in self.priorities if p in available), 'pro-audio')

    def test_only_real_capture_preferences(self):
        self.assertEqual(self.priorities, ['pro-audio'])

    def test_receiver_identity_alternatives_remain_scoped(self):
        identities = re.findall(r'(?:alsa.id|device.name) = "([^"\n]+)"', self.rule)
        self.assertEqual(identities, ['HDMIIN', '~alsa_card.platform-hdmi-receiver-sound.*', '~alsa_card.platform-hdmirx-sound.*'])
        patterns = [re.compile(p[1:]) for p in identities if p.startswith('~')]
        for unrelated in ['alsa_card.platform-sound', 'alsa_card.platform-hdmi0-sound', 'alsa_card.platform-hdmi1-sound', 'alsa_card.usb-camera']:
            self.assertFalse(any(p.fullmatch(unrelated) for p in patterns))

    def test_priority_is_a_rule_action_not_an_ignored_match_key(self):
        self.assertRegex(self.rule, r'actions\s*=\s*\{\s*update-props\s*=\s*\{\s*priorities\s*=')

    def test_no_unconditional_alsa_monitor_override(self):
        monitor = self.body.split('device.profile.priority.rules =',1)[0]
        self.assertNotRegex(monitor, r'device.profile\s*=\s*"pro-audio"')

if __name__ == '__main__':
    unittest.main()
