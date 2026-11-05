#!/usr/bin/env python3
"""locate_artifacts (Run 23): an interrupted build run - artifacts present, no
.nebulaos-build-verified record - is skipped, so a finished run of the same
commit is found instead. A scratch BUILD_BASE, never a real build tree.

Run: python3 tests/hardware-locate-artifacts-tests.py
"""
import hashlib, os, shutil, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "hardware"))
import nebulaos_agent as agent  # noqa: E402

HEAD = "a" * 40


def _run(base, name, ximage, rootfs, finished):
    art = os.path.join(base, HEAD, name, "artifacts", "buildroot-halley5-v30-image")
    os.makedirs(art)
    for fname, data in (("xImage", ximage), ("rootfs.squashfs", rootfs), ("build-manifest.txt", b"m")):
        with open(os.path.join(art, fname), "wb") as handle:
            handle.write(data)
    if finished:
        open(os.path.join(base, HEAD, name, ".nebulaos-build-verified"), "w").write("BUILD_VERIFIED=YES\n")
    return os.path.join(base, HEAD, name)


class LocateArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.base = tempfile.mkdtemp(prefix="locate.")
        self._saved = agent.BUILD_BASE
        agent.BUILD_BASE = self.base
        self.x, self.r = b"kernel", b"rootfs"
        self.xs, self.rs = hashlib.sha256(self.x).hexdigest(), hashlib.sha256(self.r).hexdigest()

    def tearDown(self):
        agent.BUILD_BASE = self._saved
        shutil.rmtree(self.base)

    def test_dead_run_first_is_skipped_for_the_finished_one(self):
        # the dead run sorts first, as the power-cut run did
        _run(self.base, "run-20261104T132303Z-1", self.x, self.r, finished=False)
        good = _run(self.base, "run-20261104T154018Z-2", self.x, self.r, finished=True)
        artifacts, run_dir = agent.locate_artifacts(HEAD, self.xs, self.rs)
        self.assertEqual(run_dir, good)
        self.assertEqual(artifacts.ximage_sha, self.xs)

    def test_only_a_dead_run_is_refused_and_says_why(self):
        _run(self.base, "run-20261104T132303Z-1", self.x, self.r, finished=False)
        with self.assertRaises(agent.AgentRefusal) as ctx:
            agent.locate_artifacts(HEAD, self.xs, self.rs)
        self.assertIn("never finished", str(ctx.exception))

    def test_finished_run_with_other_bytes_is_not_chosen(self):
        _run(self.base, "run-1", b"other", self.r, finished=True)
        with self.assertRaises(agent.AgentRefusal):
            agent.locate_artifacts(HEAD, self.xs, self.rs)


if __name__ == "__main__":
    unittest.main()
