#!/usr/bin/env python3
"""Private account vault with an ordinary ~/.codex/auth.json working copy."""

from __future__ import annotations

import fcntl
import hashlib
import hmac
import json
import os
import re
import stat
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator, Mapping


MAX_AUTH_BYTES = 4 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
SAFE_ACCOUNT_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


class VaultError(RuntimeError):
    """Base class for stable, non-secret vault failures."""


class VaultPathError(VaultError):
    pass


class VaultDataError(VaultError):
    pass


class VaultIdentityConflict(VaultError):
    pass


class VaultBusyError(VaultError):
    pass


class VaultTransactionError(VaultError):
    pass


@dataclass(frozen=True)
class AuthDocument:
    payload: dict
    data: bytes
    account_identity: str


@dataclass(frozen=True)
class SwitchTransaction:
    identifier: str
    previous_account_id: str | None
    target_account_id: str


def _private_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat(follow_symlinks=False).st_mode)


def _assert_private_owner(info: os.stat_result) -> None:
    if info.st_uid != os.getuid():
        raise VaultPathError("vault path is not owned by the current user")


def _ensure_private_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        path.mkdir(mode=0o700)
        return
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise VaultPathError("vault directory is not a private real directory")
    _assert_private_owner(info)
    if stat.S_IMODE(info.st_mode) != 0o700:
        path.chmod(0o700)


def _assert_private_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise VaultPathError("vault directory is missing") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise VaultPathError("vault directory is not a private real directory")
    _assert_private_owner(info)
    if stat.S_IMODE(info.st_mode) != 0o700:
        raise VaultPathError("vault directory permissions are not 0700")


def _assert_owned_real_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise VaultPathError("source directory is missing") from error
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise VaultPathError("source directory is not a real directory")
    _assert_private_owner(info)
    if stat.S_IMODE(info.st_mode) & 0o022:
        raise VaultPathError("source directory is writable by another user")


def _read_private_bytes(path: Path, *, maximum_size: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise VaultPathError("private file cannot be opened safely") from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise VaultPathError("private path is not a regular file")
        _assert_private_owner(info)
        mode = stat.S_IMODE(info.st_mode)
        if mode & 0o077 or not mode & 0o400:
            raise VaultPathError("private file permissions are not owner-only")
        if info.st_size < 1 or info.st_size > maximum_size:
            raise VaultDataError("private file size is invalid")
        chunks = []
        remaining = maximum_size + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > maximum_size:
            raise VaultDataError("private file is too large")
        return data
    finally:
        os.close(descriptor)


def _auth_identity(payload: Mapping[str, object]) -> str:
    tokens = payload.get("tokens")
    if isinstance(tokens, Mapping):
        account_id = tokens.get("account_id")
        if isinstance(account_id, str) and account_id.strip():
            return account_id.strip()
    account_id = payload.get("account_id")
    if isinstance(account_id, str) and account_id.strip():
        return account_id.strip()
    raise VaultDataError("authentication document has no stable account identity")


def _parse_auth_bytes(data: bytes) -> AuthDocument:
    if not data or len(data) > MAX_AUTH_BYTES:
        raise VaultDataError("authentication document size is invalid")
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VaultDataError("authentication document is not valid JSON") from error
    if not isinstance(payload, dict):
        raise VaultDataError("authentication document root is not an object")
    return AuthDocument(
        payload=payload,
        data=data,
        account_identity=_auth_identity(payload),
    )


def read_auth_file(path: Path) -> AuthDocument:
    return _parse_auth_bytes(
        _read_private_bytes(path, maximum_size=MAX_AUTH_BYTES)
    )


def _serialize_auth(value: Mapping[str, object] | bytes | bytearray) -> AuthDocument:
    if isinstance(value, Mapping):
        try:
            data = (
                json.dumps(value, ensure_ascii=False, separators=(",", ":"))
                + "\n"
            ).encode("utf-8")
        except (TypeError, ValueError) as error:
            raise VaultDataError("authentication document cannot be serialized") from error
    elif isinstance(value, (bytes, bytearray)):
        data = bytes(value)
    else:
        raise VaultDataError("unsupported authentication document input")
    return _parse_auth_bytes(data)


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _atomic_write(path: Path, data: bytes, *, mode: int = 0o600) -> None:
    _assert_private_directory(path.parent)
    try:
        existing = path.lstat()
    except FileNotFoundError:
        existing = None
    if existing is not None:
        if stat.S_ISLNK(existing.st_mode) or not stat.S_ISREG(existing.st_mode):
            raise VaultPathError("atomic write target is not a regular private file")
        _assert_private_owner(existing)

    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, mode)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _atomic_replace_with_plain_file(path: Path, data: bytes) -> None:
    _assert_private_directory(path.parent)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(temporary, flags, 0o600)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _atomic_restore_symlink(path: Path, target: str) -> None:
    _assert_private_directory(path.parent)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    temporary.symlink_to(target)
    try:
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _metadata_bytes(value: Mapping[str, object]) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        + "\n"
    ).encode("utf-8")


def _read_metadata(path: Path, default: dict | None = None) -> dict:
    if not path.exists():
        return dict(default or {})
    data = _read_private_bytes(path, maximum_size=MAX_METADATA_BYTES)
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VaultDataError("vault metadata is invalid") from error
    if not isinstance(value, dict):
        raise VaultDataError("vault metadata root is invalid")
    return value


class AccountVault:
    def __init__(
        self,
        *,
        codex_home: Path | None = None,
        fault_injector: Callable[[str], None] | None = None,
    ) -> None:
        self.codex_home = (
            codex_home or Path("~/.codex").expanduser()
        ).expanduser()
        self.workbench_root = self.codex_home / "codex-workbench"
        self.accounts_root = self.workbench_root / "accounts"
        self.registry_path = self.workbench_root / "registry.json"
        self.state_path = self.workbench_root / "state.json"
        self.transaction_path = self.workbench_root / "transaction.json"
        self.migration_journal_path = self.workbench_root / "migration.json"
        self.migration_backup_root = self.workbench_root / "migration-backup"
        self.migration_registry_backup_path = (
            self.migration_backup_root / "registry.json"
        )
        self.migration_state_backup_path = self.migration_backup_root / "state.json"
        self.migration_root_backup_path = (
            self.migration_backup_root / "root-auth.json"
        )
        self.identity_key_path = self.workbench_root / "identity.key"
        self.lock_path = self.workbench_root / "vault.lock"
        self.root_auth_path = self.codex_home / "auth.json"
        self.fault_injector = fault_injector

    def ensure_layout(self) -> None:
        _ensure_private_directory(self.codex_home)
        _ensure_private_directory(self.workbench_root)
        _ensure_private_directory(self.accounts_root)
        if not self.identity_key_path.exists():
            _atomic_write(self.identity_key_path, os.urandom(32))
        else:
            _read_private_bytes(self.identity_key_path, maximum_size=128)
        if not self.registry_path.exists():
            self._write_registry({"version": 1, "accounts": {}})
        if not self.lock_path.exists():
            _atomic_write(self.lock_path, b"vault-lock\n")
        else:
            _read_private_bytes(self.lock_path, maximum_size=128)

    @contextmanager
    def lock(self) -> Iterator[None]:
        self.ensure_layout()
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(self.lock_path, flags)
        except OSError as error:
            raise VaultPathError("vault lock cannot be opened safely") from error
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise VaultBusyError("another account transaction is active") from error
            yield
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def _fault(self, stage: str) -> None:
        if self.fault_injector is not None:
            self.fault_injector(stage)

    def _read_registry(self) -> dict:
        registry = _read_metadata(
            self.registry_path,
            {"version": 1, "accounts": {}},
        )
        if registry.get("version") != 1 or not isinstance(registry.get("accounts"), dict):
            raise VaultDataError("vault registry schema is invalid")
        return registry

    def _write_registry(self, registry: Mapping[str, object]) -> None:
        _atomic_write(self.registry_path, _metadata_bytes(registry))

    def _read_state(self) -> dict:
        state = _read_metadata(
            self.state_path,
            {"version": 1, "active_account_id": None},
        )
        if state.get("version") != 1:
            raise VaultDataError("vault state schema is invalid")
        return state

    def _write_state(self, state: Mapping[str, object]) -> None:
        _atomic_write(self.state_path, _metadata_bytes(state))

    def _write_transaction(self, transaction: Mapping[str, object]) -> None:
        _atomic_write(self.transaction_path, _metadata_bytes(transaction))

    def _identity_hash(self, account_identity: str) -> str:
        key = _read_private_bytes(self.identity_key_path, maximum_size=128)
        return hmac.new(
            key,
            account_identity.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()[:32]

    def _account_directory(self, internal_id: str, *, create: bool) -> Path:
        if not SAFE_ACCOUNT_ID.fullmatch(internal_id):
            raise VaultPathError("account id does not satisfy the safe path policy")
        path = self.accounts_root / internal_id
        if create:
            _ensure_private_directory(path)
        else:
            _assert_private_directory(path)
        if path.parent != self.accounts_root:
            raise VaultPathError("account path escaped the vault root")
        return path

    def _account_auth_path(self, internal_id: str, *, create_directory: bool) -> Path:
        return self._account_directory(
            internal_id,
            create=create_directory,
        ) / "auth.json"

    def import_account(
        self,
        internal_id: str,
        auth: Mapping[str, object] | bytes | bytearray,
    ) -> str:
        document = _serialize_auth(auth)
        with self.lock():
            registry = self._read_registry()
            accounts = registry["accounts"]
            identity_hash = self._identity_hash(document.account_identity)
            previous = accounts.get(internal_id)
            if (
                isinstance(previous, dict)
                and previous.get("identity_hash") != identity_hash
            ):
                raise VaultIdentityConflict(
                    "account id is already bound to another identity"
                )
            duplicate = next(
                (
                    account_id
                    for account_id, metadata in accounts.items()
                    if isinstance(metadata, dict)
                    and metadata.get("identity_hash") == identity_hash
                    and account_id != internal_id
                ),
                None,
            )
            if duplicate is not None:
                raise VaultIdentityConflict("account identity is already stored")
            auth_path = self._account_auth_path(
                internal_id,
                create_directory=True,
            )
            _atomic_write(auth_path, document.data)
            now = int(time.time())
            created_at = (
                previous.get("created_at")
                if isinstance(previous, dict)
                else now
            )
            accounts[internal_id] = {
                "identity_hash": identity_hash,
                "created_at": created_at,
                "updated_at": now,
            }
            self._write_registry(registry)
        return internal_id

    def account_identity(self, internal_id: str) -> str:
        self.ensure_layout()
        return read_auth_file(
            self._account_auth_path(internal_id, create_directory=False)
        ).account_identity

    def active_account_id(self) -> str | None:
        self.ensure_layout()
        value = self._read_state().get("active_account_id")
        return value if isinstance(value, str) else None

    def storage_snapshot(self) -> dict | None:
        """Return validated storage metadata without creating or changing files."""
        if not self.workbench_root.exists():
            return None
        _assert_private_directory(self.codex_home)
        _assert_private_directory(self.workbench_root)
        _assert_private_directory(self.accounts_root)
        if self.migration_journal_path.exists() or self.transaction_path.exists():
            raise VaultBusyError("an account transaction requires recovery")
        registry = self._read_registry()
        accounts = []
        for internal_id, metadata in sorted(registry["accounts"].items()):
            if not isinstance(internal_id, str) or not isinstance(metadata, dict):
                raise VaultDataError("vault registry account entry is invalid")
            document = read_auth_file(
                self._account_auth_path(internal_id, create_directory=False)
            )
            if metadata.get("identity_hash") != self._identity_hash(
                document.account_identity
            ):
                raise VaultIdentityConflict(
                    "stored account identity does not match the registry"
                )
            accounts.append(
                {
                    "id": internal_id,
                    "path": self.accounts_root / internal_id,
                }
            )
        state = self._read_state()
        active = state.get("active_account_id")
        if active is not None and not any(item["id"] == active for item in accounts):
            raise VaultDataError("active account is missing from the vault")
        try:
            root_info = self.root_auth_path.lstat()
        except FileNotFoundError:
            root_kind = "missing"
        else:
            if stat.S_ISLNK(root_info.st_mode):
                root_kind = "symlink"
            elif stat.S_ISREG(root_info.st_mode):
                root_kind = "plain_file"
            else:
                root_kind = "invalid"
        return {
            "mode": "unified_vault",
            "active_account_id": active if isinstance(active, str) else None,
            "account_count": len(accounts),
            "root_auth_kind": root_kind,
            "accounts": accounts,
        }

    def validate_active_working_copy(self, snapshot: dict | None = None) -> None:
        snapshot = snapshot if snapshot is not None else self.storage_snapshot()
        if snapshot is None or snapshot.get("account_count", 0) < 1:
            raise VaultDataError("unified account storage is not initialized")
        active = snapshot.get("active_account_id")
        if not isinstance(active, str):
            raise VaultDataError("unified account storage has no active account")
        if snapshot.get("root_auth_kind") != "plain_file":
            raise VaultIdentityConflict(
                "root authentication changed outside the unified vault"
            )
        root = read_auth_file(self.root_auth_path)
        active_document = read_auth_file(
            self._account_auth_path(active, create_directory=False)
        )
        if root.account_identity != active_document.account_identity:
            raise VaultIdentityConflict(
                "root authentication changed outside the unified vault"
            )

    def migrate_legacy_profiles(
        self,
        *,
        profile_root: Path,
        active_profile: str | None,
        dry_run: bool,
    ) -> dict:
        candidates, deduplicated = self._legacy_candidates(profile_root)
        report = {
            "dry_run": dry_run,
            "profile_count": len(candidates) + len(deduplicated),
            "planned_import_count": len(candidates),
            "imported_count": 0,
            "deduplicated_profiles": deduplicated,
            "legacy_profiles_preserved": True,
        }
        if dry_run:
            return report
        if not candidates:
            return report

        self.ensure_layout()
        created_accounts: list[str] = []
        original_registry: dict | None = None
        original_state_data: bytes | None = None
        original_root_kind = "missing"
        original_root_data: bytes | None = None
        original_root_link: str | None = None
        injector = self.fault_injector
        mutation_started = False
        original_root_signature: tuple[int, int, int] | None = None
        try:
            with self.lock():
                if self.transaction_path.exists():
                    raise VaultBusyError("an account transaction requires recovery")
                registry = self._read_registry()
                original_registry = json.loads(json.dumps(registry))
                accounts = registry["accounts"]
                if self.state_path.exists():
                    original_state_data = _read_private_bytes(
                        self.state_path,
                        maximum_size=MAX_METADATA_BYTES,
                    )

                canonical_by_identity = {
                    document.account_identity: profile_name
                    for profile_name, document in candidates
                }
                imported_mapping: dict[str, str] = {}
                plans: list[tuple[str, AuthDocument]] = []
                for profile_name, document in candidates:
                    identity_hash = self._identity_hash(document.account_identity)
                    existing_identity = next(
                        (
                            account_id
                            for account_id, metadata in accounts.items()
                            if isinstance(metadata, dict)
                            and metadata.get("identity_hash") == identity_hash
                        ),
                        None,
                    )
                    existing_name = accounts.get(profile_name)
                    if (
                        isinstance(existing_name, dict)
                        and existing_name.get("identity_hash") != identity_hash
                    ):
                        raise VaultIdentityConflict(
                            "legacy profile name conflicts with a stored account"
                        )
                    if existing_identity is not None:
                        imported_mapping[profile_name] = existing_identity
                        continue
                    plans.append((profile_name, document))
                    imported_mapping[profile_name] = profile_name

                for duplicate_name in deduplicated:
                    duplicate_document = next(
                        document
                        for name, document in self._all_legacy_documents(profile_root)
                        if name == duplicate_name
                    )
                    canonical_name = canonical_by_identity[
                        duplicate_document.account_identity
                    ]
                    imported_mapping[duplicate_name] = imported_mapping.get(
                        canonical_name,
                        canonical_name,
                    )

                active_account_id = None
                active_document = None
                if active_profile is not None:
                    if active_profile not in imported_mapping:
                        raise VaultIdentityConflict(
                            "active legacy profile is not migratable"
                        )
                    active_account_id = imported_mapping[active_profile]
                    active_document = next(
                        document
                        for name, document in self._all_legacy_documents(profile_root)
                        if name == active_profile
                    )

                if self.root_auth_path.is_symlink():
                    root_info = self.root_auth_path.lstat()
                    original_root_signature = (
                        root_info.st_dev,
                        root_info.st_ino,
                        stat.S_IFMT(root_info.st_mode),
                    )
                    original_root_kind = "symlink"
                    original_root_link = os.readlink(self.root_auth_path)
                    linked_path = Path(original_root_link)
                    if not linked_path.is_absolute():
                        linked_path = self.root_auth_path.parent / linked_path
                    if active_profile is None:
                        raise VaultIdentityConflict(
                            "root symlink has no active legacy profile"
                        )
                    expected_auth_path = (
                        profile_root / active_profile / "auth.json"
                    ).absolute()
                    normalized_link_path = Path(
                        os.path.normpath(str(linked_path.absolute()))
                    )
                    if normalized_link_path != expected_auth_path:
                        raise VaultIdentityConflict(
                            "root symlink does not target the active legacy profile"
                        )
                    root_document = read_auth_file(expected_auth_path)
                    if (
                        active_document is None
                        or root_document.account_identity
                        != active_document.account_identity
                    ):
                        raise VaultIdentityConflict(
                            "root symlink does not match the active legacy profile"
                        )
                    original_root_data = root_document.data
                elif self.root_auth_path.exists():
                    root_info = self.root_auth_path.lstat()
                    original_root_signature = (
                        root_info.st_dev,
                        root_info.st_ino,
                        stat.S_IFMT(root_info.st_mode),
                    )
                    original_root_kind = "plain"
                    root_document = read_auth_file(self.root_auth_path)
                    original_root_data = root_document.data
                    if active_document is None:
                        matching_profile = next(
                            (
                                name
                                for name, document in self._all_legacy_documents(profile_root)
                                if document.account_identity
                                == root_document.account_identity
                            ),
                            None,
                        )
                        if matching_profile is None:
                            raise VaultIdentityConflict(
                                "root authentication is not a legacy account"
                            )
                        active_profile = matching_profile
                        active_account_id = imported_mapping[matching_profile]
                        active_document = root_document
                    elif (
                        root_document.account_identity
                        != active_document.account_identity
                    ):
                        raise VaultIdentityConflict(
                            "root authentication does not match the active profile"
                        )
                elif active_document is not None:
                    original_root_data = None

                now = int(time.time())
                created_accounts = [account_id for account_id, _ in plans]
                self._prepare_legacy_migration_journal_locked(
                    created_accounts=created_accounts,
                    original_registry=original_registry,
                    original_state_data=original_state_data,
                    original_root_kind=original_root_kind,
                    original_root_data=original_root_data,
                    original_root_link=original_root_link,
                )
                mutation_started = True
                self._fault("after_legacy_journal_write")
                for account_id, document in plans:
                    account_path = self._account_auth_path(
                        account_id,
                        create_directory=True,
                    )
                    _atomic_write(account_path, document.data)
                    accounts[account_id] = {
                        "identity_hash": self._identity_hash(
                            document.account_identity
                        ),
                        "created_at": now,
                        "updated_at": now,
                    }
                self._write_registry(registry)

                if active_document is not None and active_account_id is not None:
                    try:
                        current_root_info = self.root_auth_path.lstat()
                    except FileNotFoundError:
                        current_root_signature = None
                    else:
                        current_root_signature = (
                            current_root_info.st_dev,
                            current_root_info.st_ino,
                            stat.S_IFMT(current_root_info.st_mode),
                        )
                    if current_root_signature != original_root_signature:
                        raise VaultIdentityConflict(
                            "root authentication changed during migration"
                        )
                    if original_root_kind == "symlink":
                        try:
                            current_link = os.readlink(self.root_auth_path)
                        except OSError as error:
                            raise VaultIdentityConflict(
                                "root symlink changed during migration"
                            ) from error
                        if current_link != original_root_link:
                            raise VaultIdentityConflict(
                                "root symlink changed during migration"
                            )
                    root_data = (
                        original_root_data
                        if original_root_data is not None
                        else active_document.data
                    )
                    _atomic_replace_with_plain_file(
                        self.root_auth_path,
                        root_data,
                    )
                    self._fault("after_legacy_root_replace")
                    active_auth_path = self._account_auth_path(
                        active_account_id,
                        create_directory=False,
                    )
                    _atomic_write(active_auth_path, root_data)
                    self._write_state(
                        {
                            "version": 1,
                            "active_account_id": active_account_id,
                        }
                    )
                self._remove_legacy_migration_artifacts_locked()
                report["imported_count"] = len(plans)
                return report
        except VaultError:
            if mutation_started:
                self._recover_legacy_migration()
            raise
        except Exception as error:
            if mutation_started:
                self._recover_legacy_migration()
            raise VaultTransactionError("legacy migration transaction failed") from error
        finally:
            self.fault_injector = injector

    def _all_legacy_documents(
        self,
        profile_root: Path,
    ) -> list[tuple[str, AuthDocument]]:
        if not profile_root.exists():
            return []
        _assert_owned_real_directory(profile_root)
        documents = []
        for profile in sorted(profile_root.iterdir(), key=lambda path: path.name):
            if profile.is_symlink() or not profile.is_dir():
                continue
            if profile.resolve(strict=False) == self.codex_home.resolve(strict=False):
                continue
            if not SAFE_ACCOUNT_ID.fullmatch(profile.name):
                raise VaultPathError("legacy profile name is not a safe account id")
            _assert_owned_real_directory(profile)
            auth_path = profile / "auth.json"
            if not auth_path.exists() and not auth_path.is_symlink():
                continue
            documents.append((profile.name, read_auth_file(auth_path)))
        return documents

    def _legacy_candidates(
        self,
        profile_root: Path,
    ) -> tuple[list[tuple[str, AuthDocument]], list[str]]:
        unique: dict[str, tuple[str, AuthDocument]] = {}
        deduplicated = []
        for profile_name, document in self._all_legacy_documents(profile_root):
            if document.account_identity in unique:
                deduplicated.append(profile_name)
            else:
                unique[document.account_identity] = (profile_name, document)
        return list(unique.values()), deduplicated

    def _rollback_legacy_migration(
        self,
        *,
        created_accounts: list[str],
        original_registry: dict | None,
        original_state_data: bytes | None,
        original_root_kind: str,
        original_root_data: bytes | None,
        original_root_link: str | None,
        fault_injector: Callable[[str], None] | None,
    ) -> None:
        self.fault_injector = None
        try:
            with self.lock():
                if original_root_kind == "symlink" and original_root_link is not None:
                    _atomic_restore_symlink(
                        self.root_auth_path,
                        original_root_link,
                    )
                elif original_root_kind == "plain" and original_root_data is not None:
                    _atomic_replace_with_plain_file(
                        self.root_auth_path,
                        original_root_data,
                    )
                elif original_root_kind == "missing":
                    try:
                        info = self.root_auth_path.lstat()
                    except FileNotFoundError:
                        info = None
                    if info is not None:
                        if stat.S_ISLNK(info.st_mode) or stat.S_ISREG(info.st_mode):
                            self.root_auth_path.unlink()
                            _fsync_directory(self.codex_home)

                if original_state_data is None:
                    try:
                        self.state_path.unlink()
                    except FileNotFoundError:
                        pass
                else:
                    _atomic_write(self.state_path, original_state_data)
                if original_registry is not None:
                    self._write_registry(original_registry)
                for account_id in reversed(created_accounts):
                    directory = self.accounts_root / account_id
                    try:
                        (directory / "auth.json").unlink()
                    except FileNotFoundError:
                        pass
                    try:
                        directory.rmdir()
                    except FileNotFoundError:
                        pass
                _fsync_directory(self.accounts_root)
        except VaultError:
            pass
        finally:
            self.fault_injector = fault_injector

    def _prepare_legacy_migration_journal_locked(
        self,
        *,
        created_accounts: list[str],
        original_registry: dict | None,
        original_state_data: bytes | None,
        original_root_kind: str,
        original_root_data: bytes | None,
        original_root_link: str | None,
    ) -> None:
        if self.migration_journal_path.exists():
            raise VaultBusyError("a legacy migration requires recovery")
        journal = {
            "version": 1,
            "kind": "legacy_migration",
            "stage": "preparing",
            "created_accounts": created_accounts,
            "state_existed": original_state_data is not None,
            "root_kind": original_root_kind,
            "root_link": original_root_link,
            "created_at": int(time.time()),
        }
        _atomic_write(self.migration_journal_path, _metadata_bytes(journal))
        _ensure_private_directory(self.migration_backup_root)
        if original_registry is None:
            raise VaultTransactionError("legacy migration registry backup is missing")
        _atomic_write(
            self.migration_registry_backup_path,
            _metadata_bytes(original_registry),
        )
        if original_state_data is not None:
            _atomic_write(self.migration_state_backup_path, original_state_data)
        if original_root_data is not None:
            _atomic_write(self.migration_root_backup_path, original_root_data)
        journal["stage"] = "ready"
        _atomic_write(self.migration_journal_path, _metadata_bytes(journal))

    def _validated_legacy_migration_journal(self) -> dict:
        journal = _read_metadata(self.migration_journal_path)
        created = journal.get("created_accounts")
        if (
            journal.get("version") != 1
            or journal.get("kind") != "legacy_migration"
            or journal.get("stage") not in {"preparing", "ready"}
            or not isinstance(created, list)
            or not all(
                isinstance(account_id, str)
                and SAFE_ACCOUNT_ID.fullmatch(account_id)
                for account_id in created
            )
            or not isinstance(journal.get("state_existed"), bool)
            or journal.get("root_kind")
            not in {"missing", "plain", "symlink"}
            or (
                journal.get("root_kind") == "symlink"
                and not isinstance(journal.get("root_link"), str)
            )
        ):
            raise VaultTransactionError("legacy migration journal is invalid")
        return journal

    def _recover_legacy_migration(self) -> str:
        injector = self.fault_injector
        self.fault_injector = None
        try:
            with self.lock():
                return self._recover_legacy_migration_locked()
        finally:
            self.fault_injector = injector

    def _recover_legacy_migration_locked(self) -> str:
        journal = self._validated_legacy_migration_journal()
        if journal["stage"] == "preparing":
            self._remove_legacy_migration_artifacts_locked()
            return "legacy_migration_preparation_cleaned"

        registry_data = _read_private_bytes(
            self.migration_registry_backup_path,
            maximum_size=MAX_METADATA_BYTES,
        )
        root_kind = journal["root_kind"]
        if root_kind == "symlink":
            _atomic_restore_symlink(
                self.root_auth_path,
                journal["root_link"],
            )
        elif root_kind == "plain":
            root_data = _read_private_bytes(
                self.migration_root_backup_path,
                maximum_size=MAX_AUTH_BYTES,
            )
            _atomic_replace_with_plain_file(self.root_auth_path, root_data)
        else:
            try:
                root_info = self.root_auth_path.lstat()
            except FileNotFoundError:
                root_info = None
            if root_info is not None:
                if not (
                    stat.S_ISREG(root_info.st_mode)
                    or stat.S_ISLNK(root_info.st_mode)
                ):
                    raise VaultPathError(
                        "root authentication cannot be safely recovered"
                    )
                self.root_auth_path.unlink()
                _fsync_directory(self.codex_home)

        if journal["state_existed"]:
            state_data = _read_private_bytes(
                self.migration_state_backup_path,
                maximum_size=MAX_METADATA_BYTES,
            )
            _atomic_write(self.state_path, state_data)
        else:
            try:
                self.state_path.unlink()
                _fsync_directory(self.workbench_root)
            except FileNotFoundError:
                pass

        _atomic_write(self.registry_path, registry_data)
        for account_id in reversed(journal["created_accounts"]):
            directory = self.accounts_root / account_id
            try:
                info = directory.lstat()
            except FileNotFoundError:
                continue
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                raise VaultPathError(
                    "created migration account cannot be safely recovered"
                )
            try:
                auth_info = (directory / "auth.json").lstat()
            except FileNotFoundError:
                auth_info = None
            if auth_info is not None:
                if stat.S_ISLNK(auth_info.st_mode) or not stat.S_ISREG(
                    auth_info.st_mode
                ):
                    raise VaultPathError(
                        "created migration auth cannot be safely recovered"
                    )
                (directory / "auth.json").unlink()
            try:
                directory.rmdir()
            except OSError as error:
                raise VaultPathError(
                    "created migration account is not empty"
                ) from error
        _fsync_directory(self.accounts_root)
        self._remove_legacy_migration_artifacts_locked()
        return "legacy_migration_rolled_back"

    def _remove_legacy_migration_artifacts_locked(self) -> None:
        backups: list[Path] = []
        if self.migration_backup_root.exists():
            _assert_private_directory(self.migration_backup_root)
            for backup in (
                self.migration_registry_backup_path,
                self.migration_state_backup_path,
                self.migration_root_backup_path,
            ):
                try:
                    info = backup.lstat()
                except FileNotFoundError:
                    continue
                if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                    raise VaultPathError(
                        "migration backup artifact is not a regular file"
                    )
                backups.append(backup)
        try:
            journal_info = self.migration_journal_path.lstat()
        except FileNotFoundError:
            journal_info = None
        if journal_info is not None:
            if stat.S_ISLNK(journal_info.st_mode) or not stat.S_ISREG(
                journal_info.st_mode
            ):
                raise VaultPathError(
                    "migration journal is not a regular file"
                )
            self.migration_journal_path.unlink()
            # Once the committed/rolled-back result is durable, any remaining
            # backup files are redundant cleanup material, not a recovery claim.
            _fsync_directory(self.workbench_root)
        for backup in backups:
            backup.unlink()
        if self.migration_backup_root.exists():
            try:
                self.migration_backup_root.rmdir()
            except OSError as error:
                raise VaultPathError(
                    "migration backup directory is not empty"
                ) from error
        _fsync_directory(self.workbench_root)

    def activate(self, internal_id: str) -> None:
        with self.lock():
            if self.transaction_path.exists():
                raise VaultBusyError("an account transaction requires recovery")
            target = read_auth_file(
                self._account_auth_path(internal_id, create_directory=False)
            )
            state = self._read_state()
            current = state.get("active_account_id")
            if current is None or current == internal_id:
                if self.root_auth_path.exists() or self.root_auth_path.is_symlink():
                    root = read_auth_file(self.root_auth_path)
                    if root.account_identity != target.account_identity:
                        raise VaultIdentityConflict(
                            "root authentication belongs to another account"
                        )
                    _atomic_write(
                        self._account_auth_path(internal_id, create_directory=False),
                        root.data,
                    )
                else:
                    _atomic_write(self.root_auth_path, target.data)
                self._write_state(
                    {"version": 1, "active_account_id": internal_id}
                )
                return
        transaction = self.prepare_switch(internal_id)
        self.commit_switch(transaction)

    def prepare_switch(self, target_account_id: str) -> SwitchTransaction:
        transaction: dict | None = None
        try:
            with self.lock():
                if self.transaction_path.exists():
                    raise VaultBusyError("an account transaction requires recovery")
                state = self._read_state()
                previous = state.get("active_account_id")
                if previous == target_account_id:
                    raise VaultTransactionError("target account is already active")
                target = read_auth_file(
                    self._account_auth_path(
                        target_account_id,
                        create_directory=False,
                    )
                )
                if isinstance(previous, str):
                    previous_path = self._account_auth_path(
                        previous,
                        create_directory=False,
                    )
                    previous_snapshot = read_auth_file(previous_path)
                    root = read_auth_file(self.root_auth_path)
                    if root.account_identity != previous_snapshot.account_identity:
                        raise VaultIdentityConflict(
                            "root authentication changed outside the active account"
                        )
                    _atomic_write(previous_path, root.data)
                elif self.root_auth_path.exists() or self.root_auth_path.is_symlink():
                    root = read_auth_file(self.root_auth_path)
                    if root.account_identity != target.account_identity:
                        raise VaultIdentityConflict(
                            "root authentication has no matching active vault account"
                        )

                transaction = {
                    "version": 1,
                    "id": uuid.uuid4().hex,
                    "from": previous if isinstance(previous, str) else None,
                    "to": target_account_id,
                    "stage": "prepared",
                    "created_at": int(time.time()),
                }
                self._write_transaction(transaction)
                self._fault("after_transaction_write")
                _atomic_write(self.root_auth_path, target.data)
                self._fault("after_root_materialize")
                transaction["stage"] = "materialized"
                self._write_transaction(transaction)
                self._write_state(
                    {
                        "version": 1,
                        "active_account_id": previous,
                        "pending": {
                            "id": transaction["id"],
                            "target_account_id": target_account_id,
                        },
                    }
                )
                return SwitchTransaction(
                    identifier=transaction["id"],
                    previous_account_id=transaction["from"],
                    target_account_id=target_account_id,
                )
        except VaultError:
            if transaction is not None:
                self._best_effort_rollback(transaction)
            raise
        except Exception as error:
            if transaction is not None:
                self._best_effort_rollback(transaction)
            raise VaultTransactionError("account switch transaction failed") from error

    def commit_switch(self, transaction: SwitchTransaction) -> None:
        with self.lock():
            stored = self._validated_transaction(transaction)
            if stored.get("stage") != "materialized":
                raise VaultTransactionError("transaction stage cannot be committed")
            target_path = self._account_auth_path(
                transaction.target_account_id,
                create_directory=False,
            )
            target = read_auth_file(
                target_path
            )
            root = read_auth_file(self.root_auth_path)
            if root.account_identity != target.account_identity:
                raise VaultIdentityConflict(
                    "root authentication does not match the switch target"
                )
            _atomic_write(target_path, root.data)
            self._write_state(
                {
                    "version": 1,
                    "active_account_id": transaction.target_account_id,
                }
            )
            self._remove_transaction()

    def rollback_switch(self, transaction: SwitchTransaction) -> None:
        with self.lock():
            stored = self._validated_transaction(transaction)
            self._rollback_locked(stored)

    def recover(self) -> str:
        with self.lock():
            if self.migration_journal_path.exists():
                return self._recover_legacy_migration_locked()
            if not self.transaction_path.exists():
                return "none"
            stored = self._validate_transaction_record(
                _read_metadata(self.transaction_path)
            )
            self._rollback_locked(stored)
            return "rolled_back"

    def _validated_transaction(self, transaction: SwitchTransaction) -> dict:
        if not self.transaction_path.exists():
            raise VaultTransactionError("account transaction is missing")
        stored = _read_metadata(self.transaction_path)
        stored = self._validate_transaction_record(stored)
        if (
            stored.get("id") != transaction.identifier
            or stored.get("from") != transaction.previous_account_id
            or stored.get("to") != transaction.target_account_id
        ):
            raise VaultTransactionError("account transaction identity changed")
        return stored

    def _validate_transaction_record(self, stored: dict) -> dict:
        previous = stored.get("from")
        target = stored.get("to")
        identifier = stored.get("id")
        if (
            stored.get("version") != 1
            or not isinstance(identifier, str)
            or not re.fullmatch(r"[a-f0-9]{32}", identifier)
            or (previous is not None and not isinstance(previous, str))
            or not isinstance(target, str)
            or stored.get("stage") not in {"prepared", "materialized"}
        ):
            raise VaultTransactionError("account transaction schema is invalid")
        self._account_directory(target, create=False)
        if isinstance(previous, str):
            self._account_directory(previous, create=False)
        return stored

    def _rollback_locked(self, transaction: Mapping[str, object]) -> None:
        previous = transaction.get("from")
        if isinstance(previous, str):
            previous_auth = read_auth_file(
                self._account_auth_path(previous, create_directory=False)
            )
            _atomic_write(self.root_auth_path, previous_auth.data)
        self._write_state(
            {
                "version": 1,
                "active_account_id": previous if isinstance(previous, str) else None,
            }
        )
        self._remove_transaction()

    def _best_effort_rollback(self, transaction: Mapping[str, object]) -> None:
        injector = self.fault_injector
        self.fault_injector = None
        try:
            with self.lock():
                self._rollback_locked(transaction)
        except VaultError:
            pass
        finally:
            self.fault_injector = injector

    def _remove_transaction(self) -> None:
        try:
            info = self.transaction_path.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise VaultPathError("transaction path is not a private regular file")
        self.transaction_path.unlink()
        _fsync_directory(self.workbench_root)
