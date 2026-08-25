#!/usr/bin/env python3
"""Regression checks for latest-value Vision tread forwarding."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
VIEW_MODEL = ROOT / "ROBControllerVision" / "App" / "RobotViewModel.swift"


class ControllerInputLatencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = VIEW_MODEL.read_text(encoding="utf-8")

    def test_controller_input_channel_drops_superseded_samples(self) -> None:
        self.assertIn("bufferingPolicy: .bufferingNewest(1)", self.source)
        self.assertIn("controllerInputContinuation.yield(controlSample)", self.source)

    def test_forwarding_is_bounded_above_command_rate(self) -> None:
        forwarding = self.source.split(
            "controllerInputForwardingTask = Task", 1
        )[1].split("reloadPairingStatus", 1)[0]
        self.assertIn("await session.updateOperatorInput(sample)", forwarding)
        self.assertIn("clock.sleep(for: .milliseconds(20))", forwarding)

    def test_each_sample_does_not_spawn_an_unbounded_task(self) -> None:
        method = self.source.split(
            "private func sendCombinedControllerSample()", 1
        )[1].split("private func refreshStatusMessage", 1)[0]
        self.assertNotIn("Task {", method)

    def test_disconnect_replaces_any_buffered_drive_sample(self) -> None:
        method = self.source.split(
            "private func acceptGameController", 1
        )[1].split("private func submitGripperTriggerEdges", 1)[0]
        self.assertLess(
            method.index("sendCombinedControllerSample()"),
            method.index("guard sample.isConnected"),
        )


if __name__ == "__main__":
    unittest.main()
