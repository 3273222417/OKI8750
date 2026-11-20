"""Offline regression checks for all Nova build entry points.

Run with: python -m unittest discover -s tests -v
Dependency: PyYAML. These checks validate wiring, not a full kernel build.
"""

import ast
from pathlib import Path
import re
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
VERSIONS = {"6.6.30", "6.6.50", "6.6.56", "6.6.57", "6.6.66", "6.6.89", "6.6.89_mtk", "6.6.118"}


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def load_workflow(path):
    # BaseLoader preserves the Actions `on` key and true/false input strings.
    return yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def run_step(workflow, needle):
    matches = [step for step in workflow["jobs"]["build"]["steps"]
               if needle in step.get("run", "")]
    if len(matches) != 1:
        raise AssertionError(f"expected one step containing {needle!r}, found {len(matches)}")
    return matches[0]


def make_target(text, target):
    matches = list(re.finditer(rf"^[ \t]*make[ \t]+[^\n]*[ \t]{re.escape(target)}(?:[ \t]+2>&1[ \t]+\|[^\n]*)?[ \t]*$", text, re.M))
    if len(matches) != 1:
        raise AssertionError(f"expected one make {target}, found {len(matches)}")
    return matches[0].start()


class WorkflowIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.paths = sorted((ROOT / ".github/workflows").glob("fastbuild_*.yml"))
        cls.workflows = [(path, load_workflow(path)) for path in cls.paths]

    def test_all_eight_workflows_are_covered(self):
        actual = {path.stem.removeprefix("fastbuild_") for path in self.paths}
        self.assertEqual(VERSIONS, actual)

    def test_sukisu_and_bakasu_select_distinct_setup_paths(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                inputs = workflow["on"]["workflow_dispatch"]["inputs"]
                self.assertIn("sukisu", inputs["ksu_type"]["options"])
                self.assertIn("bakasu", inputs["ksu_type"]["options"])
                step = run_step(workflow, "setup_sukisu.sh")
                match = re.search(
                    r'if \[\[ "\$\{\{ inputs\.ksu_type \}\}" == "sukisu" \]\]; then\n'
                    r'(?P<nova>.*?)\n\s*elif \[\[ "\$\{\{ inputs\.ksu_type \}\}" == "bakasu" \]\]; then\n'
                    r'(?P<bakasu>.*?)(?:\n\s*elif|\n\s*else)',
                    step["run"], re.S,
                )
                self.assertIsNotNone(match)
                self.assertIn('"$GITHUB_WORKSPACE/scripts/setup_sukisu.sh" "$PWD" "${{ inputs.susfs_enable }}"', match["nova"])
                self.assertNotIn("Baka-SU", match["nova"])
                self.assertIn("Baka-SU/BakaSU", match["bakasu"])
                self.assertEqual("ksu_version", step["id"])

    def test_checkout_precedes_helper_usage(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                steps = workflow["jobs"]["build"]["steps"]
                indexes = [i for i, step in enumerate(steps)
                           if step.get("uses", "").startswith("actions/checkout@")]
                self.assertEqual(1, len(indexes))
                checkout = steps[indexes[0]]
                self.assertEqual("false", checkout.get("with", {}).get("persist-credentials"))
                self.assertLess(indexes[0], steps.index(run_step(workflow, "setup_sukisu.sh")))

    def test_nova_susfs_isolated_from_legacy_patch_branch(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                step = run_step(workflow, "apply_sukisu_susfs.sh")
                self.assertEqual("inputs.susfs_enable", step["if"])
                nova = step["run"].split("apply_sukisu_susfs.sh", 1)[1].split("fi", 1)[0]
                self.assertIn("exit 0", nova)
                self.assertNotIn("69_hide_stuff", nova)
                self.assertIn('"$GITHUB_WORKSPACE/scripts/apply_sukisu_susfs.sh" "$PWD"', step["run"])

    def test_nova_headers_override_is_enabled(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                step = run_step(workflow, 'echo "CONFIG_HEADERS_INSTALL=y"')
                self.assertRegex(
                    step["run"],
                    r'if \[\[ "\$\{\{ inputs\.ksu_type \}\}" == "sukisu" \]\]; then\s+'
                    r'echo "CONFIG_HEADERS_INSTALL=y"[^\n]+\n\s*else\s+'
                    r'echo "CONFIG_HEADERS_INSTALL=n"',
                )

    def test_headers_then_image_then_verification_before_kpn(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                steps = workflow["jobs"]["build"]["steps"]
                step = run_step(workflow, "verify_sukisu_build.sh")
                run = step["run"]
                self.assertLess(make_target(run, "gki_defconfig"), make_target(run, "headers_install"))
                self.assertLess(make_target(run, "headers_install"), make_target(run, "Image"))
                self.assertLess(make_target(run, "Image"), run.index("verify_sukisu_build.sh"))
                self.assertIn("test -s out/usr/include/linux/unistd.h", run)
                self.assertIn("test -s out/arch/arm64/boot/Image", run)
                self.assertLess(steps.index(step), steps.index(run_step(workflow, "./kptools-linux -p")))

    def test_artifact_metadata_names_nova_and_records_source(self):
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                run = run_step(workflow, "cat ../sukisu-source.txt")["run"]
                self.assertIn('KSU_TYPENAME="SukiSU-Nova"', run)
                self.assertIn("ak3.log", run)

    def test_oki_689_uses_reviewed_compression_and_no_branch_release(self):
        workflow = next(w for p, w in self.workflows if p.name == "fastbuild_6.6.89.yml")
        step = run_step(workflow, "apply_compression_6.6.89.sh")
        self.assertEqual("inputs.lz4_enable", step["if"])
        self.assertNotIn("|| true", step["run"])
        self.assertIn("github.event.repository.default_branch", workflow["jobs"]["release"]["if"])
        local = read("local/builder_6.6.89.sh")
        self.assertIn(workflow["env"]["OKI_COMMIT"], local)
        self.assertIn("apply_compression_6.6.89.sh", local)

    def test_oki_689_checks_final_image_before_packaging(self):
        workflow = next(w for p, w in self.workflows if p.name == "fastbuild_6.6.89.yml")
        steps = workflow["jobs"]["build"]["steps"]
        build = run_step(workflow, "tee ../build-evidence/compile.log")
        check = run_step(workflow, "verify_image_config.py")
        self.assertIn("common/out/arch/arm64/boot/Image build-evidence/kernel.config", check["run"])
        self.assertLess(make_target(build["run"], "Image"), build["run"].rindex("cp out/.config"))
        self.assertLess(steps.index(run_step(workflow, "./kptools-linux -p")), steps.index(check))
        self.assertLess(steps.index(check), steps.index(run_step(workflow, "git clone https://github.com/cctv18/AnyKernel3")))

        local = read("local/builder_6.6.89.sh")
        self.assertLess(local.index("./kptools-linux -p"), local.index("verify_image_config.py"))
        self.assertLess(local.index("verify_image_config.py"), local.index("git clone https://github.com/cctv18/AnyKernel3"))

    def test_oki_689_net_extensions_leave_vendor_ipv6_nat_unchanged(self):
        workflow = next(w for p, w in self.workflows if p.name == "fastbuild_6.6.89.yml")
        net = run_step(workflow, 'echo "CONFIG_IP_SET_MAX=65534"')["run"]
        local = read("local/builder_6.6.89.sh")
        for script in (net, local):
            self.assertIn('echo "CONFIG_IP_SET=y"', script)
            self.assertIn('echo "CONFIG_NETFILTER_XT_SET=y"', script)
            self.assertNotIn("IP6_NF_NAT=y", script)
            self.assertNotIn("config.patch", script)

    def test_release_notes_link_to_nova_ci_channel(self):
        ci_url = re.search(r"^SUKISU_CI_RELEASE_URL=(.+)$", read("scripts/sukisu_sources.env"), re.M)[1]
        for path, workflow in self.workflows:
            with self.subTest(workflow=path.name):
                scripts = [step.get("run", "") for step in workflow["jobs"]["release"]["steps"]]
                self.assertTrue(any(ci_url in script for script in scripts))


class LocalIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.builders = [(path, path.read_text(encoding="utf-8"))
                        for path in sorted((ROOT / "local").glob("builder_*.sh"))]

    def test_all_eight_local_builders_are_covered(self):
        actual = {path.stem.removeprefix("builder_") for path, _ in self.builders}
        self.assertEqual(VERSIONS, actual)

    def test_distinct_local_setup_and_susfs_branches(self):
        for path, text in self.builders:
            with self.subTest(builder=path.name):
                setup = text.split("# ===== 拉取 KSU 并设置版本号 =====", 1)[1]
                match = re.search(
                    r'if \[\[ "\$KSU_BRANCH" == \[yY\] \]\]; then\n(?P<nova>.*?)'
                    r'\nelif \[\[ "\$KSU_BRANCH" == \[rR\] \]\]; then\n(?P<bakasu>.*?)\nelif',
                    setup, re.S,
                )
                self.assertIsNotNone(match)
                self.assertIn('"$SCRIPT_DIR/../scripts/setup_sukisu.sh" "$PWD" "$NOVA_SUSFS"', match["nova"])
                self.assertIn("NOVA_SUSFS=false", match["nova"])
                self.assertIn("NOVA_SUSFS=true", match["nova"])
                self.assertNotIn("Baka-SU", match["nova"])
                self.assertIn("Baka-SU/BakaSU", match["bakasu"])
                self.assertRegex(text, r'if \[\[ "\$KSU_BRANCH" == \[yY\] && "\$APPLY_SUSFS" == \[yY\] \]\]; then\s+bash "\$SCRIPT_DIR/../scripts/apply_sukisu_susfs.sh"')

    def test_local_headers_preserved_and_installed_before_compile(self):
        for path, text in self.builders:
            with self.subTest(builder=path.name):
                self.assertRegex(text, r'if \[\[ "\$KSU_BRANCH" == \[yY\] \]\]; then\s+echo "CONFIG_HEADERS_INSTALL=y"')
                self.assertLess(make_target(text, "gki_defconfig"), make_target(text, "headers_install"))
                self.assertLess(make_target(text, "headers_install"), make_target(text, "all"))
                self.assertIn("test -s out/usr/include/linux/unistd.h", text)
                self.assertIn("test -s out/arch/arm64/boot/Image", text)
                self.assertLess(make_target(text, "all"), text.index("verify_sukisu_build.sh"))
                self.assertLess(text.index("verify_sukisu_build.sh"), text.index("./kptools-linux -p"))
                self.assertRegex(text, r"apt-get install[^\n]*\brsync\b")

    def test_local_packages_include_source_provenance(self):
        for path, text in self.builders:
            with self.subTest(builder=path.name):
                self.assertIn('KSU_TYPE="SukiSU-Nova"', text)
                self.assertIn('cp "$WORKDIR/kernel_workspace/sukisu-source.txt" ./AnyKernel3/', text)


class SharedIntegrationContractTests(unittest.TestCase):
    def test_config_contract_disables_builtin_kpm_and_enables_uapi(self):
        tree = ast.parse(read("scripts/prepare_sukisu.py"))
        literals = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.Dict):
                for key, value in zip(node.keys, node.values):
                    if isinstance(key, ast.Constant) and isinstance(value, ast.Constant):
                        literals[key.value] = value.value
        self.assertEqual("y", literals["CONFIG_KSU"])
        self.assertEqual("y", literals["CONFIG_HEADERS_INSTALL"])
        self.assertEqual("n", literals["CONFIG_KPM"])
        self.assertIn('"$SCRIPT_DIR/prepare_sukisu.py"', read("scripts/setup_sukisu.sh"))

    def test_pinned_official_sources_and_full_history_version(self):
        env = dict(re.findall(r"^([A-Z_]+)=([^\n]+)$", read("scripts/sukisu_sources.env"), re.M))
        self.assertEqual("https://git.zako.shirkneko.top:20004/shirkneko/SukiSU.git", env["SUKISU_REPOSITORY"])
        self.assertEqual(env["SUKISU_REPOSITORY"].removesuffix(".git") + "/releases/tag/manager-ci", env["SUKISU_CI_RELEASE_URL"])
        self.assertRegex(env["SUKISU_CI_VERSION_CODE"], r"^[1-9][0-9]+$")
        for key in ("SUKISU_MAIN_COMMIT", "SUKISU_BUILTIN_COMMIT", "SUKISU_SUSFS_COMMIT"):
            self.assertRegex(env[key], r"^[0-9a-f]{40}$")
        self.assertEqual("30000", env["SUKISU_VERSION_BASE"])
        self.assertEqual("996", env["SUKISU_VERSION_OFFSET"])
        setup = read("scripts/setup_sukisu.sh")
        self.assertIn('true) BRANCH=builtin; COMMIT="$SUKISU_BUILTIN_COMMIT"', setup)
        self.assertIn('false) BRANCH=main; COMMIT="$SUKISU_MAIN_COMMIT"', setup)
        self.assertIn('rev-list --count "$SUKISU_MAIN_COMMIT"', setup)
        self.assertIn("rev-parse --is-shallow-repository", setup)
        self.assertIn('"$VERSION" != "$SUKISU_CI_VERSION_CODE"', setup)
        self.assertIn('checkout --detach "$COMMIT"', setup)
        self.assertNotRegex(setup, r"(?m)^\s*curl\b")

    def test_susfs_patch_must_succeed_before_adapter(self):
        script = read("scripts/apply_sukisu_susfs.sh")
        active = "\n".join(line for line in script.splitlines() if not line.lstrip().startswith("#"))
        self.assertIn("set -euo pipefail", active)
        self.assertIn('"$SUKISU_SUSFS_COMMIT"', active)
        self.assertIn("--dry-run", active)
        self.assertLess(active.index("--dry-run"), active.index("adapt_sukisu_susfs.py"))
        self.assertNotIn("|| true", active)
        self.assertNotIn("69_hide_stuff.patch", active)

    def test_build_verifier_requires_real_outputs_and_correct_configs(self):
        script = read("scripts/verify_sukisu_build.sh")
        self.assertIn("set -euo pipefail", script)
        for flag in ("CONFIG_KSU=y", "CONFIG_HEADERS_INSTALL=y", "CONFIG_KSU_SUSFS=y", "CONFIG_KPM=y"):
            self.assertIn(flag, script)
        for artifact in ("out/usr/include/linux/unistd.h", "out/drivers/kernelsu/preinit/runner.elf", "out/arch/arm64/boot/Image"):
            self.assertIn("test -s " + artifact, script)
        self.assertIn("out/drivers/kernelsu/.ksu_main.o.cmd", script)
        self.assertIn("out/drivers/kernelsu/core/.init.o.cmd", script)
        self.assertIn("-DKSU_VERSION=$SUKISU_CI_VERSION_CODE([[:space:]]|$)", script)


if __name__ == "__main__":
    unittest.main()
