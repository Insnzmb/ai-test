#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import time
import uuid
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 3
MAX_SNAPSHOT_SHARD_BYTES = 750_000
MAX_EVENT_SHARD_BYTES = 750_000
MAX_REWARD_SHARD_BYTES = 500_000

# Q-table size cap: evict near-zero entries when this limit is exceeded.
# Prevents unbounded JSON growth over long training runs.
MAX_Q_STATES = 8_000
Q_PRUNE_CAPACITY = int(MAX_Q_STATES * 0.80)  # prune back to 80 % after cap hit
Q_PRUNE_THRESHOLD = 0.02                       # magnitude below which a state is "not learned"
SHARED_LOCK_TIMEOUT = 20.0
SHARED_LOCK_STALE_SECONDS = 120.0
REWARD_FLOAT_FIELDS = (
    'cookies_total',
    'broccoli_total',
    'broccoli_burn_total',
    'stall_cookie_total',
    'stall_broccoli_total',
    'idle_broccoli_total',
    'mood_score',
)
REWARD_INT_FIELDS = (
    'cookie_events',
    'broccoli_events',
    'guide_aligned',
    'guide_misaligned',
    'idle_broccoli_events',
)


def _now() -> int:
    return int(time.time())


def _json_dump(data: Any) -> str:
    return json.dumps(data, indent=2, sort_keys=True)


def _json_dump_compact(data: Any) -> str:
    return json.dumps(data, separators=(",", ":"), sort_keys=True)


def _write_text_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    last_error: Exception | None = None
    for attempt in range(40):
        tmp = path.with_name(f"{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
        try:
            tmp.write_text(text, encoding='utf-8')
            os.replace(str(tmp), str(path))
            return
        except PermissionError as exc:
            last_error = exc
            try:
                tmp.unlink()
            except OSError:
                pass
            time.sleep(0.05 * (attempt + 1))
        except OSError as exc:
            last_error = exc
            try:
                tmp.unlink()
            except OSError:
                pass
            time.sleep(0.02 * (attempt + 1))
    if last_error is not None:
        raise last_error
    raise OSError(f"atomic write failed for {path}")


def _write_json_atomic(path: Path, data: Any) -> None:
    _write_text_atomic(path, _json_dump(data))


def _read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except Exception:
        return default


def _delete_matching(directory: Path, pattern: str) -> None:
    if not directory.exists():
        return
    for item in directory.glob(pattern):
        try:
            item.unlink()
        except OSError:
            pass


def _chunk_dict_by_size(data: dict[str, Any], max_bytes: int) -> list[dict[str, Any]]:
    items = sorted(data.items(), key=lambda kv: kv[0])
    if not items:
        return [{}]
    chunks: list[dict[str, Any]] = []
    current: dict[str, Any] = {}
    current_size = 2
    for key, value in items:
        trial = {key: value}
        trial_size = len(_json_dump_compact(trial).encode('utf-8'))
        if current and (current_size + trial_size) > max_bytes:
            chunks.append(current)
            current = {}
            current_size = 2
        current[key] = value
        current_size += trial_size
    if current or not chunks:
        chunks.append(current)
    return chunks


def _load_sharded_dict(directory: Path, stem: str, file_names: list[str] | None = None) -> dict[str, Any]:
    merged: dict[str, Any] = {}
    if not directory.exists():
        return merged
    paths: list[Path]
    if file_names:
        paths = [directory / name for name in file_names]
    else:
        paths = sorted(directory.glob(f'{stem}_*.json'))
    for path in paths:
        data = _read_json(path, {})
        if isinstance(data, dict):
            merged.update(data)
    return merged


def _generation_token() -> str:
    return f"g{time.time_ns()}_{os.getpid()}"


def _write_sharded_dict(directory: Path, stem: str, data: dict[str, Any], max_bytes: int, *, generation: str | None = None) -> list[str]:
    directory.mkdir(parents=True, exist_ok=True)
    chunks = _chunk_dict_by_size(data, max_bytes)
    token = generation or _generation_token()
    names: list[str] = []
    for index, chunk in enumerate(chunks, 1):
        name = f'{stem}_{token}_{index:04d}.json'
        path = directory / name
        _write_json_atomic(path, chunk)
        names.append(name)
    return names


class SilverMemoryStore:
    def __init__(self, requested_path: Path):
        self.requested_path = Path(requested_path)
        self.q: dict[str, dict[str, float]] = {}
        self.clone: dict[str, dict[str, float]] = {}
        self.steps = 0
        self.bad: list[dict[str, Any]] = []
        self.rewards: dict[str, Any] = self._default_rewards()

        self.store_root, self.legacy_file = self._resolve_paths(self.requested_path)
        self.snapshots_dir = self.store_root / 'snapshots'
        self.events_dir = self.store_root / 'events'
        self.rewards_dir = self.store_root / 'rewards'
        self.meta_file = self.store_root / 'meta.json'
        self.manifest_file = self.store_root / 'manifest.json'
        self.latest_export_file = self.store_root / 'silver_agent_memory_latest.json'
        self.reward_state_file = self.rewards_dir / 'reward_state.json'
        self.lock_file = self.store_root / '.memory.lock'

        self._save_baseline_steps = 0
        self._save_baseline_reward_floats: dict[str, float] = {}
        self._save_baseline_reward_ints: dict[str, int] = {}
        self._save_baseline_bad_signatures: set[str] = set()
        self._save_baseline_recent_len = 0

        self.load()

    @staticmethod
    def _resolve_paths(requested: Path) -> tuple[Path, Path | None]:
        requested = requested.expanduser()
        if requested.suffix.lower() == '.json':
            store_root = requested.parent / 'training_data'
            legacy_file = requested
            return store_root, legacy_file
        if requested.name.lower().endswith('training_data') or requested.is_dir() or not requested.suffix:
            store_root = requested
            legacy_file = requested.parent / 'silver_agent_memory.json'
            return store_root, legacy_file
        store_root = requested.parent / 'training_data'
        legacy_file = requested if requested.suffix else requested.parent / 'silver_agent_memory.json'
        return store_root, legacy_file

    def _default_payload(self) -> dict[str, Any]:
        return {'q': {}, 'clone': {}, 'steps': 0, 'bad': [], 'rewards': self._default_rewards()}

    @staticmethod
    def _default_rewards() -> dict[str, Any]:
        return {
            'cookies_total': 0.0,
            'broccoli_total': 0.0,
            'broccoli_burn_total': 0.0,
            'cookie_events': 0,
            'broccoli_events': 0,
            'guide_aligned': 0,
            'guide_misaligned': 0,
            'stall_cookie_total': 0.0,
            'stall_broccoli_total': 0.0,
            'idle_broccoli_total': 0.0,
            'idle_broccoli_events': 0,
            'broccoli_dislike': 1.35,
            'mood_score': 0.0,
            'mood': 'steady',
            'last_reason': '',
            'recent': [],
        }

    def _normalize_rewards(self, rewards: Any) -> dict[str, Any]:
        base = self._default_rewards()
        if isinstance(rewards, dict):
            for key in base:
                if key in rewards:
                    base[key] = rewards[key]
        base['cookies_total'] = round(float(base.get('cookies_total', 0.0) or 0.0), 3)
        base['broccoli_total'] = round(float(base.get('broccoli_total', 0.0) or 0.0), 3)
        base['broccoli_burn_total'] = round(float(base.get('broccoli_burn_total', 0.0) or 0.0), 3)
        base['stall_cookie_total'] = round(float(base.get('stall_cookie_total', 0.0) or 0.0), 3)
        base['stall_broccoli_total'] = round(float(base.get('stall_broccoli_total', 0.0) or 0.0), 3)
        base['idle_broccoli_total'] = round(float(base.get('idle_broccoli_total', 0.0) or 0.0), 3)
        base['broccoli_dislike'] = round(float(base.get('broccoli_dislike', 1.35) or 1.35), 3)
        base['mood_score'] = round(float(base.get('mood_score', 0.0) or 0.0), 3)
        base['cookie_events'] = int(base.get('cookie_events', 0) or 0)
        base['broccoli_events'] = int(base.get('broccoli_events', 0) or 0)
        base['idle_broccoli_events'] = int(base.get('idle_broccoli_events', 0) or 0)
        base['guide_aligned'] = int(base.get('guide_aligned', 0) or 0)
        base['guide_misaligned'] = int(base.get('guide_misaligned', 0) or 0)
        base['last_reason'] = str(base.get('last_reason', '') or '')
        base['recent'] = list(base.get('recent', []) or [])[-80:]
        base['broccoli_dislike'] = self._derive_broccoli_dislike(base)
        base['mood'] = self._derive_mood(base['mood_score'])
        return base

    def _payload(self) -> dict[str, Any]:
        return {
            'q': self.q,
            'clone': self.clone,
            'steps': int(self.steps),
            'bad': list(self.bad[-120:]),
            'rewards': self.reward_snapshot(),
        }

    @staticmethod
    def _merge_action_tables(dest: dict[str, dict[str, float]], src: dict[str, dict[str, Any]]) -> None:
        for state_key, row in (src or {}).items():
            if not isinstance(row, dict):
                continue
            dst_row = dest.setdefault(state_key, {})
            for action, value in row.items():
                try:
                    fval = float(value)
                except (TypeError, ValueError):
                    continue
                if action not in dst_row or abs(fval) > abs(float(dst_row[action])):
                    dst_row[action] = fval

    @staticmethod
    def _event_signature(item: Any) -> str:
        try:
            return _json_dump_compact(item)
        except Exception:
            return repr(item)

    def _reset_save_baseline(self) -> None:
        self._save_baseline_steps = int(self.steps)
        self._save_baseline_reward_floats = {
            key: float(self.rewards.get(key, 0.0) or 0.0)
            for key in REWARD_FLOAT_FIELDS
        }
        self._save_baseline_reward_ints = {
            key: int(self.rewards.get(key, 0) or 0)
            for key in REWARD_INT_FIELDS
        }
        self._save_baseline_bad_signatures = {self._event_signature(item) for item in self.bad}
        self._save_baseline_recent_len = len(list(self.rewards.get('recent', []) or []))

    def _acquire_lock(self, timeout: float = SHARED_LOCK_TIMEOUT) -> bool:
        deadline = time.time() + max(0.5, float(timeout or 0.5))
        while time.time() < deadline:
            try:
                self.store_root.mkdir(parents=True, exist_ok=True)
                fd = os.open(str(self.lock_file), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                with os.fdopen(fd, 'w', encoding='utf-8') as handle:
                    handle.write(f"pid={os.getpid()} t={time.time()}\n")
                return True
            except FileExistsError:
                try:
                    age = time.time() - self.lock_file.stat().st_mtime
                    if age >= SHARED_LOCK_STALE_SECONDS:
                        self.lock_file.unlink()
                        continue
                except OSError:
                    pass
                time.sleep(0.10)
            except OSError:
                time.sleep(0.10)
        return False

    def _release_lock(self) -> None:
        try:
            self.lock_file.unlink()
        except OSError:
            pass

    def _read_disk_payload(self) -> dict[str, Any]:
        payload = self._default_payload()
        for candidate in (self.latest_export_file, self.legacy_file):
            if candidate is not None and candidate.exists():
                data = _read_json(candidate, None)
                if isinstance(data, dict):
                    payload['q'] = dict(data.get('q', {}) or {})
                    payload['clone'] = dict(data.get('clone', {}) or {})
                    payload['steps'] = int(data.get('steps', 0) or 0)
                    payload['bad'] = list(data.get('bad', []) or [])[-120:]
                    payload['rewards'] = self._normalize_rewards(data.get('rewards', None))
                    return payload
        meta = _read_json(self.meta_file, {})
        if isinstance(meta, dict) and self.snapshots_dir.exists():
            payload['q'] = _load_sharded_dict(self.snapshots_dir, 'q', list(meta.get('q_files', []) or []))
            payload['clone'] = _load_sharded_dict(self.snapshots_dir, 'clone', list(meta.get('clone_files', []) or []))
            payload['steps'] = int(meta.get('steps', 0) or 0)
            payload['bad'] = list(meta.get('bad', []) or [])[-120:]
            reward_payload = _read_json(self.reward_state_file, meta.get('rewards', None))
            payload['rewards'] = self._normalize_rewards(reward_payload)
        return payload

    def load(self) -> None:
        self.q = {}
        self.clone = {}
        self.steps = 0
        self.bad = []
        self.rewards = self._default_rewards()

        loaded = False
        meta = _read_json(self.meta_file, {})
        if isinstance(meta, dict) and self.snapshots_dir.exists():
            self.q = _load_sharded_dict(self.snapshots_dir, 'q', list(meta.get('q_files', []) or []))
            self.clone = _load_sharded_dict(self.snapshots_dir, 'clone', list(meta.get('clone_files', []) or []))
            if self.q or self.clone or meta:
                self.steps = int(meta.get('steps', 0) or 0)
                self.bad = list(meta.get('bad', []) or [])[-120:]
                loaded = True

        payload = None
        if not loaded and self.legacy_file and self.legacy_file.exists():
            payload = _read_json(self.legacy_file, self._default_payload())
            if isinstance(payload, dict):
                self.q = dict(payload.get('q', {}) or {})
                self.clone = dict(payload.get('clone', {}) or {})
                self.steps = int(payload.get('steps', 0) or 0)
                self.bad = list(payload.get('bad', []) or [])[-120:]
                loaded = True

        if not loaded and self.latest_export_file.exists():
            payload = _read_json(self.latest_export_file, self._default_payload())
            if isinstance(payload, dict):
                self.q = dict(payload.get('q', {}) or {})
                self.clone = dict(payload.get('clone', {}) or {})
                self.steps = int(payload.get('steps', 0) or 0)
                self.bad = list(payload.get('bad', []) or [])[-120:]

        reward_payload = _read_json(self.reward_state_file, None)
        if reward_payload is None and isinstance(payload, dict):
            reward_payload = payload.get('rewards', None)
        if reward_payload is None and isinstance(meta, dict):
            reward_payload = meta.get('rewards', None)
        self.rewards = self._normalize_rewards(reward_payload)
        self._reset_save_baseline()

    def hot_reload_q(self) -> None:
        """Merge the on-disk Q-table and clone table into the current in-memory tables.

        Called every 5 seconds by the agent loop so it picks up merged training data
        written by the 10x training runner without losing its own unsaved updates.
        Steps, bad-list, and rewards are intentionally left untouched.

        Merge strategy: for each (state, action) pair keep the value with the
        larger absolute magnitude so neither source's strong learned preferences
        are overwritten by a weaker one.
        """
        fresh_q: dict[str, dict[str, float]] = {}
        fresh_clone: dict[str, dict[str, float]] = {}

        # Never read mid-save on Windows; replacing files while another
        # process has them open causes WinError 5. Skip this cycle and retry
        # on the next 5-second hot reload tick.
        if self.lock_file.exists():
            return

        # Prefer the sharded snapshot directory (written by SilverMemoryStore.save)
        meta = _read_json(self.meta_file, {})
        if isinstance(meta, dict) and self.snapshots_dir.exists():
            fresh_q = _load_sharded_dict(self.snapshots_dir, 'q', list(meta.get('q_files', []) or []))
            fresh_clone = _load_sharded_dict(self.snapshots_dir, 'clone', list(meta.get('clone_files', []) or []))

        # Fall back to the legacy flat JSON file
        if not fresh_q and not fresh_clone:
            for candidate in (self.legacy_file, self.latest_export_file):
                if candidate and candidate.exists():
                    payload = _read_json(candidate, {})
                    if isinstance(payload, dict):
                        fresh_q = dict(payload.get('q', {}) or {})
                        fresh_clone = dict(payload.get('clone', {}) or {})
                    if fresh_q or fresh_clone:
                        break

        def _merge(dest: dict, src: dict) -> None:
            for sk, actions in src.items():
                if not isinstance(actions, dict):
                    continue
                if sk not in dest:
                    dest[sk] = dict(actions)
                else:
                    row = dest[sk]
                    for act, val in actions.items():
                        try:
                            fval = float(val)
                        except (TypeError, ValueError):
                            continue
                        if act not in row or abs(fval) > abs(float(row[act])):
                            row[act] = fval

        _merge(self.q, fresh_q)
        _merge(self.clone, fresh_clone)

    def _current_event_shard(self) -> Path:
        self.events_dir.mkdir(parents=True, exist_ok=True)
        existing = sorted(self.events_dir.glob('events_*.jsonl'))
        if not existing:
            return self.events_dir / 'events_0001.jsonl'
        current = existing[-1]
        try:
            size = current.stat().st_size
        except OSError:
            size = 0
        if size >= MAX_EVENT_SHARD_BYTES:
            try:
                current_index = int(current.stem.split('_')[-1])
            except Exception:
                current_index = len(existing)
            return self.events_dir / f'events_{current_index + 1:04d}.jsonl'
        return current

    def _current_reward_shard(self) -> Path:
        self.rewards_dir.mkdir(parents=True, exist_ok=True)
        existing = sorted(self.rewards_dir.glob('reward_events_*.jsonl'))
        if not existing:
            return self.rewards_dir / 'reward_events_0001.jsonl'
        current = existing[-1]
        try:
            size = current.stat().st_size
        except OSError:
            size = 0
        if size >= MAX_REWARD_SHARD_BYTES:
            try:
                current_index = int(current.stem.split('_')[-1])
            except Exception:
                current_index = len(existing)
            return self.rewards_dir / f'reward_events_{current_index + 1:04d}.jsonl'
        return current

    def append_event(self, kind: str, payload: dict[str, Any]) -> None:
        record = {'t': _now(), 'kind': kind, **payload}
        try:
            shard = self._current_event_shard()
            with shard.open('a', encoding='utf-8') as handle:
                handle.write(_json_dump_compact(record) + "\n")
        except OSError:
            pass

    @staticmethod
    def _derive_broccoli_dislike(rewards: dict[str, Any]) -> float:
        total = float(rewards.get('broccoli_total', 0.0) or 0.0)
        total += float(rewards.get('stall_broccoli_total', 0.0) or 0.0) * 0.35
        total += float(rewards.get('idle_broccoli_total', 0.0) or 0.0) * 0.85
        return round(1.35 + min(4.65, total / 18.0), 3)

    @staticmethod
    def _derive_mood(score: float) -> str:
        if score >= 20:
            return 'ecstatic'
        if score >= 8:
            return 'happy'
        if score >= 2:
            return 'content'
        if score > -2:
            return 'steady'
        if score > -8:
            return 'annoyed'
        if score > -18:
            return 'sad'
        return 'broccoli_misery'

    @staticmethod
    def _summarize_reward_recent(recent: list[dict[str, Any]]) -> str:
        if not recent:
            return 'none'
        pieces: list[str] = []
        for item in recent[-5:]:
            kind = str(item.get('kind', '') or '').strip() or 'feedback'
            amount = float(item.get('amount', 0.0) or 0.0)
            reason = str(item.get('reason', '') or '').strip()
            if len(reason) > 64:
                reason = reason[:64] + '…'
            if reason:
                pieces.append(f"{kind}:{amount:.2f}:{reason}")
            else:
                pieces.append(f"{kind}:{amount:.2f}")
        return ' | '.join(pieces)

    def reward_snapshot(self) -> dict[str, Any]:
        snap = json.loads(json.dumps(self.rewards))
        cookies = float(snap.get('cookies_total', 0.0) or 0.0)
        broccoli = float(snap.get('broccoli_total', 0.0) or 0.0)
        burn = float(snap.get('broccoli_burn_total', 0.0) or 0.0)
        misaligned = int(snap.get('guide_misaligned', 0) or 0)
        aligned = int(snap.get('guide_aligned', 0) or 0)
        snap['net_reward_score'] = round(cookies + (burn * 0.8) - (broccoli * 1.8), 3)
        snap['broccoli_pressure'] = round(broccoli * max(1.0, float(snap.get('broccoli_dislike', 1.35) or 1.35)), 3)
        snap['cookie_drive'] = round(cookies + burn + max(0, aligned - misaligned) * 0.12, 3)
        snap['discipline_ratio'] = round((cookies + burn + 1.0) / (1.0 + broccoli + max(0, misaligned - aligned) * 0.35), 3)
        snap['reward_recent_summary'] = self._summarize_reward_recent(list(snap.get('recent', []) or []))
        if snap['broccoli_pressure'] >= max(6.0, snap['cookie_drive'] * 1.15):
            directive = 'AVOID_BROCCOLI: move with purpose, break stalls fast, do not stand still, do not loop, obey guide/proven progress.'
        elif snap['cookie_drive'] >= max(4.0, snap['broccoli_pressure'] * 0.8):
            directive = 'CHASE_COOKIES: push productive movement, interactions, battle progress, catches, items, and badges now.'
        else:
            directive = 'STAY_DISCIPLINED: follow guide, maintain momentum, prefer proven useful actions over random ones.'
        snap['reward_directive'] = directive
        return snap

    def reward_context(self) -> str:
        snap = self.reward_snapshot()
        return (
            f"mood={snap.get('mood', 'steady')} cookies={snap.get('cookies_total', 0.0):.2f} "
            f"broccoli={snap.get('broccoli_total', 0.0):.2f} burn={snap.get('broccoli_burn_total', 0.0):.2f} "
            f"dislike={snap.get('broccoli_dislike', 1.35):.2f} "
            f"aligned={snap.get('guide_aligned', 0)} misaligned={snap.get('guide_misaligned', 0)}"
        )

    def _apply_feedback(
        self,
        kind: str,
        amount: float,
        *,
        reason: str = '',
        state_key: str = '',
        action: str = '',
        guide_action: str = '',
        stall_frames: int = 0,
        count_alignment: bool = False,
        aligned: bool | None = None,
        broccoli_reduction: float = 0.0,
    ) -> None:
        amount = round(max(0.0, float(amount or 0.0)), 3)
        broccoli_reduction = round(max(0.0, float(broccoli_reduction or 0.0)), 3)
        if amount <= 0 and broccoli_reduction <= 0:
            return
        snap = self.rewards
        if count_alignment:
            if aligned is True:
                snap['guide_aligned'] = int(snap.get('guide_aligned', 0) or 0) + 1
            elif aligned is False:
                snap['guide_misaligned'] = int(snap.get('guide_misaligned', 0) or 0) + 1
        if kind == 'cookie':
            snap['cookies_total'] = round(float(snap.get('cookies_total', 0.0) or 0.0) + amount, 3)
            snap['cookie_events'] = int(snap.get('cookie_events', 0) or 0) + (1 if amount > 0 else 0)
            snap['mood_score'] = round(float(snap.get('mood_score', 0.0) or 0.0) + (amount * 1.0), 3)
            if stall_frames > 0 and amount > 0:
                snap['stall_cookie_total'] = round(float(snap.get('stall_cookie_total', 0.0) or 0.0) + amount, 3)
            if broccoli_reduction > 0:
                current_broccoli = float(snap.get('broccoli_total', 0.0) or 0.0)
                actual_burn = round(min(current_broccoli, broccoli_reduction), 3)
                if actual_burn > 0:
                    snap['broccoli_total'] = round(max(0.0, current_broccoli - actual_burn), 3)
                    snap['broccoli_burn_total'] = round(float(snap.get('broccoli_burn_total', 0.0) or 0.0) + actual_burn, 3)
                    snap['mood_score'] = round(float(snap.get('mood_score', 0.0) or 0.0) + (actual_burn * 0.7), 3)
        elif kind == 'broccoli':
            snap['broccoli_total'] = round(float(snap.get('broccoli_total', 0.0) or 0.0) + amount, 3)
            snap['broccoli_events'] = int(snap.get('broccoli_events', 0) or 0) + 1
            dislike = max(1.35, float(snap.get('broccoli_dislike', 1.35) or 1.35))
            mood_hit = amount * max(1.55, dislike)
            snap['mood_score'] = round(float(snap.get('mood_score', 0.0) or 0.0) - mood_hit, 3)
            if stall_frames > 0:
                snap['stall_broccoli_total'] = round(float(snap.get('stall_broccoli_total', 0.0) or 0.0) + amount, 3)
            reason_l = (reason or '').lower()
            if 'idle' in reason_l:
                snap['idle_broccoli_total'] = round(float(snap.get('idle_broccoli_total', 0.0) or 0.0) + amount, 3)
                snap['idle_broccoli_events'] = int(snap.get('idle_broccoli_events', 0) or 0) + 1
        snap['broccoli_dislike'] = self._derive_broccoli_dislike(snap)
        snap['mood'] = self._derive_mood(float(snap.get('mood_score', 0.0) or 0.0))
        snap['last_reason'] = reason or ''
        event = {
            't': _now(),
            'kind': kind,
            'amount': amount,
            'broccoli_reduction': broccoli_reduction,
            'mood': snap['mood'],
            'reason': reason or '',
            'state': state_key,
            'action': action,
            'guide_action': guide_action,
            'stall_frames': int(stall_frames or 0),
            'aligned': aligned,
        }
        recent = list(snap.get('recent', []) or [])
        recent.append(event)
        snap['recent'] = recent[-80:]
        try:
            shard = self._current_reward_shard()
            with shard.open('a', encoding='utf-8') as handle:
                handle.write(_json_dump_compact(event) + "\n")
        except OSError:
            pass
        self.append_event('reward_feedback', event)

    def record_reward_signal(self, signal: Any, *, state_key: str = '', action: str = '', guide_action: str = '') -> None:
        cookies = round(max(0.0, float(getattr(signal, 'cookies', 0.0) or 0.0)), 3)
        broccoli = round(max(0.0, float(getattr(signal, 'broccoli', 0.0) or 0.0)), 3)
        broccoli_reduction = round(max(0.0, float(getattr(signal, 'broccoli_reduction', 0.0) or 0.0)), 3)
        aligned = getattr(signal, 'aligned', None)
        reasons = list(getattr(signal, 'reasons', []) or [])
        stall_frames = int(getattr(signal, 'stall_pressure', 0) or 0)
        reason = '; '.join(reasons[:8]) if reasons else ''
        if aligned is True:
            self.rewards['guide_aligned'] = int(self.rewards.get('guide_aligned', 0) or 0) + 1
        elif aligned is False:
            self.rewards['guide_misaligned'] = int(self.rewards.get('guide_misaligned', 0) or 0) + 1
        if cookies > 0 or broccoli_reduction > 0:
            self._apply_feedback(
                'cookie',
                cookies,
                reason=reason,
                state_key=state_key,
                action=action,
                guide_action=guide_action,
                stall_frames=stall_frames,
                aligned=aligned,
                broccoli_reduction=broccoli_reduction,
            )
        if broccoli > 0:
            self._apply_feedback(
                'broccoli',
                broccoli,
                reason=reason,
                state_key=state_key,
                action=action,
                guide_action=guide_action,
                stall_frames=stall_frames,
                aligned=aligned,
            )
        if cookies <= 0 and broccoli <= 0 and broccoli_reduction <= 0 and aligned is not None:
            self.append_event(
                'reward_alignment',
                {
                    'state': state_key,
                    'action': action,
                    'guide_action': guide_action,
                    'aligned': aligned,
                    'reason': reason,
                    'stall_frames': stall_frames,
                    'mood': self.rewards.get('mood', 'steady'),
                },
            )

    def save(self, reason: str = 'periodic') -> None:
        local_q = json.loads(json.dumps(self.q))
        local_clone = json.loads(json.dumps(self.clone))
        local_bad = list(self.bad[-120:])
        local_rewards = self.reward_snapshot()
        delta_steps = max(0, int(self.steps) - int(self._save_baseline_steps))
        delta_reward_floats = {
            key: round(float(local_rewards.get(key, 0.0) or 0.0) - float(self._save_baseline_reward_floats.get(key, 0.0) or 0.0), 6)
            for key in REWARD_FLOAT_FIELDS
        }
        delta_reward_ints = {
            key: int(local_rewards.get(key, 0) or 0) - int(self._save_baseline_reward_ints.get(key, 0) or 0)
            for key in REWARD_INT_FIELDS
        }
        new_bad = [item for item in local_bad if self._event_signature(item) not in self._save_baseline_bad_signatures]
        local_recent = list(local_rewards.get('recent', []) or [])
        new_recent = local_recent[self._save_baseline_recent_len:] if self._save_baseline_recent_len < len(local_recent) else []

        if not self._acquire_lock():
            return
        try:
            self.store_root.mkdir(parents=True, exist_ok=True)
            self.snapshots_dir.mkdir(parents=True, exist_ok=True)
            self.events_dir.mkdir(parents=True, exist_ok=True)
            self.rewards_dir.mkdir(parents=True, exist_ok=True)

            disk_payload = self._read_disk_payload()
            merged_q = dict(disk_payload.get('q', {}) or {})
            merged_clone = dict(disk_payload.get('clone', {}) or {})
            self._merge_action_tables(merged_q, local_q)
            self._merge_action_tables(merged_clone, local_clone)

            merged_rewards = self._normalize_rewards(disk_payload.get('rewards', None))
            for key, value in delta_reward_floats.items():
                if abs(value) > 1e-9:
                    merged_rewards[key] = round(float(merged_rewards.get(key, 0.0) or 0.0) + float(value), 3)
            for key, value in delta_reward_ints.items():
                if value:
                    merged_rewards[key] = int(merged_rewards.get(key, 0) or 0) + int(value)
            merged_rewards['last_reason'] = str(local_rewards.get('last_reason', '') or merged_rewards.get('last_reason', '') or '')
            merged_recent = list(merged_rewards.get('recent', []) or [])
            seen_recent = {self._event_signature(item) for item in merged_recent}
            for item in new_recent:
                sig = self._event_signature(item)
                if sig in seen_recent:
                    continue
                merged_recent.append(item)
                seen_recent.add(sig)
            merged_rewards['recent'] = merged_recent[-80:]
            merged_rewards['broccoli_dislike'] = self._derive_broccoli_dislike(merged_rewards)
            merged_rewards['mood'] = self._derive_mood(float(merged_rewards.get('mood_score', 0.0) or 0.0))

            merged_bad = list(disk_payload.get('bad', []) or [])[-120:]
            seen_bad = {self._event_signature(item) for item in merged_bad}
            for item in new_bad:
                sig = self._event_signature(item)
                if sig in seen_bad:
                    continue
                merged_bad.append(item)
                seen_bad.add(sig)
            merged_bad = merged_bad[-120:]

            self.q = merged_q
            self.clone = merged_clone
            self.steps = int(disk_payload.get('steps', 0) or 0) + int(delta_steps)
            self.bad = merged_bad
            self.rewards = merged_rewards

            generation = _generation_token()
            q_files = _write_sharded_dict(self.snapshots_dir, 'q', self.q, MAX_SNAPSHOT_SHARD_BYTES, generation=generation)
            clone_files = _write_sharded_dict(self.snapshots_dir, 'clone', self.clone, MAX_SNAPSHOT_SHARD_BYTES, generation=generation)
            rewards = self.reward_snapshot()

            meta = {
                'schema_version': SCHEMA_VERSION,
                'saved_at': _now(),
                'steps': int(self.steps),
                'bad': list(self.bad[-120:]),
                'q_state_count': len(self.q),
                'clone_state_count': len(self.clone),
                'q_files': q_files,
                'clone_files': clone_files,
                'rewards': {
                    'cookies_total': rewards['cookies_total'],
                    'broccoli_total': rewards['broccoli_total'],
                    'broccoli_burn_total': rewards['broccoli_burn_total'],
                    'idle_broccoli_total': rewards['idle_broccoli_total'],
                    'broccoli_dislike': rewards['broccoli_dislike'],
                    'mood': rewards['mood'],
                    'guide_aligned': rewards['guide_aligned'],
                    'guide_misaligned': rewards['guide_misaligned'],
                },
            }
            _write_json_atomic(self.meta_file, meta)
            _write_json_atomic(self.reward_state_file, rewards)

            payload = self._payload()
            _write_json_atomic(self.latest_export_file, payload)
            if self.legacy_file is not None:
                _write_json_atomic(self.legacy_file, payload)

            manifest = {
                'schema_version': SCHEMA_VERSION,
                'store_root': str(self.store_root),
                'legacy_file': str(self.legacy_file) if self.legacy_file is not None else '',
                'latest_export': str(self.latest_export_file),
                'saved_at': meta['saved_at'],
                'snapshot_files': q_files + clone_files + [self.meta_file.name],
                'event_shards': len(list(self.events_dir.glob('events_*.jsonl'))),
                'reward_state': str(self.reward_state_file),
                'reward_shards': len(list(self.rewards_dir.glob('reward_events_*.jsonl'))),
                'reason': reason,
            }
            _write_json_atomic(self.manifest_file, manifest)

            current_snapshot_names = set(q_files + clone_files)
            for old_path in sorted(self.snapshots_dir.glob('*.json')):
                if old_path.name in current_snapshot_names:
                    continue
                try:
                    old_path.unlink()
                except OSError:
                    pass
        finally:
            self._release_lock()

        self._reset_save_baseline()
        self.append_event(
            'snapshot',
            {
                'reason': reason,
                'steps': int(self.steps),
                'q_state_count': len(self.q),
                'clone_state_count': len(self.clone),
                'cookies_total': self.rewards.get('cookies_total', 0.0),
                'broccoli_total': self.rewards.get('broccoli_total', 0.0),
                'broccoli_burn_total': self.rewards.get('broccoli_burn_total', 0.0),
                'mood': self.rewards.get('mood', 'steady'),
                'broccoli_dislike': self.rewards.get('broccoli_dislike', 1.35),
            },
        )

    def qvalue(self, state_key: str, action: str) -> float:
        return float(self.q.get(state_key, {}).get(action, 0.0))

    def clonevalue(self, state_key: str, action: str) -> float:
        return float(self.clone.get(state_key, {}).get(action, 0.0))

    def best_action(self, state_key: str, allowed: list[str], fallback: str) -> str:
        row = self.q.get(state_key, {})
        best = fallback
        best_v = -10**9
        for action in allowed:
            v = float(row.get(action, 0.0))
            if v > best_v:
                best = action
                best_v = v
        return best

    def _prune_q(self) -> None:
        """Evict near-zero Q-table entries when the state count exceeds MAX_Q_STATES.

        States where every action's |Q-value| is below Q_PRUNE_THRESHOLD have
        contributed nothing meaningful and are safe to drop.  We prune until
        we're back at Q_PRUNE_CAPACITY (80 % of the cap) so the next prune
        doesn't fire immediately on the following update.
        """
        if len(self.q) <= MAX_Q_STATES:
            return
        # Collect candidates sorted by max absolute Q-value ascending so we
        # remove the least-learned states first.
        candidates = sorted(
            (
                (max(abs(v) for v in row.values()) if row else 0.0, key)
                for key, row in self.q.items()
            )
        )
        for _, key in candidates:
            if len(self.q) <= Q_PRUNE_CAPACITY:
                break
            row = self.q.get(key)
            if row and max(abs(v) for v in row.values()) >= Q_PRUNE_THRESHOLD:
                break  # reached learned states — stop pruning
            del self.q[key]

    def update(self, prev_state: str, prev_action: str, reward: float, next_state: str, allowed_next: list[str]) -> None:
        alpha = 0.22
        gamma = 0.88
        row = self.q.setdefault(prev_state, {})
        old = float(row.get(prev_action, 0.0))
        next_best = 0.0
        if allowed_next:
            next_best = max(self.qvalue(next_state, action) for action in allowed_next)
        new_v = old + alpha * (reward + gamma * next_best - old)
        row[prev_action] = round(new_v, 6)
        self.steps += 1
        if reward <= -0.5:
            self.bad.append(
                {
                    't': _now(),
                    'state': prev_state,
                    'action': prev_action,
                    'reward': round(reward, 3),
                }
            )
        self.bad = self.bad[-120:]
        # Keep Q-table size bounded so the JSON file stays manageable.
        if self.steps % 500 == 0:
            self._prune_q()
        self.append_event(
            'q_update',
            {
                'state': prev_state,
                'action': prev_action,
                'reward': round(float(reward), 6),
                'next_state': next_state,
                'steps': int(self.steps),
            },
        )

    def observe_teacher(self, state_key: str, action: str) -> None:
        row = self.clone.setdefault(state_key, {})
        row[action] = round(float(row.get(action, 0.0)) + 1.0, 3)
        if len(row) > 10:
            keep = sorted(row.items(), key=lambda kv: kv[1], reverse=True)[:6]
            self.clone[state_key] = {k: v for k, v in keep}
        self.append_event(
            'teacher',
            {
                'state': state_key,
                'action': action,
                'weight': float(self.clone.get(state_key, {}).get(action, 0.0)),
            },
        )

    def best_clone_action(self, state_key: str, allowed: list[str], fallback: str) -> str:
        row = self.clone.get(state_key, {})
        if not row:
            return fallback
        best = fallback
        best_v = -10**9
        for action in allowed:
            v = float(row.get(action, 0.0))
            if v > best_v:
                best = action
                best_v = v
        return best


def build_memory(path: Path) -> SilverMemoryStore:
    return SilverMemoryStore(Path(path))
