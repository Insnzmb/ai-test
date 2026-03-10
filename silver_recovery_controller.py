#!/usr/bin/env python3
from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from typing import Any

MOVEMENT_ACTIONS = {"UP", "DOWN", "LEFT", "RIGHT", "UP_A", "DOWN_A", "LEFT_A", "RIGHT_A"}
ORTH_SOUTH = ("UP", "DOWN")
EAST_WEST = ("LEFT", "RIGHT")
OPPOSITE = {
    "UP": "DOWN",
    "DOWN": "UP",
    "LEFT": "RIGHT",
    "RIGHT": "LEFT",
    "UP_A": "DOWN_A",
    "DOWN_A": "UP_A",
    "LEFT_A": "RIGHT_A",
    "RIGHT_A": "LEFT_A",
}


@dataclass
class RecoveryRuntime:
    recent_positions: deque = field(default_factory=lambda: deque(maxlen=20))
    recent_actions: deque = field(default_factory=lambda: deque(maxlen=24))
    loop_score: int = 0
    standstill_score: int = 0

    def observe_transition(self, prev: dict[str, Any], action: str, curr: dict[str, Any], reward_signal: Any | None = None) -> None:
        pos = (int(curr.get("map_group", 0)), int(curr.get("map_number", 0)), int(curr.get("x", 0)), int(curr.get("y", 0)))
        self.recent_positions.append(pos)
        self.recent_actions.append(str(action or "NONE").upper())
        moved = (int(prev.get("x", 0)), int(prev.get("y", 0))) != (int(curr.get("x", 0)), int(curr.get("y", 0)))
        progress = bool(getattr(reward_signal, "progress", False)) if reward_signal is not None else False
        tried_to_move = str(action or "NONE").upper() in MOVEMENT_ACTIONS
        if moved or progress:
            self.standstill_score = max(0, self.standstill_score - 2)
            self.loop_score = max(0, self.loop_score - 1)
        else:
            # Only charge standstill when a movement was actually attempted but
            # failed (wall bump).  Choosing NONE intentionally (e.g. waiting on
            # the same tile as the host) should not build recovery pressure.
            if tried_to_move:
                self.standstill_score = min(30, self.standstill_score + 1)
            if len(self.recent_positions) >= 6:
                tail = list(self.recent_positions)[-6:]
                if len(set(tail)) <= 2:
                    self.loop_score = min(40, self.loop_score + 2)
            if len(self.recent_actions) >= 4:
                tail_a = list(self.recent_actions)[-4:]
                if tail_a[0] == tail_a[2] and tail_a[1] == tail_a[3] and tail_a[0] != tail_a[1]:
                    self.loop_score = min(40, self.loop_score + 3)

    def recovery_pressure(self) -> int:
        return int(self.loop_score + self.standstill_score)

    def recommend_action(
        self,
        state: dict[str, Any],
        allowed: list[str],
        *,
        guide_action: str | None = None,
        fallback_action: str | None = None,
        last_action: str | None = None,
        blocked_action: str | None = None,
        detour_action: str | None = None,
    ) -> str | None:
        pressure = self.recovery_pressure()
        if pressure < 8:
            return None
        if int(state.get("in_menu", 0)) != 0:
            for act in ("B", "A", guide_action, fallback_action):
                if act in allowed:
                    return act
        if int(state.get("script_running", 0)) != 0:
            for act in ("A", "B"):
                if act in allowed:
                    return act
        blocked_base = str(blocked_action or "NONE").upper()
        if detour_action in allowed:
            return detour_action
        if guide_action in MOVEMENT_ACTIONS and guide_action in allowed and str(guide_action).upper() != blocked_base:
            return guide_action
        if fallback_action in MOVEMENT_ACTIONS and fallback_action in allowed and str(fallback_action).upper() != blocked_base:
            return fallback_action
        last = str(last_action or "NONE").upper()
        if last in OPPOSITE and OPPOSITE[last] in allowed and pressure >= 12:
            return OPPOSITE[last]
        axis = EAST_WEST if (len(self.recent_positions) >= 2 and list(self.recent_positions)[-1][:2] == list(self.recent_positions)[-2][:2]) else ORTH_SOUTH
        for act in axis + ("A", "B"):
            if act in allowed:
                return act
        return None
