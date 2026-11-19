"""Offline tests for the deliberately narrow SukiSU-Nova/SUSFS ABI adapter."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "adapt_sukisu_susfs", Path(__file__).resolve().parents[1] / "scripts/adapt_sukisu_susfs.py"
)
adapter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter)

BOOL = """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_su_compat_enabled;
void caller(void) {
    if (static_branch_likely(&ksu_su_compat_enabled)) {
        do_something();
    }
}
#endif
"""
READ = """#ifdef CONFIG_KSU_SUSFS
extern struct static_key_true ksu_is_init_rc_hook_enabled;
extern __attribute__((cold)) void ksu_handle_sys_read(unsigned int fd);
#endif
SYSCALL_DEFINE3(read, unsigned int, fd, char __user *, buf, size_t, count)
{
#ifdef CONFIG_KSU_SUSFS
    if (static_branch_unlikely(&ksu_is_init_rc_hook_enabled))
        ksu_handle_sys_read(fd);
#endif
    return ksys_read(fd, buf, count);
}
"""
SUCOMPAT = """bool ksu_su_compat_enabled __read_mostly = true;
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,
                        int *__unused_flags) { return 0; }
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags) { return 0; }
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
                       void *envp, int *flags) { return 0; }
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
                       void *envp, int *flags) { return 0; }
"""
KSUD = """DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);
DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);
int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr)
{ return 0; }
"""


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.common = self.root / "common"
        self.ksu = self.root / "KernelSU"
        for relative in adapter.BOOL_FILES:
            self.put(self.common / relative, BOOL)
        self.put(self.common / adapter.READ_FILE, READ)
        self.put(self.ksu / "kernel/feature/sucompat.c", SUCOMPAT)
        self.put(self.ksu / "kernel/runtime/ksud.c", KSUD)
        self.put(self.ksu / "kernel/hook/lsm_hook.c",
                 "int ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid) { return 0; }\n")
        self.put(self.ksu / "kernel/Kconfig",
                 "config KSU_SUSFS\n\tdefault y\nconfig KSU_SUSFS_PRIORITY_UID_FILTER\n\tdefault y\n")

    @staticmethod
    def put(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8"))

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes()
                for p in self.root.rglob("*") if p.is_file()}

    def test_adapts_exactly_four_files_and_is_idempotent(self):
        nova_before = {str(p): p.read_bytes() for p in self.ksu.rglob("*") if p.is_file()}
        changed = adapter.adapt_tree(self.common, self.ksu)
        self.assertEqual(4, len(changed))
        for relative in adapter.BOOL_FILES:
            text = (self.common / relative).read_text()
            self.assertIn("extern bool ksu_su_compat_enabled;", text)
            self.assertIn("likely(READ_ONCE(ksu_su_compat_enabled))", text)
            self.assertNotIn("static_branch_likely(&ksu_su_compat_enabled)", text)
        read = (self.common / adapter.READ_FILE).read_text()
        self.assertIn("ksu_handle_sys_read(fd, &buf, &count);", read)
        self.assertIn("extern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr, size_t *count_ptr);", read)
        self.assertIn("static_branch_unlikely(&ksu_is_init_rc_hook_enabled)", read)
        before = self.snapshot()
        self.assertEqual([], adapter.adapt_tree(self.common, self.ksu))
        self.assertEqual(before, self.snapshot())
        self.assertEqual(nova_before, {str(p): p.read_bytes() for p in self.ksu.rglob("*") if p.is_file()})

    def test_check_does_not_write(self):
        before = self.snapshot()
        self.assertEqual(4, len(adapter.adapt_tree(self.common, self.ksu, check=True)))
        self.assertEqual(before, self.snapshot())

    def test_crlf_source_checkout(self):
        for path in self.root.rglob("*"):
            if path.is_file():
                path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(4, len(adapter.adapt_tree(self.common, self.ksu)))
        self.assertEqual([], adapter.adapt_tree(self.common, self.ksu))

    def test_kconfig_help_is_not_parsed_as_c_literals(self):
        self.put(self.ksu / "kernel/Kconfig", "config KSU_FEATURE_ADBROOT\n"
                 "\thelp\n\t  Build KernelSU's adb root feature.\nconfig KSU_SUSFS\n"
                 "config KSU_SUSFS_PRIORITY_UID_FILTER\n\thelp\n\t  User's choice.\n")
        self.assertEqual(4, len(adapter.adapt_tree(self.common, self.ksu)))

    def test_unknown_driver_read_signature_rejected_before_writes(self):
        self.put(self.ksu / "kernel/runtime/ksud.c", KSUD.replace("size_t *count_ptr", "size_t count_ptr"))
        before = self.snapshot()
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_tree(self.common, self.ksu)
        self.assertEqual(before, self.snapshot())

    def test_new_static_key_driver_is_not_rewritten_as_bool(self):
        self.put(self.ksu / "kernel/feature/sucompat.c",
                 SUCOMPAT + "DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled);\n")
        before = self.snapshot()
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_tree(self.common, self.ksu)
        self.assertEqual(before, self.snapshot())

    def test_mixed_bool_declaration_and_static_key_call_is_rejected(self):
        text = BOOL.replace("extern struct static_key_true", "extern bool")
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_bool(text, "fixture")

    def test_extra_reference_is_rejected(self):
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_bool(BOOL + "void extra(void) { use(ksu_su_compat_enabled); }\n", "fixture")

    def test_comments_and_literals_do_not_create_false_matches(self):
        comment = '// static_branch_likely(&ksu_su_compat_enabled)\n'
        literal = 'char *s = "ksu_su_compat_enabled";\n'
        result = adapter.adapt_bool(comment + literal + BOOL, "fixture")
        self.assertTrue(result.startswith(comment + literal))
        self.assertIn("likely(READ_ONCE(ksu_su_compat_enabled))", result)

    def test_preserves_unlikely_hint_and_crlf(self):
        text = BOOL.replace("static_branch_likely", "static_branch_unlikely").replace("\n", "\r\n")
        result = adapter.adapt_bool(text, "fixture")
        self.assertIn("unlikely(READ_ONCE(ksu_su_compat_enabled))", result)
        self.assertEqual(text.count("\r\n"), result.count("\r\n"))

    def test_wrong_read_variable_scope_is_rejected(self):
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_read(READ.replace("size_t, count)", "size_t, length)"))

    def test_read_call_outside_syscall_is_rejected(self):
        text = READ.replace("        ksu_handle_sys_read(fd);", "        other(fd);")
        text += "void other(void) { ksu_handle_sys_read(fd); }\n"
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_read(text)

    def test_partial_read_adaptation_is_rejected(self):
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_read(READ.replace("ksu_handle_sys_read(fd);", "ksu_handle_sys_read(fd, &buf, &count);"))

    def test_last_file_error_does_not_partially_write_first_files(self):
        self.put(self.common / adapter.READ_FILE, READ.replace("ksu_handle_sys_read(fd);", "other(fd);"))
        before = self.snapshot()
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_tree(self.common, self.ksu)
        self.assertEqual(before, self.snapshot())

    def test_missing_driver_feature_rejected(self):
        self.put(self.ksu / "kernel/Kconfig", "config KSU_SUSFS\n")
        with self.assertRaises(adapter.AdaptationError):
            adapter.adapt_tree(self.common, self.ksu)


if __name__ == "__main__":
    unittest.main()
