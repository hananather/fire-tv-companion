import math
import unittest
from unittest.mock import patch

import airplay_diagnostics


class DiagnosticsPrivacyTests(unittest.TestCase):
    def test_only_finite_numeric_screen_fields_are_retained(self):
        message = {
            "deviceName": "private receiver label", "address": "192.0.2.2", "token": "private value",
            "durationMs": 30000, "stats": {"Sent Frames": 1200, "Dropped Overflow Frames": 3},
            "pairingMs": True, "resolveMs": math.inf, "setupMs": "private value",
        }
        self.assertEqual(airplay_diagnostics.numeric_screen_fields(message),
                         {"durationMs": 30000, "Sent Frames": 1200, "Dropped Overflow Frames": 3})

    def test_public_network_targets_are_refused_before_contact(self):
        with patch("socket.create_connection") as connect:
            with self.assertRaises(ValueError):
                airplay_diagnostics.lan_metrics("192.0.2.2")
            connect.assert_not_called()


if __name__ == "__main__":
    unittest.main()
