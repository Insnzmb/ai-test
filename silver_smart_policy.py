#!/usr/bin/env python3
from __future__ import annotations

from collections import defaultdict, deque
from dataclasses import dataclass, field
from typing import Any
import math


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


def _clamp(value: int | float, lo: int | float, hi: int | float):
    return max(lo, min(hi, value))


def _base_action(action: str | None) -> str:
    raw = str(action or "NONE").upper()
    if raw.endswith("_A"):
        raw = raw[:-2]
    return raw


def _same_family(a: str | None, b: str | None) -> bool:
    return _base_action(a) == _base_action(b)


def _same_map(state: dict[str, Any]) -> bool:
    return (
        int(state.get("host_map_group", -1)) == int(state.get("map_group", -2))
        and int(state.get("host_map_number", -1)) == int(state.get("map_number", -2))
        and int(state.get("host_x", -999)) >= 0
        and int(state.get("host_y", -999)) >= 0
    )


def _map_key(state: dict[str, Any]) -> str:
    return f"{int(state.get('map_group', 0))}:{int(state.get('map_number', 0))}"


def _tile_key(state: dict[str, Any]) -> str:
    return (
        f"{_map_key(state)}:{int(state.get('x', 0))}:{int(state.get('y', 0))}:"
        f"{int(state.get('battle_mode', 0))}:{int(state.get('in_menu', 0))}:{int(state.get('script_running', 0))}"
    )


def _context_key(state: dict[str, Any]) -> str:
    if int(state.get("battle_mode", 0)) != 0:
        hp_bucket = int(_clamp(int(state.get("enemy_hp", 0)) // 20, 0, 12))
        return (
            f"BT:{int(state.get('battle_type', 0))}:{int(state.get('in_menu', 0))}:"
            f"{int(state.get('battle_menu_pos', 0))}:{int(state.get('balls', 0)) > 0}:{hp_bucket}"
        )
    if int(state.get("map_status", 0)) == 0:
        return (
            f"IN:{int(state.get('in_menu', 0))}:{int(state.get('script_running', 0))}:"
            f"{int(state.get('menu_y', 0))}:{int(state.get('menu_x', 0))}:{int(state.get('naming_type', 0))}"
        )
    if _same_map(state):
        dx = int(_clamp(int(state.get("host_x", 0)) - int(state.get("x", 0)), -4, 4))
        dy = int(_clamp(int(state.get("host_y", 0)) - int(state.get("y", 0)), -4, 4))
        return (
            f"OWF:{_map_key(state)}:{dx}:{dy}:{int(state.get('script_running', 0))}:"
            f"{int(state.get('in_menu', 0))}:{int(state.get('house_scene', 0))}"
        )
    return (
        f"OWX:{_map_key(state)}:{int(state.get('script_running', 0))}:"
        f"{int(state.get('in_menu', 0))}:{int(state.get('house_scene', 0))}:{int(state.get('map_status', 0))}"
    )


def _progress_happened(prev: dict[str, Any], curr: dict[str, Any], reward_signal: Any | None, reward_total: float) -> bool:
    if bool(getattr(reward_signal, "progress", False)):
        return True
    if int(prev.get("map_group", 0)) != int(curr.get("map_group", 0)):
        return True
    if int(prev.get("map_number", 0)) != int(curr.get("map_number", 0)):
        return True
    if int(prev.get("x", 0)) != int(curr.get("x", 0)) or int(prev.get("y", 0)) != int(curr.get("y", 0)):
        return True
    if int(prev.get("enemy_hp", 0)) > int(curr.get("enemy_hp", 0)) and int(curr.get("battle_mode", 0)) != 0:
        return True
    if int(curr.get("dex_caught", 0)) > int(prev.get("dex_caught", 0)):
        return True
    if int(curr.get("party_count", 0)) > int(prev.get("party_count", 0)):
        return True
    if int(curr.get("num_items", 0)) > int(prev.get("num_items", 0)):
        return True
    return float(reward_total or 0.0) > 0.2


@dataclass
class ActionStat:
    count: int = 0
    total: float = 0.0
    progress: int = 0
    fail: int = 0

    def update(self, reward: float, progress: bool) -> None:
        self.count += 1
        self.total += float(reward)
        if progress:
            self.progress += 1
        else:
            self.fail += 1

    def score(self) -> float:
        if self.count <= 0:
            return 0.0
        avg = self.total / max(1, self.count)
        progress_rate = self.progress / max(1, self.count)
        fail_rate = self.fail / max(1, self.count)
        return (avg * 0.85) + (progress_rate * 1.15) - (fail_rate * 0.65)


@dataclass
class SmartPolicyRuntime:
    context_stats: dict[str, dict[str, ActionStat]] = field(default_factory=lambda: defaultdict(dict))
    tile_failures: dict[str, dict[str, int]] = field(default_factory=lambda: defaultdict(dict))
    map_success: dict[str, dict[str, int]] = field(default_factory=lambda: defaultdict(dict))
    recent_tiles: deque = field(default_factory=lambda: deque(maxlen=96))
    recent_actions: deque = field(default_factory=lambda: deque(maxlen=48))
    _demo_cache: dict[tuple[str, tuple[str, ...], int], dict[str, float]] = field(default_factory=dict)

    def observe_transition(
        self,
        prev_state: dict[str, Any],
        action: str,
        curr_state: dict[str, Any],
        reward_total: float,
        reward_signal: Any | None = None,
        guide_action: str | None = None,
    ) -> None:
        action = str(action or "NONE").upper()
        context = _context_key(prev_state)
        row = self.context_stats.setdefault(context, {})
        stat = row.setdefault(action, ActionStat())
        progress = _progress_happened(prev_state, curr_state, reward_signal, reward_total)
        shaped_reward = float(reward_total or 0.0)
        if progress:
            shaped_reward += 0.45
        if guide_action and _same_family(action, guide_action):
            shaped_reward += 0.15
        stat.update(max(-3.0, min(3.0, shaped_reward)), progress)

        prev_tile = _tile_key(prev_state)
        if progress:
            if action in MOVEMENT_ACTIONS:
                map_row = self.map_success.setdefault(_map_key(prev_state), {})
                map_row[action] = int(map_row.get(action, 0)) + 1
            # A progress event from a tile should soften prior tile failure bias.
            fail_row = self.tile_failures.get(prev_tile, {})
            if action in fail_row:
                fail_row[action] = max(0, int(fail_row.get(action, 0)) - 1)
        else:
            if action in MOVEMENT_ACTIONS or action in {"A", "B", "START", "NONE"}:
                fail_row = self.tile_failures.setdefault(prev_tile, {})
                fail_row[action] = min(12, int(fail_row.get(action, 0)) + 1)

        self.recent_tiles.append((_map_key(curr_state), int(curr_state.get("x", 0)), int(curr_state.get("y", 0))))
        self.recent_actions.append(action)

        if len(self._demo_cache) > 256:
            # Brutally simple cache eviction. No drama, no parquet cathedral.
            self._demo_cache.clear()

    def _similarity(self, state: dict[str, Any], other_key: str) -> float:
        if not other_key:
            return 0.0
        cur_battle = int(state.get("battle_mode", 0)) != 0
        if cur_battle:
            parts = other_key.split(":")
            if len(parts) != 8 or parts[0] != "BT":
                return 0.0
            try:
                battle_mode = int(parts[1])
                battle_type = int(parts[2])
                in_menu = int(parts[3])
                menu_y = int(parts[4])
                menu_x = int(parts[5])
                balls = 1 if parts[6] in {"1", "True", "true"} else 0
                hp_bucket = int(parts[7])
            except ValueError:
                return 0.0
            score = 0.0
            if battle_mode == int(state.get("battle_mode", 0)):
                score += 1.0
            if battle_type == int(state.get("battle_type", 0)):
                score += 2.5
            if in_menu == int(state.get("in_menu", 0)):
                score += 1.8
            score += max(0.0, 0.6 - abs(menu_y - int(state.get("menu_y", 0))) * 0.25)
            score += max(0.0, 0.6 - abs(menu_x - int(state.get("menu_x", 0))) * 0.25)
            score += max(0.0, 1.2 - (abs(hp_bucket - int(_clamp(int(state.get("enemy_hp", 0)) // 15, 0, 15))) * 0.2))
            if balls == (1 if int(state.get("balls", 0)) > 0 else 0):
                score += 0.9
            return score

        if _same_map(state):
            parts = other_key.split(":")
            if len(parts) < 7 or parts[0] != "OW":
                return 0.0
            try:
                same_flag = int(parts[1])
            except ValueError:
                return 0.0
            if same_flag != 1:
                return 0.0
            try:
                dx = int(parts[2])
                dy = int(parts[3])
                script_running = int(parts[4])
                in_menu = int(parts[5])
            except ValueError:
                return 0.0
            cur_dx = int(_clamp(int(state.get("host_x", 0)) - int(state.get("x", 0)), -6, 6))
            cur_dy = int(_clamp(int(state.get("host_y", 0)) - int(state.get("y", 0)), -6, 6))
            score = 2.0
            score += max(0.0, 1.5 - (abs(dx - cur_dx) * 0.25))
            score += max(0.0, 1.5 - (abs(dy - cur_dy) * 0.25))
            if script_running == int(state.get("script_running", 0)):
                score += 0.7
            if in_menu == int(state.get("in_menu", 0)):
                score += 0.6
            return score

        if int(state.get("map_status", 0)) == 0:
            parts = other_key.split(":")
            tag = parts[0] if parts else ""
            # IN keys: "IN:im:sr:my:mx" → 5 parts
            if tag == "IN" and len(parts) == 5:
                score = 1.0
                try:
                    if int(parts[1]) == int(state.get("in_menu", 0)):
                        score += 1.3
                    if int(parts[2]) == int(state.get("script_running", 0)):
                        score += 1.0
                    score += max(0.0, 0.7 - abs(int(parts[3]) - int(state.get("menu_y", 0))) * 0.3)
                    score += max(0.0, 0.7 - abs(int(parts[4]) - int(state.get("menu_x", 0))) * 0.3)
                except ValueError:
                    return 0.0
                return score
            # NM/NC keys: "NM:my:mx:sr" → 4 parts
            if tag in {"NM", "NC"} and len(parts) == 4:
                score = 1.0
                try:
                    score += max(0.0, 0.7 - abs(int(parts[1]) - int(state.get("menu_y", 0))) * 0.3)
                    score += max(0.0, 0.7 - abs(int(parts[2]) - int(state.get("menu_x", 0))) * 0.3)
                    if int(parts[3]) == int(state.get("script_running", 0)):
                        score += 1.0
                except ValueError:
                    return 0.0
                return score
            return 0.0

        if other_key.startswith("OW:0:"):
            parts = other_key.split(":")
            # OW:0 keys: "OW:0:sr:im:hs" → 5 parts
            if len(parts) != 5:
                return 0.0
            score = 1.2
            try:
                if int(parts[2]) == int(state.get("script_running", 0)):
                    score += 0.8
                if int(parts[3]) == int(state.get("in_menu", 0)):
                    score += 0.8
                if int(parts[4]) == int(state.get("house_scene", 0)):
                    score += 0.6
            except ValueError:
                return 0.0
            return score
        return 0.0

    def _nearest_demo_scores(
        self,
        state: dict[str, Any],
        clone_table: dict[str, dict[str, float]],
        allowed: list[str],
    ) -> dict[str, float]:
        cache_key = (_context_key(state), tuple(allowed), len(clone_table))
        cached = self._demo_cache.get(cache_key)
        if cached is not None:
            return dict(cached)

        allowed_set = set(allowed)
        scored_matches: list[tuple[float, dict[str, float]]] = []
        for other_key, row in clone_table.items():
            if not isinstance(row, dict):
                continue
            sim = self._similarity(state, other_key)
            if sim <= 0.0:
                continue
            filtered = {a: float(v) for a, v in row.items() if a in allowed_set}
            if not filtered:
                continue
            scored_matches.append((sim, filtered))

        scored_matches.sort(key=lambda item: item[0], reverse=True)
        scored_matches = scored_matches[:24]

        aggregated = {a: 0.0 for a in allowed}
        for sim, row in scored_matches:
            scale = min(3.6, sim)
            for action, value in row.items():
                aggregated[action] = aggregated.get(action, 0.0) + (math.log1p(max(0.0, value)) * scale * 0.42)

        self._demo_cache[cache_key] = dict(aggregated)
        return aggregated

    def _movement_vector_bonus(self, state: dict[str, Any], action: str) -> float:
        if action not in MOVEMENT_ACTIONS:
            return 0.0
        if not _same_map(state):
            return 0.0
        dx = int(state.get("host_x", 0)) - int(state.get("x", 0))
        dy = int(state.get("host_y", 0)) - int(state.get("y", 0))
        if dx == 0 and dy == 0:
            return 0.0
        score = 0.0
        base = _base_action(action)
        if dx > 0 and base == "RIGHT":
            score += 1.7 + min(1.0, abs(dx) * 0.15)
        if dx < 0 and base == "LEFT":
            score += 1.7 + min(1.0, abs(dx) * 0.15)
        if dy > 0 and base == "DOWN":
            score += 1.7 + min(1.0, abs(dy) * 0.15)
        if dy < 0 and base == "UP":
            score += 1.7 + min(1.0, abs(dy) * 0.15)
        if score <= 0.0:
            return -0.35
        return score

    def score_actions(
        self,
        state: dict[str, Any],
        allowed: list[str],
        *,
        memory_clone: dict[str, dict[str, float]] | None = None,
        guide_action: str | None = None,
        heuristic: str | None = None,
        fallback: str | None = None,
        q_best: str | None = None,
        clone_best: str | None = None,
        ollama_pick: str | None = None,
        last_action: str | None = None,
        action_history: Any = None,
        stuck_count: int = 0,
        repeated_action_streak: int = 0,
        intro_stall_frames: int = 0,
        desync_frames: int = 0,
    ) -> dict[str, float]:
        scores = {action: 0.0 for action in allowed}
        context = _context_key(state)
        row = self.context_stats.get(context, {})
        for action, stat in row.items():
            if action in scores:
                scores[action] += stat.score() * 0.75

        if memory_clone:
            demo_scores = self._nearest_demo_scores(state, memory_clone, allowed)
            for action, value in demo_scores.items():
                scores[action] = scores.get(action, 0.0) + value

        map_row = self.map_success.get(_map_key(state), {})
        map_total = sum(int(v) for v in map_row.values())
        if map_total > 0:
            for action in allowed:
                local = int(map_row.get(action, 0) or 0)
                if local > 0:
                    scores[action] += min(1.15, (local / map_total) * 5.0)

        tile_fail = self.tile_failures.get(_tile_key(state), {})
        for action in allowed:
            failures = int(tile_fail.get(action, 0) or 0)
            if failures > 0:
                scores[action] -= min(2.6, failures * 0.48)

        if guide_action in scores:
            scores[guide_action] += 1.45
        if heuristic in scores:
            scores[heuristic] += 0.95
        if fallback in scores:
            scores[fallback] += 0.8
        if q_best in scores:
            scores[q_best] += 0.45
        if clone_best in scores:
            scores[clone_best] += 0.65
        if ollama_pick in scores:
            scores[ollama_pick] += 0.3

        for action in allowed:
            scores[action] += self._movement_vector_bonus(state, action)

        if state.get("battle_mode", 0):
            if "NONE" in scores:
                scores["NONE"] -= 2.5
            if int(state.get("script_running", 0)) != 0 and "A" in scores:
                scores["A"] += 2.6
            if int(state.get("in_menu", 0)) == 0 and "A" in scores:
                scores["A"] += 1.2
        else:
            if int(state.get("script_running", 0)) != 0 and "A" in scores:
                scores["A"] += 2.0
            if int(state.get("in_menu", 0)) != 0 and "A" in scores:
                scores["A"] += 1.2
            if not _same_map(state) and desync_frames >= 36 and guide_action in scores:
                scores[guide_action] += 1.2

        if last_action in MOVEMENT_ACTIONS:
            for action in allowed:
                if action in MOVEMENT_ACTIONS and OPPOSITE_ACTION.get(action) == last_action and stuck_count < 5:
                    scores[action] -= 1.0
                elif action == last_action and repeated_action_streak >= 4 and stuck_count == 0:
                    scores[action] -= min(1.2, repeated_action_streak * 0.12)

        if stuck_count >= 4 or intro_stall_frames >= 48:
            for action in allowed:
                if action == last_action:
                    scores[action] -= 0.9
                if action == "NONE":
                    scores[action] -= 1.8
                if action in MOVEMENT_ACTIONS and action != last_action:
                    scores[action] += 0.55
                if action == "A":
                    scores[action] += 0.45
        if stuck_count >= 8:
            recently_used = set(list(self.recent_actions)[-6:])
            for action in allowed:
                if action not in recently_used:
                    scores[action] += 0.5

        # Tiny nudge away from sitting on the same tile forever. The machine yearns for progress.
        if len(self.recent_tiles) >= 8:
            current_triplet = (_map_key(state), int(state.get("x", 0)), int(state.get("y", 0)))
            visits = sum(1 for item in self.recent_tiles if item == current_triplet)
            if visits >= 5:
                if "NONE" in scores:
                    scores["NONE"] -= 1.4
                for action in allowed:
                    if action in MOVEMENT_ACTIONS:
                        scores[action] += 0.22

        return scores

    def choose_action(self, scores: dict[str, float], allowed: list[str]) -> str:
        best = allowed[0] if allowed else "NONE"
        best_score = -10**9
        for action in allowed:
            value = float(scores.get(action, 0.0))
            if value > best_score:
                best = action
                best_score = value
        return best
