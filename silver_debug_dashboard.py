#!/usr/bin/env python3
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class DebugDashboardRuntime:
    json_path: Path
    text_path: Path
    tick: int = 0

    def update(self, payload: dict[str, Any]) -> None:
        self.tick += 1
        try:
            self.json_path.parent.mkdir(parents=True, exist_ok=True)
            self.json_path.write_text(json.dumps(payload, indent=2), encoding='utf-8')
            lines = [
                f"frame: {payload.get('frame')}",
                f"map: {payload.get('map_name')} ({payload.get('map_group')}-{payload.get('map_number')}) at {payload.get('x')},{payload.get('y')}",
                f"host: {payload.get('host_map_group')}-{payload.get('host_map_number')} at {payload.get('host_x')},{payload.get('host_y')}",
                f"phase: {payload.get('phase')} | milestone: {payload.get('milestone')} | planner: {payload.get('planner')}",
                f"objective: {payload.get('objective')}",
                f"mission: {payload.get('mission_label')} | battle: {payload.get('battle_note')}",
                f"capture: {payload.get('capture_note')}",
                f"cookies/broccoli: {payload.get('cookies')} / {payload.get('broccoli')} | mood: {payload.get('mood')}",
                f"recovery: {payload.get('recovery_action')} pressure={payload.get('recovery_pressure')} | stuck={payload.get('stuck_count')} | repeat={payload.get('repeat_streak')}",
                f"manual override: {payload.get('manual_override')} | teacher: {payload.get('teacher_summary')}",
                f"last action: {payload.get('last_action')} | guide: {payload.get('guide_action')} | chosen: {payload.get('chosen_action')}",
                f"wall: {payload.get('wall_summary')}",
                f"signal: {payload.get('signal_summary')}",
            ]
            self.text_path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
        except OSError:
            pass
