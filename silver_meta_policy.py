#!/usr/bin/env python3
from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Any

MOVEMENT_ACTIONS = {"UP", "DOWN", "LEFT", "RIGHT", "UP_A", "DOWN_A", "LEFT_A", "RIGHT_A"}
HORIZONTAL_ACTIONS = {"LEFT", "RIGHT", "LEFT_A", "RIGHT_A"}
VERTICAL_ACTIONS = {"UP", "DOWN", "UP_A", "DOWN_A"}
OPPOSITE_ACTION = {
    "UP": "DOWN",
    "DOWN": "UP",
    "LEFT": "RIGHT",
    "RIGHT": "LEFT",
    "UP_A": "DOWN_A",
    "DOWN_A": "UP_A",
    "LEFT_A": "RIGHT_A",
    "RIGHT_A": "LEFT_A",
}


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def _same_map(state: dict[str, Any]) -> bool:
    return (
        int(state.get("host_map_group", -1)) == int(state.get("map_group", -2))
        and int(state.get("host_map_number", -1)) == int(state.get("map_number", -2))
        and int(state.get("host_x", -999)) >= 0
        and int(state.get("host_y", -999)) >= 0
    )


def _canonical(action: str | None) -> str:
    raw = str(action or "NONE").upper().strip()
    if raw.endswith("_A"):
        raw = raw[:-2]
    return raw


def _state_bucket(state: dict[str, Any], objective: str = "") -> str:
    if int(state.get("battle_mode", 0)) != 0:
        return f"BT:{int(state.get('battle_type', 0))}:{int(state.get('in_menu', 0))}:{int(state.get('battle_menu_pos', 0))}"
    if _same_map(state):
        dx = int(state.get("host_x", 0)) - int(state.get("x", 0))
        dy = int(state.get("host_y", 0)) - int(state.get("y", 0))
        return f"OWF:{int(state.get('map_group', 0))}:{int(state.get('map_number', 0))}:{max(-5, min(5, dx))}:{max(-5, min(5, dy))}"
    objective = (objective or "").lower()
    if "catch" in objective:
        goal = "catch"
    elif "train" in objective or "grind" in objective:
        goal = "train"
    elif "item" in objective:
        goal = "item"
    elif "gym" in objective or "badge" in objective:
        goal = "badge"
    else:
        goal = "story"
    return f"OWX:{int(state.get('map_group', 0))}:{int(state.get('map_number', 0))}:{goal}:{int(state.get('script_running', 0))}:{int(state.get('in_menu', 0))}"


@dataclass
class MetaStat:
    seen: int = 0
    progress: int = 0
    value: float = 0.0

    def update(self, reward: float, progress: bool) -> None:
        self.seen += 1
        self.value += float(reward)
        if progress:
            self.progress += 1

    def score(self) -> float:
        if self.seen <= 0:
            return 0.0
        avg = self.value / max(1, self.seen)
        prog = self.progress / max(1, self.seen)
        return (avg * 0.55) + (prog * 1.4)


@dataclass
class MetaPolicyRuntime:
    buckets: dict[str, dict[str, MetaStat]] = field(default_factory=lambda: defaultdict(dict))
    recent_progress_actions: deque = field(default_factory=lambda: deque(maxlen=24))
    recent_fail_actions: deque = field(default_factory=lambda: deque(maxlen=24))

    def observe_transition(
        self,
        prev_state: dict[str, Any],
        action: str,
        curr_state: dict[str, Any],
        reward_total: float,
        reward_signal: Any | None = None,
        objective: str = "",
    ) -> None:
        action = str(action or "NONE").upper()
        progress = bool(getattr(reward_signal, "progress", False))
        if not progress:
            if int(prev_state.get("x", 0)) != int(curr_state.get("x", 0)) or int(prev_state.get("y", 0)) != int(curr_state.get("y", 0)):
                progress = True
            elif int(prev_state.get("enemy_hp", 0)) > int(curr_state.get("enemy_hp", 0)) and int(curr_state.get("battle_mode", 0)) != 0:
                progress = True
            elif int(curr_state.get("dex_caught", 0)) > int(prev_state.get("dex_caught", 0)):
                progress = True
            elif int(curr_state.get("num_items", 0)) > int(prev_state.get("num_items", 0)):
                progress = True
            elif int(curr_state.get("badges_johto", 0)) != int(prev_state.get("badges_johto", 0)) or int(curr_state.get("badges_kanto", 0)) != int(prev_state.get("badges_kanto", 0)):
                progress = True
        bucket = _state_bucket(prev_state, objective)
        row = self.buckets.setdefault(bucket, {})
        stat = row.setdefault(action, MetaStat())
        shaped = _clamp(float(reward_total or 0.0), -3.0, 3.0)
        if progress:
            shaped += 0.55
            self.recent_progress_actions.append(action)
        else:
            self.recent_fail_actions.append(action)
        stat.update(shaped, progress)

    def score_actions(
        self,
        state: dict[str, Any],
        allowed: list[str],
        *,
        reward_state: dict[str, Any] | None = None,
        objective: str = "",
        map_name: str = "",
        guide_action: str | None = None,
        fallback: str | None = None,
        last_action: str | None = None,
        repeated_action_streak: int = 0,
        stuck_count: int = 0,
        desync_frames: int = 0,
    ) -> dict[str, float]:
        reward_state = reward_state or {}
        scores = {str(a): 0.0 for a in allowed}
        broccoli_pressure = float(reward_state.get("broccoli_pressure", 0.0) or 0.0)
        cookie_drive = float(reward_state.get("cookie_drive", 0.0) or 0.0)
        net_reward = float(reward_state.get("net_reward_score", 0.0) or 0.0)
        action_bias = min(2.8, 0.15 + (cookie_drive * 0.02))
        anti_idle = min(3.5, 0.35 + (broccoli_pressure * 0.05))

        bucket = _state_bucket(state, objective)
        for action, stat in self.buckets.get(bucket, {}).items():
            if action in scores:
                scores[action] += stat.score()

        if guide_action in scores:
            scores[guide_action] += action_bias + 0.45
        if fallback in scores:
            scores[fallback] += action_bias

        if int(state.get("battle_mode", 0)) != 0:
            if "NONE" in scores:
                scores["NONE"] -= anti_idle + 0.9
            if "A" in scores:
                scores["A"] += 1.15 + min(0.8, cookie_drive * 0.015)
            if "B" in scores and int(state.get("in_menu", 0)) != 0:
                scores["B"] += 0.25
            if int(state.get("enemy_hp", 0)) <= 30 and int(state.get("balls", 0)) > 0 and "A" in scores:
                scores["A"] += 0.45
        else:
            if _same_map(state):
                dx = int(state.get("host_x", 0)) - int(state.get("x", 0))
                dy = int(state.get("host_y", 0)) - int(state.get("y", 0))
                dist = abs(dx) + abs(dy)
                if dx > 0:
                    for a in ("RIGHT", "RIGHT_A"):
                        if a in scores:
                            scores[a] += 1.2 + min(1.1, dist * 0.12)
                elif dx < 0:
                    for a in ("LEFT", "LEFT_A"):
                        if a in scores:
                            scores[a] += 1.2 + min(1.1, dist * 0.12)
                if dy > 0:
                    for a in ("DOWN", "DOWN_A"):
                        if a in scores:
                            scores[a] += 1.2 + min(1.1, dist * 0.12)
                elif dy < 0:
                    for a in ("UP", "UP_A"):
                        if a in scores:
                            scores[a] += 1.2 + min(1.1, dist * 0.12)
                if dist <= 1 and int(state.get("script_running", 0)) == 0 and "A" in scores:
                    scores["A"] += 0.45
            else:
                for action in allowed:
                    if action in MOVEMENT_ACTIONS:
                        scores[action] += 0.15 + min(0.45, desync_frames * 0.003)

            if "NONE" in scores:
                scores["NONE"] -= anti_idle
            if int(state.get("script_running", 0)) != 0 or int(state.get("in_menu", 0)) != 0:
                if "A" in scores:
                    scores["A"] += 0.55
                if "B" in scores:
                    scores["B"] += 0.25
            if "catch" in (objective or "").lower() and int(state.get("balls", 0)) > 0 and "A" in scores:
                scores["A"] += 0.35
            if "item" in (objective or "").lower() and "A" in scores:
                scores["A"] += 0.25

        if last_action in scores and repeated_action_streak >= 3:
            scores[last_action] -= min(2.0, 0.35 * repeated_action_streak)
        opposite = OPPOSITE_ACTION.get(str(last_action or "").upper())
        if opposite in scores and repeated_action_streak >= 2 and stuck_count == 0:
            scores[opposite] -= 0.25

        # Reinforce actions that have recently produced actual progress.
        progress_hist = list(self.recent_progress_actions)[-10:]
        fail_hist = list(self.recent_fail_actions)[-10:]
        for action in set(progress_hist):
            if action in scores:
                scores[action] += min(0.8, progress_hist.count(action) * 0.12)
        for action in set(fail_hist):
            if action in scores:
                scores[action] -= min(0.9, fail_hist.count(action) * 0.10)

        if net_reward < -2.0:
            for action in allowed:
                if action in MOVEMENT_ACTIONS:
                    scores[action] += 0.18
            if guide_action in scores:
                scores[guide_action] += 0.35

        # Avoid weird menu-drifts when context is quiet.
        if int(state.get("battle_mode", 0)) == 0 and int(state.get("script_running", 0)) == 0 and int(state.get("in_menu", 0)) == 0:
            for action in ("START", "SELECT"):
                if action in scores:
                    scores[action] -= 0.75

        return scores
