import fcntl
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def synthetic_auth(account_id: str, marker: str) -> dict:
    return {
        "auth_mode": "chatgpt",
        "tokens": {
            "account_id": account_id,
            "access_token": f"access-{marker}",
            "refresh_token": f"refresh-{marker}",
        },
    }


class AccountVaultTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.codex_home = self.home / ".codex"

    def tearDown(self):
        self.tmp.cleanup()

    def make_vault(self, **kwargs):
        from account_vault import AccountVault

        return AccountVault(codex_home=self.codex_home, **kwargs)

    def import_two_accounts(self, vault):
        vault.import_account("A", synthetic_auth("account-a", "A"))
        vault.import_account("B", synthetic_auth("account-b", "B"))

    def root_account_id(self):
        payload = json.loads((self.codex_home / "auth.json").read_text(encoding="utf-8"))
        return payload["tokens"]["account_id"]

    def make_legacy_profile(self, name: str, account_id: str, marker: str):
        profile = self.home / ".codex-profiles" / name
        profile.mkdir(parents=True, mode=0o700)
        auth_path = profile / "auth.json"
        auth_path.write_text(
            json.dumps(synthetic_auth(account_id, marker)),
            encoding="utf-8",
        )
        auth_path.chmod(0o600)
        return profile

    def test_layout_and_sensitive_modes_live_under_codex_home(self):
        vault = self.make_vault()
        vault.import_account("A", synthetic_auth("account-a", "A"))

        self.assertEqual(
            vault.accounts_root,
            self.codex_home / "codex-workbench" / "accounts",
        )
        for directory in (
            self.codex_home,
            vault.workbench_root,
            vault.accounts_root,
            vault.accounts_root / "A",
        ):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        for file_path in (
            vault.accounts_root / "A" / "auth.json",
            vault.registry_path,
            vault.identity_key_path,
        ):
            self.assertEqual(stat.S_IMODE(file_path.stat().st_mode), 0o600)

    def test_registry_and_state_never_store_auth_or_account_identity(self):
        vault = self.make_vault()
        vault.import_account("A", synthetic_auth("account-a", "private-marker"))
        vault.activate("A")

        metadata = vault.registry_path.read_text(encoding="utf-8")
        metadata += vault.state_path.read_text(encoding="utf-8")
        self.assertNotIn("account-a", metadata)
        self.assertNotIn("private-marker", metadata)
        self.assertNotIn("access_token", metadata)
        self.assertNotIn("refresh_token", metadata)

    def test_rejects_symlinked_codex_home(self):
        from account_vault import VaultPathError

        real_home = self.home / "real-codex"
        real_home.mkdir(mode=0o700)
        self.codex_home.symlink_to(real_home, target_is_directory=True)

        with self.assertRaises(VaultPathError):
            self.make_vault().ensure_layout()

    def test_rejects_symlinked_account_directory(self):
        from account_vault import VaultPathError

        vault = self.make_vault()
        vault.ensure_layout()
        outside = self.home / "outside"
        outside.mkdir(mode=0o700)
        (vault.accounts_root / "A").symlink_to(outside, target_is_directory=True)

        with self.assertRaises(VaultPathError):
            vault.import_account("A", synthetic_auth("account-a", "A"))

    def test_rejects_symlinked_auth_target(self):
        from account_vault import VaultPathError

        vault = self.make_vault()
        vault.ensure_layout()
        account_dir = vault.accounts_root / "A"
        account_dir.mkdir(mode=0o700)
        outside = self.home / "outside-auth.json"
        outside.write_text(json.dumps(synthetic_auth("account-a", "A")), encoding="utf-8")
        outside.chmod(0o600)
        (account_dir / "auth.json").symlink_to(outside)

        with self.assertRaises(VaultPathError):
            vault.import_account("A", synthetic_auth("account-a", "A"))

    def test_rejects_invalid_or_permissive_auth_files(self):
        from account_vault import VaultDataError, VaultPathError, read_auth_file

        invalid = self.home / "invalid.json"
        invalid.write_text("{", encoding="utf-8")
        invalid.chmod(0o600)
        with self.assertRaises(VaultDataError):
            read_auth_file(invalid)

        permissive = self.home / "permissive.json"
        permissive.write_text(
            json.dumps(synthetic_auth("account-a", "A")),
            encoding="utf-8",
        )
        permissive.chmod(0o644)
        with self.assertRaises(VaultPathError):
            read_auth_file(permissive)

    def test_switches_a_to_b_to_a_with_a_plain_root_working_file(self):
        vault = self.make_vault()
        self.import_two_accounts(vault)

        vault.activate("A")
        self.assertEqual(self.root_account_id(), "account-a")
        transaction = vault.prepare_switch("B")
        self.assertEqual(self.root_account_id(), "account-b")
        vault.commit_switch(transaction)
        transaction = vault.prepare_switch("A")
        self.assertEqual(self.root_account_id(), "account-a")
        vault.commit_switch(transaction)

        root_auth = self.codex_home / "auth.json"
        self.assertTrue(root_auth.is_file())
        self.assertFalse(root_auth.is_symlink())
        self.assertEqual(stat.S_IMODE(root_auth.stat().st_mode), 0o600)
        self.assertFalse(any(vault.workbench_root.rglob("*.tmp")))

    def test_commit_captures_target_refresh_from_the_root_working_file(self):
        vault = self.make_vault()
        self.import_two_accounts(vault)
        vault.activate("A")
        transaction = vault.prepare_switch("B")
        refreshed = synthetic_auth("account-b", "B-refreshed")
        root_auth = self.codex_home / "auth.json"
        root_auth.write_text(json.dumps(refreshed), encoding="utf-8")
        root_auth.chmod(0o600)

        vault.commit_switch(transaction)

        snapshot = json.loads(
            (vault.accounts_root / "B" / "auth.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            snapshot["tokens"]["refresh_token"],
            "refresh-B-refreshed",
        )

    def test_commit_rejects_a_tampered_transaction_stage_without_mutation(self):
        from account_vault import VaultTransactionError

        vault = self.make_vault()
        self.import_two_accounts(vault)
        vault.activate("A")
        transaction = vault.prepare_switch("B")
        stored = json.loads(vault.transaction_path.read_text(encoding="utf-8"))
        stored["stage"] = "tampered"
        vault.transaction_path.write_text(json.dumps(stored), encoding="utf-8")
        vault.transaction_path.chmod(0o600)

        with self.assertRaises(VaultTransactionError):
            vault.commit_switch(transaction)

        self.assertEqual(vault.active_account_id(), "A")
        self.assertTrue(vault.transaction_path.exists())

    def test_internal_id_collision_preserves_the_original_account(self):
        from account_vault import VaultIdentityConflict

        vault = self.make_vault()
        vault.import_account("A", synthetic_auth("account-a", "A"))

        with self.assertRaises(VaultIdentityConflict):
            vault.import_account("A", synthetic_auth("account-other", "other"))

        self.assertEqual(vault.account_identity("A"), "account-a")

    def test_external_login_identity_conflict_preserves_both_snapshots(self):
        from account_vault import VaultIdentityConflict

        vault = self.make_vault()
        self.import_two_accounts(vault)
        vault.activate("A")
        root_auth = self.codex_home / "auth.json"
        root_auth.write_text(
            json.dumps(synthetic_auth("external-account", "external")),
            encoding="utf-8",
        )
        root_auth.chmod(0o600)

        with self.assertRaises(VaultIdentityConflict):
            vault.prepare_switch("B")

        self.assertEqual(self.root_account_id(), "external-account")
        self.assertEqual(vault.account_identity("A"), "account-a")
        self.assertEqual(vault.account_identity("B"), "account-b")

    def test_prepare_failure_rolls_back_root_and_sanitizes_transaction(self):
        from account_vault import VaultTransactionError

        def fail_after_materialize(stage):
            if stage == "after_root_materialize":
                raise OSError("synthetic write failure with secret-marker")

        vault = self.make_vault()
        self.import_two_accounts(vault)
        vault.activate("A")
        vault.fault_injector = fail_after_materialize

        with self.assertRaises(VaultTransactionError):
            vault.prepare_switch("B")

        self.assertEqual(self.root_account_id(), "account-a")
        self.assertEqual(vault.active_account_id(), "A")
        if vault.transaction_path.exists():
            transaction = vault.transaction_path.read_text(encoding="utf-8")
            self.assertNotIn("secret-marker", transaction)
            self.assertNotIn("access_token", transaction)

    def test_recover_restores_previous_account_from_uncommitted_switch(self):
        vault = self.make_vault()
        self.import_two_accounts(vault)
        vault.activate("A")
        vault.prepare_switch("B")
        self.assertEqual(self.root_account_id(), "account-b")

        recovered = vault.recover()

        self.assertEqual(recovered, "rolled_back")
        self.assertEqual(self.root_account_id(), "account-a")
        self.assertEqual(vault.active_account_id(), "A")
        self.assertFalse(vault.transaction_path.exists())

    def test_nonblocking_lock_rejects_a_concurrent_transaction(self):
        from account_vault import VaultBusyError

        vault = self.make_vault()
        self.import_two_accounts(vault)
        vault.activate("A")
        descriptor = os.open(vault.lock_path, os.O_RDWR)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(VaultBusyError):
                vault.prepare_switch("B")
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def test_legacy_migration_dry_run_does_not_change_the_file_tree(self):
        vault = self.make_vault()
        profile_root = self.home / ".codex-profiles"
        self.make_legacy_profile("A", "account-a", "A")
        before = {
            path.relative_to(self.home): (
                path.lstat().st_mode,
                path.read_bytes() if path.is_file() and not path.is_symlink() else None,
            )
            for path in self.home.rglob("*")
        }

        report = vault.migrate_legacy_profiles(
            profile_root=profile_root,
            active_profile="A",
            dry_run=True,
        )

        after = {
            path.relative_to(self.home): (
                path.lstat().st_mode,
                path.read_bytes() if path.is_file() and not path.is_symlink() else None,
            )
            for path in self.home.rglob("*")
        }
        self.assertEqual(before, after)
        self.assertEqual(report["planned_import_count"], 1)
        self.assertFalse(self.codex_home.exists())

    def test_legacy_migration_keeps_old_profiles_and_replaces_root_symlink(self):
        vault = self.make_vault()
        profile_root = self.home / ".codex-profiles"
        profile_a = self.make_legacy_profile("A", "account-a", "A")
        profile_b = self.make_legacy_profile("B", "account-b", "B")
        self.codex_home.mkdir(mode=0o700)
        root_auth = self.codex_home / "auth.json"
        root_auth.symlink_to(profile_a / "auth.json")

        report = vault.migrate_legacy_profiles(
            profile_root=profile_root,
            active_profile="A",
            dry_run=False,
        )

        self.assertEqual(report["imported_count"], 2)
        self.assertEqual(vault.active_account_id(), "A")
        self.assertEqual(self.root_account_id(), "account-a")
        self.assertFalse(root_auth.is_symlink())
        self.assertEqual(stat.S_IMODE(root_auth.stat().st_mode), 0o600)
        self.assertTrue((profile_a / "auth.json").exists())
        self.assertTrue((profile_b / "auth.json").exists())

    def test_legacy_migration_deduplicates_the_same_official_identity(self):
        vault = self.make_vault()
        profile_root = self.home / ".codex-profiles"
        self.make_legacy_profile("A", "account-a", "A")
        self.make_legacy_profile("A-copy", "account-a", "A-copy")

        report = vault.migrate_legacy_profiles(
            profile_root=profile_root,
            active_profile="A",
            dry_run=False,
        )

        self.assertEqual(report["imported_count"], 1)
        self.assertEqual(report["deduplicated_profiles"], ["A-copy"])
        self.assertEqual(
            sorted(path.name for path in vault.accounts_root.iterdir() if path.is_dir()),
            ["A"],
        )

    def test_legacy_migration_conflict_does_not_overwrite_existing_vault(self):
        from account_vault import VaultIdentityConflict

        vault = self.make_vault()
        vault.import_account("A", synthetic_auth("vault-account", "vault"))
        self.codex_home.joinpath("auth.json").write_text(
            json.dumps(synthetic_auth("vault-account", "root")),
            encoding="utf-8",
        )
        self.codex_home.joinpath("auth.json").chmod(0o600)
        profile_root = self.home / ".codex-profiles"
        self.make_legacy_profile("A", "legacy-account", "legacy")

        with self.assertRaises(VaultIdentityConflict):
            vault.migrate_legacy_profiles(
                profile_root=profile_root,
                active_profile="A",
                dry_run=False,
            )

        self.assertEqual(vault.account_identity("A"), "vault-account")
        self.assertFalse(vault.state_path.exists())
        self.assertEqual(self.root_account_id(), "vault-account")

    def test_legacy_migration_failure_restores_root_symlink_and_state(self):
        from account_vault import VaultTransactionError

        vault = self.make_vault()
        profile_root = self.home / ".codex-profiles"
        profile_a = self.make_legacy_profile("A", "account-a", "A")
        self.make_legacy_profile("B", "account-b", "B")
        self.codex_home.mkdir(mode=0o700)
        root_auth = self.codex_home / "auth.json"
        root_auth.symlink_to(profile_a / "auth.json")

        def fail_after_root(stage):
            if stage == "after_legacy_root_replace":
                raise OSError("synthetic migration failure")

        vault.fault_injector = fail_after_root
        with self.assertRaises(VaultTransactionError):
            vault.migrate_legacy_profiles(
                profile_root=profile_root,
                active_profile="A",
                dry_run=False,
            )

        self.assertTrue(root_auth.is_symlink())
        self.assertEqual(root_auth.resolve(), (profile_a / "auth.json").resolve())
        self.assertFalse(vault.state_path.exists())
        self.assertFalse(
            any(path.is_dir() for path in vault.accounts_root.iterdir())
        )

    def test_legacy_migration_hard_crash_is_recovered_from_a_durable_journal(self):
        class SyntheticCrash(BaseException):
            pass

        vault = self.make_vault()
        profile_root = self.home / ".codex-profiles"
        profile_a = self.make_legacy_profile("A", "account-a", "A")
        self.make_legacy_profile("B", "account-b", "B")
        self.codex_home.mkdir(mode=0o700)
        root_auth = self.codex_home / "auth.json"
        root_auth.symlink_to(profile_a / "auth.json")

        def crash_after_root(stage):
            if stage == "after_legacy_root_replace":
                raise SyntheticCrash()

        vault.fault_injector = crash_after_root
        with self.assertRaises(SyntheticCrash):
            vault.migrate_legacy_profiles(
                profile_root=profile_root,
                active_profile="A",
                dry_run=False,
            )

        self.assertTrue(vault.migration_journal_path.exists())
        recovered = self.make_vault().recover()

        self.assertEqual(recovered, "legacy_migration_rolled_back")
        self.assertTrue(root_auth.is_symlink())
        self.assertEqual(root_auth.resolve(), (profile_a / "auth.json").resolve())
        self.assertFalse(vault.state_path.exists())
        self.assertFalse(vault.migration_journal_path.exists())
        self.assertFalse(
            any(path.is_dir() for path in vault.accounts_root.iterdir())
        )

    def test_legacy_migration_cleanup_removes_journal_before_backups(self):
        class SyntheticCrash(BaseException):
            pass

        vault = self.make_vault()
        profile_root = self.home / ".codex-profiles"
        profile_a = self.make_legacy_profile("A", "account-a", "A")
        self.codex_home.mkdir(mode=0o700)
        root_auth = self.codex_home / "auth.json"
        root_auth.symlink_to(profile_a / "auth.json")
        original_unlink = Path.unlink

        def crash_after_registry_backup_unlink(path, *args, **kwargs):
            result = original_unlink(path, *args, **kwargs)
            if path == vault.migration_registry_backup_path:
                raise SyntheticCrash()
            return result

        with (
            patch.object(Path, "unlink", crash_after_registry_backup_unlink),
            self.assertRaises(SyntheticCrash),
        ):
            vault.migrate_legacy_profiles(
                profile_root=profile_root,
                active_profile="A",
                dry_run=False,
            )

        self.assertFalse(vault.migration_journal_path.exists())
        self.assertEqual(self.make_vault().recover(), "none")
        snapshot = self.make_vault().storage_snapshot()
        self.assertEqual(snapshot["active_account_id"], "A")
        self.assertEqual(snapshot["account_count"], 1)

    def test_legacy_migration_rejects_same_identity_symlink_to_the_wrong_file(self):
        from account_vault import VaultIdentityConflict

        vault = self.make_vault()
        profile_root = self.home / ".codex-profiles"
        self.make_legacy_profile("A", "account-a", "A")
        decoy = self.home / "decoy-auth.json"
        decoy.write_text(
            json.dumps(synthetic_auth("account-a", "decoy")),
            encoding="utf-8",
        )
        decoy.chmod(0o600)
        self.codex_home.mkdir(mode=0o700)
        self.codex_home.joinpath("auth.json").symlink_to(decoy)

        with self.assertRaises(VaultIdentityConflict):
            vault.migrate_legacy_profiles(
                profile_root=profile_root,
                active_profile="A",
                dry_run=False,
            )

        self.assertTrue(self.codex_home.joinpath("auth.json").is_symlink())
        self.assertFalse(vault.state_path.exists())


if __name__ == "__main__":
    unittest.main()
