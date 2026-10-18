"""Safety regressions for the offline native image installation kit."""

from __future__ import annotations

import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import native_image as image

BUILD = "a" * 64
PYTHON = "b" * 64
ROOT_PEM = b"-----BEGIN CERTIFICATE-----\nMAA=\n-----END CERTIFICATE-----\n"
REAL_LSTAT = Path.lstat


def root_metadata(path: Path) -> os.stat_result:
    """Model root ownership only; real modes, file kinds and bytes remain checked."""
    metadata = REAL_LSTAT(path)
    return os.stat_result((*metadata[:4], 0, 0, *metadata[6:]))


class NativeImageTest(unittest.TestCase):
    def make_trust(self, root: Path) -> list[image.Entry]:
        records: list[image.Entry] = []
        for name in (image.TRUST_BASE, image.TRUST_DESTINATION, "root/etc/unrelated"):
            relative = Path(name).relative_to("root")
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            data = b"pinned-vendor-fixture\n" if name != "root/etc/unrelated" else b"unrelated\n"
            path.write_bytes(data)
            path.chmod(0o444)
            records.append(image.Entry(name, "file", hashlib.sha256(data).hexdigest(), 0o444))
        return records

    def manage_trust(self, root: Path) -> Path:
        target = root / f"var/lib/overalls-trust/bundle-{BUILD}.pem"
        target.parent.mkdir(parents=True)
        target.write_bytes((root / "etc/overalls/system-ca.pem").read_bytes() + ROOT_PEM)
        target.chmod(0o644)
        destination = root / "etc/ssl/cacert.pem"
        destination.unlink()
        destination.symlink_to("/" + str(target.relative_to(root)))
        return target

    def make_kit(self, root: Path) -> None:
        (root / "root/usr/bin").mkdir(parents=True)
        executable = root / "root/usr/bin/git"
        executable.write_bytes(b"native-git-fixture")
        executable.chmod(0o755)
        (root / "root/usr/bin/git-alias").symlink_to("git")
        base = root.parent / "pinned.raw"
        base.write_bytes(b"pinned-whole-gpt-image")
        image.pack(root, BUILD, PYTHON, base)

    def test_exact_payload_and_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "kit"
            self.make_kit(root)
            self.assertEqual(len(image.check_kit(root, BUILD, native_runtime=False)), 2)
            (root / "root/usr/bin/git").chmod(0o444)
            with self.assertRaisesRegex(ValueError, "payload differs"):
                image.check_kit(root, BUILD, native_runtime=False)

    def test_changed_file_and_link_refuse(self) -> None:
        for mutation in ("bytes", "symlink"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "kit"
                self.make_kit(root)
                if mutation == "bytes":
                    (root / "root/usr/bin/git").chmod(0o755)
                    (root / "root/usr/bin/git").write_bytes(b"foreign")
                else:
                    link = root / "root/usr/bin/git-alias"
                    link.unlink()
                    link.symlink_to("/foreign")
                with self.assertRaisesRegex(ValueError, "payload differs|symlink"):
                    image.check_kit(root, BUILD, native_runtime=False)

    def test_special_file_refuses(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "kit"
            self.make_kit(root)
            os.mkfifo(root / "fifo")
            with self.assertRaisesRegex(ValueError, "special file"):
                image.check_kit(root, BUILD, native_runtime=False)

    def test_imported_pool_is_refused_before_device_access(self) -> None:
        with self.assertRaisesRegex(ValueError, "must not already be imported"):
            image.check_device(Path("/dev/dsk/c999d0s0"), "12345", "999\n12345\n")

    def test_invalid_guids_refuse(self) -> None:
        for value in ("0", "01", "-1", "1\n2", str(1 << 64)):
            with self.subTest(value=value), self.assertRaises(ValueError):
                image.pool_guid(value)

    def test_whole_disk_length_is_exact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "disk"
            path.write_bytes(b"pinned")
            for length in (5, 7):
                with self.subTest(length=length), self.assertRaises(ValueError):
                    image.stream_digest(path, length)

    def test_installed_receipt_paths_and_duplicates_refuse(self) -> None:
        valid = image.entry_json(image.Entry("root/usr/bin/git", "file", BUILD, 0o755))
        self.assertEqual(len(image.checked_entries([valid])), 1)
        with self.assertRaises(ValueError):
            image.checked_entries([valid, valid])
        for name in ("root/../etc/passwd", "root/etc/./passwd", "root/dev/node"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                image.checked_entries([image.entry_json(image.Entry(name, "file", BUILD, 0o644))])

    def test_links_remain_inside_guest_or_kit(self) -> None:
        for name, target in (
            ("root/usr/lib/amd64/libc.so", "../../../lib/amd64/libc.so.1"),
            ("root/lib/32", "."),
            ("root/usr/bin/git", "/usr/libexec/git"),
            ("kernel/bin/helper", "../lib/helper"),
        ):
            with self.subTest(name=name, target=target):
                image.check_symlink(name, target)
        for name, target in (
            ("root/usr/bin/git", "../../../../outside"),
            ("root/usr/bin/git", "/../outside"),
            ("root/usr/bin/git", "/nix/store/host-binary"),
            ("kernel/bin/helper", "../../../outside"),
            ("kernel/bin/helper", "/usr/bin/host-helper"),
            ("root/usr/bin/git", "git\nforeign"),
        ):
            with self.subTest(name=name, target=target), self.assertRaises(ValueError):
                image.check_symlink(name, target)
        with self.assertRaises(ValueError):
            image.checked_entries(
                [
                    image.entry_json(
                        image.Entry("root/usr/bin/git", "symlink", "", 0o777, "../../../../outside")
                    )
                ]
            )

    def test_sudoers_target_mode_is_distinct_from_immutable_kit(self) -> None:
        source = [
            image.Entry("root/etc/sudoers", "file", BUILD, 0o444),
            image.Entry("root/usr/bin/git", "file", PYTHON, 0o555),
            image.Entry("kernel/objects/viosock.o", "file", BUILD, 0o444),
        ]
        installed = image.installation_entries(source)
        self.assertEqual(source[0].mode, 0o444)
        self.assertEqual(installed[0], image.Entry("root/etc/sudoers", "file", BUILD, 0o440))
        self.assertEqual(installed[1], source[1])
        self.assertEqual(len(installed), 2)
        self.assertEqual(installed, image.installation_entries(installed))
        for files in ([], [image.Entry("root/etc/sudoers", "symlink", "", 0o777, "policy")]):
            with self.subTest(files=files), self.assertRaisesRegex(ValueError, "regular.*sudoers"):
                image.installation_entries(files)

    def test_manifest_binds_final_nix_publication_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "kit"
            self.make_kit(root)
            policy = root / "root/etc/sudoers"
            policy.parent.mkdir()
            policy.write_bytes(b"root ALL=(ALL) ALL\n")
            policy.chmod(0o440)
            base = root.parent / "pinned.raw"
            image.pack(root, BUILD, PYTHON, base)
            files = image.check_kit(root, BUILD, native_runtime=False)
            self.assertEqual((root / "root/usr/bin/git").stat().st_mode & 0o777, 0o555)
            self.assertEqual(policy.stat().st_mode & 0o777, 0o444)
            self.assertEqual(next(row for row in files if row.name == image.SUDOERS).mode, 0o444)
            self.assertEqual(image.installation_entries(files)[0].mode, 0o440)

    def test_offline_service_disable_requires_complete_false_properties(self) -> None:
        row = "general/enabled boolean false\n"
        complete = row * len(image.STOCK_SERVICES)
        image.check_disabled_service_properties(complete)
        for output in (
            "",
            complete.removesuffix(row),
            complete + row,
            complete.replace("false", "true", 1),
            complete.replace("boolean", "astring", 1),
            complete + "svccfg: refused\n",
        ):
            with (
                self.subTest(output=output),
                self.assertRaisesRegex(ValueError, "must be disabled"),
            ):
                image.check_disabled_service_properties(output)

    def test_console_configuration_preserves_stock_and_binds_both_files(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch("native_candidate.check_ownership"),
            mock.patch("native_candidate.os.fchown"),
        ):
            root = Path(temporary).resolve()
            (root / "etc").mkdir()
            (root / "boot").mkdir()
            system = root / "etc/system"
            loader = root / "boot/loader.conf.local"
            original = b"* retained stock kernel configuration\nset maxusers=2048\n"
            local = b"# retained local loader configuration\nautoboot_delay=3\n"
            system.write_bytes(original)
            loader.write_bytes(local)
            records = image.configure_console(root)
            self.assertEqual(system.read_bytes(), original + image.CONSOLE_SETTINGS["etc/system"])
            self.assertEqual(
                loader.read_bytes(), local + image.CONSOLE_SETTINGS["boot/loader.conf.local"]
            )
            self.assertEqual(
                image.checked_entries([image.entry_json(row) for row in records]), records
            )
            image.check_console_configuration(root, records)
            for data in image.CONSOLE_SETTINGS.values():
                for forbidden in (b"boot_kmdb", b"boot_single", b"boot_verbose", b"autologin"):
                    self.assertNotIn(forbidden, data)
            loader.write_bytes(loader.read_bytes().replace(b'console="ttya"', b'console="text"'))
            with self.assertRaisesRegex(ValueError, "configuration differs"):
                image.check_console_configuration(root, records)

    def test_transient_boot_arguments_remove_only_single_user_flag(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch("native_candidate.check_ownership"),
            mock.patch("native_candidate.os.fchown"),
        ):
            root = Path(temporary).resolve()
            path = root / image.TRANSIENT_CONFIG
            path.parent.mkdir(parents=True)
            original = (
                b"bootfile='/platform/i86pc/kernel/amd64/unix;unix'\n"
                b"boot-args='-B zfs-bootfs=pool/ROOT/candidate,bootpath=\"pci@0\" -s -B console=ttya'\n"
                b"other='-shelf -safe'\n"
            )
            path.write_bytes(original)
            with self.assertRaisesRegex(ValueError, "still requests single-user"):
                image.check_transient_configuration(root)
            image.sanitize_transient_configuration(root)
            expected = original.replace(b" -s -B", b" -B")
            self.assertEqual(path.read_bytes(), expected)
            self.assertEqual(
                image._remove_transient_single_user(b"boot-args='-s -B console=ttya'\n"),
                b"boot-args='-B console=ttya'\n",
            )
            image.check_transient_configuration(root)
            self.assertIn(b"-shelf", path.read_bytes())
            self.assertIn(b"-safe", path.read_bytes())

    def test_transient_boot_arguments_reject_unsafe_file(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch("native_candidate.check_ownership"),
        ):
            root = Path(temporary).resolve()
            path = root / image.TRANSIENT_CONFIG
            path.parent.mkdir(parents=True)
            path.write_bytes(b"boot-args='-s'\n")
            path.chmod(0o666)
            with self.assertRaisesRegex(ValueError, "safe regular file"):
                image.sanitize_transient_configuration(root)

    def test_network_handoff_removes_only_fixed_files_and_refuses_restoration(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch("native_candidate.check_ownership"),
        ):
            root = Path(temporary).resolve()
            (root / "etc").mkdir()
            unrelated = root / "etc/hostname.other0"
            unrelated.write_bytes(b"unrelated-interface\n")
            for relative in image.STOCK_NETWORK_FILES:
                (root / relative).write_bytes(b"plumb\n")
            image.remove_stock_network(root)
            image.check_stock_network_absent(root)
            image.remove_stock_network(root)
            self.assertEqual(unrelated.read_bytes(), b"unrelated-interface\n")
            for relative in image.STOCK_NETWORK_FILES:
                path = root / relative
                path.write_bytes(b"plumb\n")
                with self.assertRaisesRegex(ValueError, "remain absent"):
                    image.check_stock_network_absent(root)
                path.unlink()

    def test_native_ssh_requires_safe_installed_executable(self) -> None:
        for mutation in (
            "valid",
            "missing",
            "symlink",
            "directory",
            "mode",
            "writable",
            "privileged",
            "bytes",
        ):
            with (
                self.subTest(mutation=mutation),
                tempfile.TemporaryDirectory() as temporary,
                mock.patch("native_candidate.check_ownership"),
                mock.patch.object(Path, "lstat", root_metadata),
            ):
                root = Path(temporary).resolve()
                executable = root / image.NATIVE_SSHD
                executable.parent.mkdir(parents=True)
                if mutation == "symlink":
                    executable.symlink_to("/usr/sbin/sshd")
                elif mutation == "directory":
                    executable.mkdir()
                elif mutation != "missing":
                    executable.write_bytes(b"foreign" if mutation == "bytes" else b"\x7fELFnative")
                    modes = {"mode": 0o644, "writable": 0o775}
                    executable.chmod(modes.get(mutation, 0o755))

                def checked_metadata(
                    path: Path, *, selected: str = mutation, target: Path = executable
                ) -> os.stat_result:
                    metadata = root_metadata(path)
                    if selected == "privileged" and path == target:
                        return os.stat_result((metadata.st_mode | 0o4000, *metadata[1:]))
                    return metadata

                # The build sandbox forbids creating setuid files; model only
                # that stat bit while checking actual bytes and executable modes.
                with mock.patch.object(Path, "lstat", checked_metadata):
                    if mutation == "valid":
                        image.check_native_ssh_executable(root)
                    else:
                        with self.assertRaises((ValueError, FileNotFoundError)):
                            image.check_native_ssh_executable(root)

    def test_exact_kit_cannot_reintroduce_stock_network_authority(self) -> None:
        for relative in image.STOCK_NETWORK_FILES:
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary) / "kit"
                self.make_kit(root)
                path = root / "root" / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"plumb\n")
                image.pack(root, BUILD, PYTHON, root.parent / "pinned.raw")
                with self.assertRaisesRegex(ValueError, "stock network authority"):
                    image.check_kit(root, BUILD, native_runtime=False)

    def test_network_handoff_preflights_all_paths_before_removal(self) -> None:
        for kind in ("symlink", "directory"):
            with (
                self.subTest(kind=kind),
                tempfile.TemporaryDirectory() as temporary,
                mock.patch("native_candidate.check_ownership"),
            ):
                root = Path(temporary).resolve()
                (root / "etc").mkdir()
                first = root / image.STOCK_NETWORK_FILES[0]
                first.write_bytes(b"plumb\n")
                last = root / image.STOCK_NETWORK_FILES[-1]
                if kind == "symlink":
                    last.symlink_to(first)
                else:
                    last.mkdir()
                with self.assertRaises(ValueError):
                    image.remove_stock_network(root)
                self.assertEqual(first.read_bytes(), b"plumb\n")

    def test_console_configuration_requires_both_exact_regular_records(self) -> None:
        valid = [
            image.Entry(f"root/{relative}", "file", BUILD, 0o644)
            for relative in image.CONSOLE_SETTINGS
        ]
        for records in (
            [],
            valid[:1],
            [*valid, valid[0]],
            [image.Entry(valid[0].name, "symlink", "", 0o777, "foreign"), valid[1]],
            [image.Entry(valid[0].name, "file", BUILD, 0o666), valid[1]],
        ):
            with self.subTest(records=records), self.assertRaisesRegex(ValueError, "records"):
                image.check_console_configuration(Path("/unread-fixture"), records)

    def test_console_preflight_refuses_symlinks_before_any_configuration_write(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch("native_candidate.check_ownership"),
        ):
            root = Path(temporary).resolve() / "root"
            (root / "etc").mkdir(parents=True)
            system = root / "etc/system"
            system.write_bytes(b"* stock\n")
            (root / "boot").symlink_to(root.parent)
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                image.configure_console(root)
            self.assertEqual(system.read_bytes(), b"* stock\n")

    def test_console_missing_stock_and_oversize_configuration_refuse(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch("native_candidate.check_ownership"),
        ):
            root = Path(temporary).resolve()
            (root / "etc").mkdir()
            system = root / "etc/system"
            with self.assertRaisesRegex(ValueError, "stock system"):
                image.configure_console(root)
            original = b"*" * 65536
            system.write_bytes(original)
            with self.assertRaisesRegex(ValueError, "exceeds its bound"):
                image.configure_console(root)
            self.assertEqual(system.read_bytes(), original)

    def test_effective_trust_accepts_exact_vendor_or_narrow_managed_state(self) -> None:
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch("native_candidate.check_ownership"),
            mock.patch.object(Path, "lstat", root_metadata),
        ):
            root = Path(temporary).resolve()
            records = self.make_trust(root)
            image.check_installed(root, records)
            image.check_installed(root, records, runtime_trust=True)
            self.manage_trust(root)
            image.check_installed(root, records, runtime_trust=True)
            with self.assertRaises(ValueError):
                image.check_installed(root, records)
            unrelated = root / "etc/unrelated"
            unrelated.chmod(0o644)
            unrelated.write_bytes(b"changed\n")
            unrelated.chmod(0o444)
            with self.assertRaisesRegex(ValueError, "payload bytes"):
                image.check_installed(root, records, runtime_trust=True)

    def test_managed_trust_refuses_foreign_links_modes_and_vendor_changes(self) -> None:
        for mutation in ("link", "mode", "prefix", "base", "target-link"):
            with (
                self.subTest(mutation=mutation),
                tempfile.TemporaryDirectory() as temporary,
                mock.patch("native_candidate.check_ownership"),
                mock.patch.object(Path, "lstat", root_metadata),
            ):
                root = Path(temporary).resolve()
                records = self.make_trust(root)
                target = self.manage_trust(root)
                if mutation == "link":
                    destination = root / "etc/ssl/cacert.pem"
                    destination.unlink()
                    destination.symlink_to("/var/lib/overalls-trust/../foreign.pem")
                elif mutation == "mode":
                    target.chmod(0o666)
                elif mutation == "prefix":
                    target.write_bytes(b"foreign vendor\n" + ROOT_PEM)
                elif mutation == "base":
                    base = root / "etc/overalls/system-ca.pem"
                    base.chmod(0o644)
                    base.write_bytes(b"substituted vendor\n")
                else:
                    target.unlink()
                    target.symlink_to(root / "etc/overalls/system-ca.pem")
                with self.assertRaises(ValueError):
                    image.check_installed(root, records, runtime_trust=True)

    def test_managed_trust_requires_complete_bounded_public_pem_roots(self) -> None:
        image.check_trust_roots(ROOT_PEM)
        image.check_trust_roots(ROOT_PEM * 32)
        for invalid in (
            b"",
            ROOT_PEM * 33,
            ROOT_PEM + b"unexpected",
            b"prefix" + ROOT_PEM,
            ROOT_PEM.replace(b"MAA=", b"not-pem!"),
            ROOT_PEM.replace(b"MAA=", b""),
            ROOT_PEM.replace(b"CERTIFICATE", b"PRIVATE KEY"),
            ROOT_PEM.replace(b"MAA=", b"A" * 17000),
            ROOT_PEM.replace(b"-----END CERTIFICATE-----", b""),
        ):
            with self.subTest(size=len(invalid)), self.assertRaises(ValueError):
                image.check_trust_roots(invalid)


if __name__ == "__main__":
    unittest.main()
